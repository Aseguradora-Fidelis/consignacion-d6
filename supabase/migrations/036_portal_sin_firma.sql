-- 036: remediacion del portal y del expediente (auditoria del 2026-10-08).
--   * Correo y celular del distribuidor son obligatorios (decision del 2026-10-08).
--   * Sin firma dibujada. El procedimiento v01 pide el cuestionario IVE, no una firma.
--     Queda la declaracion de veracidad, con evidencia guardada por el servidor.
--   * Una vez enviado, el enlace solo recibe documentos: los datos del IVE no se reescriben.
--     Se reabren cuando Suscripcion pide informacion complementaria.
--   * El servidor exige fecha de nacimiento, fuente de ingresos y las respuestas PEP.

-- ============================================================================
-- Evidencia del envio
-- ============================================================================
ALTER TABLE public.solicitudes_alta
  ADD COLUMN IF NOT EXISTS ive_envio_hash TEXT,
  ADD COLUMN IF NOT EXISTS ive_envio_ip TEXT,
  ADD COLUMN IF NOT EXISTS ive_envio_user_agent TEXT,
  ADD COLUMN IF NOT EXISTS ive_declaracion_version TEXT;

COMMENT ON COLUMN public.solicitudes_alta.ive_envio_hash IS 'SHA-256 del IVE enviado, para probar que no cambio despues';
COMMENT ON COLUMN public.solicitudes_alta.ive_declaracion_version IS 'Version del texto de la declaracion de veracidad que acepto el distribuidor';

-- Encabezado HTTP de la peticion en curso (PostgREST lo expone en request.headers).
CREATE OR REPLACE FUNCTION public.d6_encabezado(p_nombre TEXT)
RETURNS TEXT
LANGUAGE sql STABLE SET search_path = ''
AS $$
  SELECT left(NULLIF(btrim(COALESCE(current_setting('request.headers', true), '{}')::json ->> p_nombre), ''), 300);
$$;
REVOKE EXECUTE ON FUNCTION public.d6_encabezado(TEXT) FROM PUBLIC, anon, authenticated;

-- Solo datos: la firma y la declaracion no viajan en el borrador.
CREATE OR REPLACE FUNCTION public.d6_sin_firma(p_datos JSONB)
RETURNS JSONB
LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
  SELECT COALESCE(p_datos, '{}'::jsonb) - 'firmaImagen' - 'declaracionVeracidad';
$$;

-- El enlace de una solicitud ya enviada solo sirve para subir documentos.
CREATE OR REPLACE FUNCTION public.d6_solo_documentos(p_estado public.d6_solicitud_status)
RETURNS BOOLEAN
LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
  SELECT p_estado IN ('EXPEDIENTE_RECIBIDO', 'EN_REVISION');
$$;

-- ============================================================================
-- Validacion del IVE
-- ============================================================================
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
    v_requeridos := ARRAY['primerNombre', 'primerApellido', 'dpi', 'nit', 'telefono', 'correo', 'fechaNacimiento', 'direccion', 'municipio', 'departamento', 'nacionalidad', 'profesion', 'lugarTrabajo', 'cargoTrabajo', 'fuenteIngresos', 'ingresosMensuales', 'egresosMensuales', 'estadoCivil', 'esPEP', 'parientePEP', 'asociadoPEP', 'refNombre1', 'refTelefono1'];
  ELSIF v_tipo IN ('IVE-IR-02', 'IVE-ASS-02') THEN
    v_requeridos := ARRAY['razonSocial', 'nitEntidad', 'actividadEconomica', 'paisConstitucion', 'escrituraNumero', 'escrituraFecha', 'notarioConstitucion', 'patenteSociedad', 'patenteEmpresa', 'registroMercantil', 'direccionSede', 'telefonoEmpresa', 'correoEmpresa', 'repNombreCompleto', 'repDpi', 'repNit', 'repCargo', 'repNombramientoNotario', 'repNombramientoFecha', 'repEsPEP'];
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

-- ============================================================================
-- Portal del distribuidor
-- ============================================================================
CREATE OR REPLACE FUNCTION public.portal_ive_contexto(p_token TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_inv public.ive_invitaciones;
  v_sol public.solicitudes_alta;
  v_motivo TEXT;
  v_previo JSONB;
  v_solo_docs BOOLEAN;
BEGIN
  v_inv := public.d6_invitacion_por_token(p_token);
  v_motivo := CASE
    WHEN v_inv.id IS NULL THEN 'NO_EXISTE'
    WHEN v_inv.used_at IS NOT NULL THEN 'ENVIADO'
    WHEN v_inv.revoked_at IS NOT NULL THEN 'REEMPLAZADO'
    WHEN v_inv.expires_at <= now() THEN 'EXPIRADO'
  END;
  IF v_motivo IS NOT NULL THEN
    RETURN jsonb_build_object('valido', false, 'motivo', v_motivo);
  END IF;
  SELECT * INTO v_sol FROM public.solicitudes_alta WHERE id = v_inv.solicitud_alta_id;
  IF NOT public.d6_estado_actualizable(v_sol.estado_operativo) THEN
    RETURN jsonb_build_object('valido', false, 'motivo', 'CERRADO');
  END IF;
  v_solo_docs := public.d6_solo_documentos(v_sol.estado_operativo);

  -- Precarga de una solicitud anterior del mismo cliente y de la misma marca, sin firma ni declaracion.
  IF NOT v_solo_docs AND v_sol.ive_data IS NULL AND v_sol.cliente_id IS NOT NULL THEN
    SELECT public.d6_sin_firma(sa.ive_data) INTO v_previo FROM public.solicitudes_alta sa
    WHERE sa.cliente_id = v_sol.cliente_id AND sa.id <> v_sol.id AND sa.ive_data IS NOT NULL
      AND sa.tipo_persona = v_sol.tipo_persona
      AND EXISTS (
        SELECT 1 FROM public.grupo_beneficiario_rel a
        JOIN public.grupo_beneficiario_rel b ON b.grupo_id = a.grupo_id
        JOIN public.grupos_beneficiarios g ON g.id = a.grupo_id AND g.codigo <> 'GRP-GENERAL'
        WHERE a.beneficiario_id = v_sol.beneficiario_id AND b.beneficiario_id = sa.beneficiario_id)
    ORDER BY sa.ive_completed_at DESC NULLS LAST LIMIT 1;
  END IF;

  RETURN jsonb_build_object(
    'valido', true,
    'numero_solicitud', v_sol.numero_solicitud,
    'estado', v_sol.estado_operativo,
    'marca', COALESCE((SELECT g.nombre FROM public.grupo_beneficiario_rel r
                       JOIN public.grupos_beneficiarios g ON g.id = r.grupo_id AND g.codigo <> 'GRP-GENERAL'
                       WHERE r.beneficiario_id = v_sol.beneficiario_id LIMIT 1),
                      (SELECT nombre FROM public.beneficiarios WHERE id = v_sol.beneficiario_id)),
    'afianzado', v_sol.cliente_nombre_tmp,
    'tipo_persona', v_sol.tipo_persona,
    'tipo_solicitud', v_sol.tipo_solicitud,
    'monto_solicitado', v_sol.monto_solicitado,
    'expira', v_inv.expires_at,
    'comentario', CASE WHEN v_sol.estado_operativo = 'INFORMACION_COMPLEMENTARIA' THEN v_sol.resolucion_comentario END,
    'faltantes', v_sol.faltantes,
    -- Ya enviado, el portal no devuelve el formulario: solo pide los documentos que faltan.
    'borrador', CASE WHEN v_solo_docs THEN '{}'::jsonb
                     ELSE COALESCE(v_previo, '{}'::jsonb) || public.d6_sin_firma(v_sol.ive_data)
                          || public.d6_sin_firma(v_sol.ive_borrador) END,
    'precargado', v_previo IS NOT NULL,
    'actualizacion', v_solo_docs,
    'solo_documentos', v_solo_docs,
    'requisitos', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'categoria', r.categoria, 'nombre', r.nombre, 'ayuda', r.ayuda, 'obligatorio', r.obligatorio,
        'responsable', r.responsable,
        'documentos', COALESCE((
          SELECT jsonb_agg(jsonb_build_object(
            'id', d.id, 'nombre_archivo', d.nombre_archivo, 'estado', d.estado_revision, 'origen', d.origen,
            'comentario', d.comentario_revision, 'subido', d.created_at) ORDER BY d.created_at)
          FROM public.documentos d
          WHERE d.solicitud_alta_id = v_sol.id AND d.categoria = r.categoria AND NOT d.carga_pendiente
            AND NOT (d.estado_revision = 'RECHAZADO' AND COALESCE(d.comentario_revision, '') ~ '^(Reemplazado|Retirado)')
        ), '[]'::jsonb)
      ) ORDER BY r.orden)
      FROM public.ive_requisitos_d6 r
      WHERE r.activo AND r.tipo_persona = v_sol.tipo_persona
        AND r.categoria NOT IN ('IVE_ASS_01', 'IVE_ASS_02')
        AND (NOT r.requiere_umbral_exposicion OR v_sol.requiere_documento_accesorio)
    ), '[]'::jsonb)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.portal_ive_guardar_borrador(p_token TEXT, p_datos JSONB)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_sol public.solicitudes_alta;
BEGIN
  v_sol := public.d6_portal_solicitud(p_token);
  IF public.d6_solo_documentos(v_sol.estado_operativo) THEN
    RAISE EXCEPTION 'Sus datos ya fueron enviados a Fidelis. Con este enlace solo puede subir documentos.';
  END IF;
  IF pg_column_size(p_datos) > 512000 THEN
    RAISE EXCEPTION 'El borrador es demasiado grande';
  END IF;
  UPDATE public.solicitudes_alta
  SET ive_borrador = public.d6_sin_firma(COALESCE(ive_borrador, ive_data, '{}'::jsonb) || COALESCE(p_datos, '{}'::jsonb))
  WHERE id = v_sol.id;
END;
$$;

CREATE OR REPLACE FUNCTION public.completar_ive_invitacion(p_token TEXT, p_datos JSONB)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_sol public.solicitudes_alta;
  v_inv public.ive_invitaciones;
  v_faltan TEXT;
  v_datos JSONB;
  v_solo_docs BOOLEAN;
BEGIN
  v_sol := public.d6_portal_solicitud(p_token);
  v_inv := public.d6_invitacion_por_token(p_token);
  v_solo_docs := public.d6_solo_documentos(v_sol.estado_operativo);
  SELECT string_agg(nombre, ', ') INTO v_faltan FROM public.d6_documentos_faltantes(v_sol.id, true);
  PERFORM 1 FROM public.ive_invitaciones WHERE id = v_inv.id FOR UPDATE;

  IF v_solo_docs THEN
    -- Ya enviado: el IVE no cambia. Solo se registra que el distribuidor subio lo que faltaba.
    UPDATE public.solicitudes_alta
    SET faltantes = COALESCE((SELECT jsonb_agg(categoria) FROM public.d6_documentos_faltantes(v_sol.id, true)), '[]'::jsonb)
    WHERE id = v_sol.id;
    UPDATE public.ive_invitaciones SET used_at = now() WHERE id = v_inv.id;
    INSERT INTO public.solicitud_revisiones (solicitud_alta_id, estado_anterior, estado_nuevo, comentario, creado_por)
    VALUES (v_sol.id, v_sol.estado_operativo, v_sol.estado_operativo,
            'Documentos subidos con el enlace del distribuidor' || COALESCE('. Siguen pendientes: ' || v_faltan, ''), NULL);
    RETURN v_sol.id;
  END IF;

  IF pg_column_size(p_datos) > 512000 THEN
    RAISE EXCEPTION 'El formulario es demasiado grande';
  END IF;
  PERFORM public.validar_datos_ive_d6(p_datos);
  IF (v_sol.tipo_persona = 'INDIVIDUAL' AND p_datos->>'tipoIve' NOT IN ('IVE-ASS-01', 'IVE-IR-01'))
     OR (v_sol.tipo_persona = 'JURIDICA' AND p_datos->>'tipoIve' NOT IN ('IVE-ASS-02', 'IVE-IR-02')) THEN
    RAISE EXCEPTION 'El formulario no corresponde al tipo de cliente del expediente';
  END IF;

  -- Se guarda sin imagen de firma. La declaracion aceptada queda como evidencia del envio.
  v_datos := (p_datos - 'firmaImagen') || jsonb_build_object('declaracionVeracidad', true);

  UPDATE public.solicitudes_alta
  SET ive_data = v_datos,
      ive_borrador = NULL,
      ive_form_version = COALESCE(NULLIF(p_datos->>'versionFormulario', ''), 'FIDELIS-D6-2026.4'),
      ive_completed_at = now(),
      ive_envio_hash = encode(extensions.digest(v_datos::text, 'sha256'), 'hex'),
      ive_envio_ip = COALESCE(public.d6_encabezado('cf-connecting-ip'), split_part(public.d6_encabezado('x-forwarded-for'), ',', 1)),
      ive_envio_user_agent = public.d6_encabezado('user-agent'),
      ive_declaracion_version = COALESCE(NULLIF(p_datos->>'versionDeclaracion', ''), 'D6-DECLARACION-2026.1'),
      estado_operativo = 'EXPEDIENTE_RECIBIDO',
      faltantes = COALESCE((SELECT jsonb_agg(categoria) FROM public.d6_documentos_faltantes(v_sol.id, true)), '[]'::jsonb)
  WHERE id = v_sol.id;
  UPDATE public.ive_invitaciones SET used_at = now() WHERE id = v_inv.id;
  INSERT INTO public.solicitud_revisiones (solicitud_alta_id, estado_anterior, estado_nuevo, comentario, creado_por)
  VALUES (v_sol.id, v_sol.estado_operativo, 'EXPEDIENTE_RECIBIDO',
          'Solicitud enviada por el distribuidor' || COALESCE('. Documentos pendientes: ' || v_faltan, ''), NULL);
  RETURN v_sol.id;
END;
$$;

-- La marca no escribe firma ni declaracion (ya lo hacia la 033), ahora con la funcion comun.
CREATE OR REPLACE FUNCTION public.d6_alta_guardar_borrador(p_solicitud_id UUID, p_cambios JSONB)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_sol public.solicitudes_alta;
BEGIN
  SELECT * INTO v_sol FROM public.solicitudes_alta WHERE id = p_solicitud_id FOR UPDATE;
  IF NOT FOUND OR NOT public.d6_alta_editable(v_sol) THEN
    RAISE EXCEPTION 'Esta solicitud ya no se puede editar';
  END IF;
  IF pg_column_size(p_cambios) > 512000 THEN RAISE EXCEPTION 'Los datos son demasiado grandes'; END IF;
  UPDATE public.solicitudes_alta
  SET ive_borrador = COALESCE(ive_borrador, '{}'::jsonb) || public.d6_sin_firma(p_cambios)
  WHERE id = p_solicitud_id;
END;
$$;

-- ============================================================================
-- Correo y celular obligatorios
-- ============================================================================
CREATE OR REPLACE FUNCTION public.d6_correo_valido(p_correo TEXT)
RETURNS BOOLEAN
LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
  SELECT COALESCE(btrim(p_correo), '') ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$';
$$;

CREATE OR REPLACE FUNCTION public.d6_celular_valido(p_telefono TEXT)
RETURNS BOOLEAN
LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
  SELECT length(regexp_replace(COALESCE(p_telefono, ''), '\D', '', 'g')) BETWEEN 8 AND 15;
$$;

DROP FUNCTION IF EXISTS public.crear_invitacion_ive(UUID, TEXT, INTEGER);
CREATE OR REPLACE FUNCTION public.crear_invitacion_ive(
  p_solicitud_id UUID, p_destinatario_email TEXT, p_horas INTEGER DEFAULT 72, p_destinatario_telefono TEXT DEFAULT NULL
)
RETURNS TABLE(token TEXT, expires_at TIMESTAMPTZ)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_token TEXT := encode(extensions.gen_random_bytes(32), 'hex');
  v_expires_at TIMESTAMPTZ := now() + make_interval(hours => LEAST(GREATEST(COALESCE(p_horas, 72), 1), 720));
  v_solicitud public.solicitudes_alta%ROWTYPE;
  v_es_personal BOOLEAN := public.has_d6_role(ARRAY['admin', 'comercial', 'suscripcion']::public.d6_role[]);
  v_correo TEXT;
  v_telefono TEXT;
BEGIN
  SELECT * INTO v_solicitud FROM public.solicitudes_alta WHERE id = p_solicitud_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'La solicitud de alta no existe';
  END IF;
  IF NOT v_es_personal AND NOT public.d6_beneficiario_es_mio(v_solicitud.beneficiario_id) THEN
    RAISE EXCEPTION 'No tiene permiso para enviar el enlace de esta solicitud';
  END IF;
  v_correo := NULLIF(btrim(COALESCE(NULLIF(btrim(p_destinatario_email), ''), v_solicitud.cliente_email_tmp, '')), '');
  v_telefono := NULLIF(btrim(COALESCE(NULLIF(btrim(p_destinatario_telefono), ''), v_solicitud.cliente_telefono_tmp, '')), '');
  IF NOT public.d6_correo_valido(v_correo) THEN
    RAISE EXCEPTION 'Indique un correo válido del distribuidor';
  END IF;
  IF NOT public.d6_celular_valido(v_telefono) THEN
    RAISE EXCEPTION 'Indique el celular del distribuidor (8 dígitos)';
  END IF;
  IF NOT (v_solicitud.estado_operativo = 'BORRADOR' OR public.d6_estado_actualizable(v_solicitud.estado_operativo))
     AND NOT (v_es_personal AND v_solicitud.estado_operativo = 'SUSPENDIDA') THEN
    RAISE EXCEPTION 'La solicitud esta en estado % y no admite un enlace nuevo', v_solicitud.estado_operativo;
  END IF;

  UPDATE public.ive_invitaciones SET revoked_at = now()
  WHERE solicitud_alta_id = p_solicitud_id AND used_at IS NULL AND revoked_at IS NULL;
  INSERT INTO public.ive_invitaciones (solicitud_alta_id, token_hash, destinatario_email, expires_at, created_by)
  VALUES (p_solicitud_id, encode(extensions.digest(v_token, 'sha256'), 'hex'), v_correo, v_expires_at, auth.uid());
  UPDATE public.solicitudes_alta SET cliente_email_tmp = v_correo, cliente_telefono_tmp = v_telefono
  WHERE id = p_solicitud_id AND (cliente_email_tmp IS DISTINCT FROM v_correo OR cliente_telefono_tmp IS DISTINCT FROM v_telefono);

  IF v_solicitud.estado_operativo IN ('BORRADOR', 'SUSPENDIDA') THEN
    UPDATE public.solicitudes_alta SET estado_operativo = 'IVE_PENDIENTE' WHERE id = p_solicitud_id;
    INSERT INTO public.solicitud_revisiones (solicitud_alta_id, estado_anterior, estado_nuevo, comentario, creado_por)
    VALUES (p_solicitud_id, v_solicitud.estado_operativo, 'IVE_PENDIENTE', 'Enlace enviado al afianzado', auth.uid());
  END IF;
  RETURN QUERY SELECT v_token, v_expires_at;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.crear_invitacion_ive(UUID, TEXT, INTEGER, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crear_invitacion_ive(UUID, TEXT, INTEGER, TEXT) TO authenticated;

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
  IF NOT public.d6_correo_valido(v_correo) THEN
    RAISE EXCEPTION 'El correo del distribuidor es obligatorio';
  END IF;
  IF NOT public.d6_celular_valido(v_telefono) THEN
    RAISE EXCEPTION 'El celular del distribuidor es obligatorio (8 dígitos)';
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

-- Se retira la funcion de "correo o celular" de la 034: ya no aplica.
DROP FUNCTION IF EXISTS public.d6_contacto_valido(TEXT, TEXT);

-- La vista de la marca trae el celular para que WhatsApp abra el chat correcto al reenviar.
CREATE OR REPLACE VIEW public.v_solicitudes_alta_marca
WITH (security_barrier = true)
AS
SELECT sa.id, sa.numero_solicitud, sa.beneficiario_id,
  b.codigo_contacto AS beneficiario_codigo, b.nombre AS beneficiario_nombre,
  COALESCE(sa.cliente_nombre_tmp, c.nombre) AS afianzado_nombre,
  sa.cliente_email_tmp AS afianzado_email,
  sa.tipo_persona, sa.monto_solicitado, sa.monto_aprobado, sa.estado_operativo,
  CASE WHEN sa.estado_operativo IN ('INFORMACION_COMPLEMENTARIA', 'SUSPENDIDA', 'NO_ELEGIBLE') THEN sa.resolucion_comentario END AS motivo,
  sa.faltantes, sa.resolucion_marca_numero,
  sa.ive_completed_at IS NOT NULL AS ive_completado,
  inv.expires_at AS enlace_expira,
  f.fianza AS fianza_emitida,
  sa.emitida_en, sa.created_at, sa.updated_at,
  sa.cliente_telefono_tmp AS afianzado_telefono
FROM public.solicitudes_alta sa
JOIN public.beneficiarios b ON b.id = sa.beneficiario_id
LEFT JOIN public.clientes c ON c.id = sa.cliente_id
LEFT JOIN LATERAL (
  SELECT i.expires_at FROM public.ive_invitaciones i
  WHERE i.solicitud_alta_id = sa.id AND i.used_at IS NULL AND i.revoked_at IS NULL
  ORDER BY i.created_at DESC LIMIT 1) inv ON true
LEFT JOIN LATERAL (
  SELECT fz.fianza FROM public.fianzas fz
  WHERE sa.estado_operativo = 'EMITIDA' AND fz.cliente_id = sa.cliente_id
    AND fz.beneficiario_id = sa.beneficiario_id AND fz.contrato_id = sa.contrato_id
  ORDER BY fz.created_at DESC LIMIT 1) f ON true
WHERE public.d6_puede_ver_beneficiario(sa.beneficiario_id);
