-- 034: muchos distribuidores solo usan WhatsApp. El alta pide correo o celular, no los dos.

ALTER TABLE public.ive_invitaciones ALTER COLUMN destinatario_email DROP NOT NULL;

CREATE OR REPLACE FUNCTION public.d6_contacto_valido(p_correo TEXT, p_telefono TEXT)
RETURNS BOOLEAN
LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(btrim(p_correo), '') ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'
      OR length(regexp_replace(COALESCE(p_telefono, ''), '\D', '', 'g')) >= 8;
$$;

CREATE OR REPLACE FUNCTION public.crear_invitacion_ive(p_solicitud_id UUID, p_destinatario_email TEXT, p_horas INTEGER DEFAULT 72)
RETURNS TABLE(token TEXT, expires_at TIMESTAMPTZ)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_token TEXT := encode(extensions.gen_random_bytes(32), 'hex');
  v_expires_at TIMESTAMPTZ := now() + make_interval(hours => LEAST(GREATEST(COALESCE(p_horas, 72), 1), 720));
  v_solicitud public.solicitudes_alta%ROWTYPE;
  v_es_personal BOOLEAN := public.has_d6_role(ARRAY['admin', 'comercial', 'suscripcion']::public.d6_role[]);
  v_correo TEXT;
BEGIN
  SELECT * INTO v_solicitud FROM public.solicitudes_alta WHERE id = p_solicitud_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'La solicitud de alta no existe';
  END IF;
  IF NOT v_es_personal AND NOT public.d6_beneficiario_es_mio(v_solicitud.beneficiario_id) THEN
    RAISE EXCEPTION 'No tiene permiso para enviar el enlace de esta solicitud';
  END IF;
  v_correo := NULLIF(btrim(COALESCE(NULLIF(btrim(p_destinatario_email), ''), v_solicitud.cliente_email_tmp, '')), '');
  IF NOT public.d6_contacto_valido(v_correo, v_solicitud.cliente_telefono_tmp) THEN
    RAISE EXCEPTION 'Indique un correo o un celular del distribuidor';
  END IF;
  IF v_solicitud.estado_operativo NOT IN ('BORRADOR', 'IVE_PENDIENTE', 'INFORMACION_COMPLEMENTARIA')
     AND NOT (v_es_personal AND v_solicitud.estado_operativo = 'SUSPENDIDA') THEN
    RAISE EXCEPTION 'La solicitud esta en estado % y no admite un enlace nuevo', v_solicitud.estado_operativo;
  END IF;

  UPDATE public.ive_invitaciones SET revoked_at = now()
  WHERE solicitud_alta_id = p_solicitud_id AND used_at IS NULL AND revoked_at IS NULL;
  INSERT INTO public.ive_invitaciones (solicitud_alta_id, token_hash, destinatario_email, expires_at, created_by)
  VALUES (p_solicitud_id, encode(extensions.digest(v_token, 'sha256'), 'hex'), v_correo, v_expires_at, auth.uid());

  IF v_solicitud.estado_operativo IN ('BORRADOR', 'SUSPENDIDA') THEN
    UPDATE public.solicitudes_alta SET estado_operativo = 'IVE_PENDIENTE' WHERE id = p_solicitud_id;
    INSERT INTO public.solicitud_revisiones (solicitud_alta_id, estado_anterior, estado_nuevo, comentario, creado_por)
    VALUES (p_solicitud_id, v_solicitud.estado_operativo, 'IVE_PENDIENTE', 'Enlace enviado al afianzado', auth.uid());
  END IF;
  RETURN QUERY SELECT v_token, v_expires_at;
END;
$$;

CREATE OR REPLACE FUNCTION public.d6_solicitar_alta(
  p_beneficiario_codigo INTEGER,
  p_cliente_nombre TEXT,
  p_cliente_email TEXT,
  p_monto NUMERIC,
  p_tipo_persona public.tipo_persona DEFAULT 'INDIVIDUAL',
  p_cliente_nit TEXT DEFAULT NULL,
  p_cliente_telefono TEXT DEFAULT NULL,
  p_resolucion_numero TEXT DEFAULT NULL,
  p_resolucion_fecha DATE DEFAULT NULL,
  p_resolucion_monto NUMERIC DEFAULT NULL,
  p_resolucion_plazo_dias INTEGER DEFAULT NULL,
  p_observaciones TEXT DEFAULT NULL,
  p_horas_ive INTEGER DEFAULT 168
)
RETURNS TABLE(solicitud_id UUID, numero_solicitud TEXT, ive_token TEXT, ive_expira TIMESTAMPTZ)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_beneficiario public.beneficiarios%ROWTYPE;
  v_cliente_id UUID;
  v_nombre TEXT := regexp_replace(btrim(COALESCE(p_cliente_nombre, '')), '\s+', ' ', 'g');
  v_nit TEXT := public.d6_normalizar_nit(p_cliente_nit);
  v_correo TEXT := NULLIF(btrim(COALESCE(p_cliente_email, '')), '');
  v_telefono TEXT := NULLIF(btrim(COALESCE(p_cliente_telefono, '')), '');
  v_solicitud_id UUID;
  v_numero TEXT;
  v_token TEXT := encode(extensions.gen_random_bytes(32), 'hex');
  v_expira TIMESTAMPTZ := now() + make_interval(hours => LEAST(GREATEST(COALESCE(p_horas_ive, 168), 1), 720));
  v_exposicion NUMERIC(15,2) := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Debe iniciar sesion para solicitar un alta';
  END IF;
  IF v_nombre = '' THEN
    RAISE EXCEPTION 'El nombre del distribuidor es obligatorio';
  END IF;
  IF NOT public.d6_contacto_valido(v_correo, v_telefono) THEN
    RAISE EXCEPTION 'Indique un correo o un celular del distribuidor: ahi recibe el enlace';
  END IF;
  IF v_correo IS NOT NULL AND v_correo !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
    RAISE EXCEPTION 'Revise el correo del distribuidor';
  END IF;
  IF COALESCE(p_monto, 0) <= 0 THEN
    RAISE EXCEPTION 'El monto solicitado debe ser mayor que cero';
  END IF;
  IF p_resolucion_monto IS NOT NULL AND p_monto > p_resolucion_monto THEN
    RAISE EXCEPTION 'El monto de la fianza no puede superar el limite aprobado por la marca (%)', p_resolucion_monto;
  END IF;

  SELECT * INTO v_beneficiario FROM public.beneficiarios WHERE codigo_contacto = p_beneficiario_codigo;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'El beneficiario % no existe', p_beneficiario_codigo;
  END IF;
  IF NOT public.has_d6_role(ARRAY['admin', 'comercial', 'suscripcion']::public.d6_role[])
     AND NOT public.d6_beneficiario_es_mio(v_beneficiario.id) THEN
    RAISE EXCEPTION 'No puede solicitar altas de una marca que no es la suya';
  END IF;

  IF v_nit IS NOT NULL THEN
    SELECT id INTO v_cliente_id FROM public.clientes
    WHERE public.d6_normalizar_nit(nit) = v_nit ORDER BY created_at LIMIT 1;
  END IF;
  IF v_cliente_id IS NULL THEN
    INSERT INTO public.clientes (codigo_contacto, nombre, nit, tipo_persona, telefono, email)
    VALUES (nextval('public.clientes_app_codigo_seq'), v_nombre, NULLIF(btrim(COALESCE(p_cliente_nit, '')), ''),
            COALESCE(p_tipo_persona, 'INDIVIDUAL'), v_telefono, v_correo)
    RETURNING id INTO v_cliente_id;
  END IF;

  SELECT COALESCE(SUM(monto_afianzado), 0) INTO v_exposicion
  FROM public.fianzas
  WHERE cliente_id = v_cliente_id
    AND operational_status IN ('VIGENTE', 'POR_RENOVAR', 'PENDIENTE_ANULACION')
    AND vigencia_hasta >= CURRENT_DATE;

  v_numero := 'ALT-' || to_char(now(), 'YYYY') || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));

  INSERT INTO public.solicitudes_alta (
    numero_solicitud, cliente_id, cliente_nombre_tmp, cliente_nit_tmp, cliente_email_tmp, cliente_telefono_tmp,
    tipo_persona, beneficiario_id, monto_solicitado, vigencia_desde, vigencia_hasta, tema_de_fianza,
    resolucion_marca_numero, resolucion_marca_fecha, resolucion_marca_monto, resolucion_marca_plazo_dias,
    observaciones, estado, estado_operativo, requiere_documento_accesorio, exposicion_vigente, creado_por
  ) VALUES (
    v_numero, v_cliente_id, v_nombre, NULLIF(btrim(COALESCE(p_cliente_nit, '')), ''), v_correo, v_telefono,
    COALESCE(p_tipo_persona, 'INDIVIDUAL'),
    v_beneficiario.id, p_monto, CURRENT_DATE, (CURRENT_DATE + INTERVAL '1 year' - INTERVAL '1 day')::date,
    'Consignacion comercial de linea de productos',
    NULLIF(btrim(COALESCE(p_resolucion_numero, '')), ''), p_resolucion_fecha, p_resolucion_monto, p_resolucion_plazo_dias,
    NULLIF(btrim(COALESCE(p_observaciones, '')), ''), 'BORRADOR', 'IVE_PENDIENTE',
    (p_monto > 300000 OR p_monto + v_exposicion > 300000), v_exposicion, auth.uid()
  )
  RETURNING id INTO v_solicitud_id;

  INSERT INTO public.ive_invitaciones (solicitud_alta_id, token_hash, destinatario_email, expires_at, created_by)
  VALUES (v_solicitud_id, encode(extensions.digest(v_token, 'sha256'), 'hex'), v_correo, v_expira, auth.uid());
  INSERT INTO public.solicitud_revisiones (solicitud_alta_id, estado_anterior, estado_nuevo, comentario, creado_por)
  VALUES (v_solicitud_id, NULL, 'IVE_PENDIENTE', 'Alta solicitada', auth.uid());

  RETURN QUERY SELECT v_solicitud_id, v_numero, v_token, v_expira;
END;
$$;

-- El formulario del distribuidor tampoco exige correo: basta el celular.
CREATE OR REPLACE FUNCTION public.validar_datos_ive_d6(p_datos JSONB)
RETURNS VOID
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public
AS $$
DECLARE
  v_tipo TEXT := COALESCE(p_datos->>'tipoIve', '');
  v_campo TEXT;
  v_requeridos TEXT[];
BEGIN
  IF v_tipo IN ('IVE-IR-01', 'IVE-ASS-01') THEN
    v_requeridos := ARRAY['primerNombre', 'primerApellido', 'dpi', 'nit', 'telefono', 'direccion', 'municipio', 'departamento', 'nacionalidad', 'profesion', 'lugarTrabajo', 'cargoTrabajo', 'ingresosMensuales', 'egresosMensuales', 'estadoCivil', 'refNombre1', 'refTelefono1'];
  ELSIF v_tipo IN ('IVE-IR-02', 'IVE-ASS-02') THEN
    v_requeridos := ARRAY['razonSocial', 'nitEntidad', 'actividadEconomica', 'paisConstitucion', 'escrituraNumero', 'escrituraFecha', 'notarioConstitucion', 'patenteSociedad', 'patenteEmpresa', 'registroMercantil', 'direccionSede', 'telefonoEmpresa', 'correoEmpresa', 'repNombreCompleto', 'repDpi', 'repNit', 'repCargo', 'repNombramientoNotario', 'repNombramientoFecha'];
  ELSE
    RAISE EXCEPTION 'Tipo de formulario IVE no reconocido';
  END IF;

  FOREACH v_campo IN ARRAY v_requeridos LOOP
    IF NULLIF(BTRIM(COALESCE(p_datos->>v_campo, '')), '') IS NULL THEN
      RAISE EXCEPTION 'Falta el campo IVE requerido: %', v_campo;
    END IF;
  END LOOP;

  IF COALESCE((p_datos->>'declaracionVeracidad')::BOOLEAN, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'Debe aceptar la declaración de veracidad';
  END IF;
  IF NULLIF(BTRIM(COALESCE(p_datos->>'firmaImagen', '')), '') IS NULL THEN
    RAISE EXCEPTION 'Debe capturar la firma del solicitante';
  END IF;
  IF p_datos->>'esPEP' = 'SI' AND NULLIF(BTRIM(COALESCE(p_datos->>'pepDetalle', '')), '') IS NULL THEN
    RAISE EXCEPTION 'Falta detalle de condición PEP';
  END IF;
  IF p_datos->>'parientePEP' = 'SI' AND NULLIF(BTRIM(COALESCE(p_datos->>'parientePepDetalle', '')), '') IS NULL THEN
    RAISE EXCEPTION 'Falta detalle de parentesco PEP';
  END IF;
  IF p_datos->>'asociadoPEP' = 'SI' AND NULLIF(BTRIM(COALESCE(p_datos->>'asociadoPepDetalle', '')), '') IS NULL THEN
    RAISE EXCEPTION 'Falta detalle de asociación PEP';
  END IF;
  IF p_datos->>'repEsPEP' = 'SI' AND NULLIF(BTRIM(COALESCE(p_datos->>'repPepDetalle', '')), '') IS NULL THEN
    RAISE EXCEPTION 'Falta detalle PEP del representante legal';
  END IF;
END;
$$;
