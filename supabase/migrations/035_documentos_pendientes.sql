-- 035: los documentos que falten no detienen el envio. El distribuidor envia lo que tiene,
-- lo que falta queda pendiente y la marca o Fidelis generan un enlace nuevo para que lo suba.
-- Fidelis puede empezar a revisar con documentos pendientes; para aprobar exige todos.
-- El correo del distribuidor vuelve a ser obligatorio (decision del 2026-10-08).

-- Estados en los que el distribuidor puede actualizar su solicitud con un enlace vigente.
CREATE OR REPLACE FUNCTION public.d6_estado_actualizable(p_estado public.d6_solicitud_status)
RETURNS BOOLEAN LANGUAGE sql IMMUTABLE AS $$
  SELECT p_estado IN ('IVE_PENDIENTE', 'INFORMACION_COMPLEMENTARIA', 'EXPEDIENTE_RECIBIDO', 'EN_REVISION');
$$;


CREATE OR REPLACE FUNCTION public.d6_portal_solicitud(p_token TEXT)
RETURNS public.solicitudes_alta
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_inv public.ive_invitaciones;
  v_sol public.solicitudes_alta;
BEGIN
  v_inv := public.d6_invitacion_por_token(p_token);
  IF v_inv.id IS NULL OR v_inv.revoked_at IS NOT NULL OR v_inv.used_at IS NOT NULL OR v_inv.expires_at <= now() THEN
    RAISE EXCEPTION 'El enlace no es valido, expiro o fue reemplazado por uno nuevo';
  END IF;
  SELECT * INTO v_sol FROM public.solicitudes_alta WHERE id = v_inv.solicitud_alta_id;
  IF NOT public.d6_estado_actualizable(v_sol.estado_operativo) THEN
    RAISE EXCEPTION 'Este expediente ya no recibe cambios (estado %)', v_sol.estado_operativo;
  END IF;
  RETURN v_sol;
END;
$$;

CREATE OR REPLACE FUNCTION public.portal_ive_contexto(p_token TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_inv public.ive_invitaciones;
  v_sol public.solicitudes_alta;
  v_motivo TEXT;
  v_previo JSONB;
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
  IF v_sol.ive_data IS NULL AND v_sol.cliente_id IS NOT NULL THEN
    SELECT sa.ive_data INTO v_previo FROM public.solicitudes_alta sa
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
    -- El nombre de la marca que el distribuidor conoce, no la razon social del beneficiario.
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
    -- Lo que llenaron la marca o el distribuidor pesa mas que el formulario de una solicitud anterior.
    'borrador', COALESCE(v_previo, '{}'::jsonb) || COALESCE(v_sol.ive_data, '{}'::jsonb) || COALESCE(v_sol.ive_borrador, '{}'::jsonb),
    'precargado', v_previo IS NOT NULL,
    'actualizacion', v_sol.estado_operativo IN ('EXPEDIENTE_RECIBIDO', 'EN_REVISION'),
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

CREATE OR REPLACE FUNCTION public.completar_ive_invitacion(p_token TEXT, p_datos JSONB)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_sol public.solicitudes_alta;
  v_inv public.ive_invitaciones;
  v_faltan TEXT;
BEGIN
  v_sol := public.d6_portal_solicitud(p_token);
  v_inv := public.d6_invitacion_por_token(p_token);
  PERFORM public.validar_datos_ive_d6(p_datos);
  IF (v_sol.tipo_persona = 'INDIVIDUAL' AND p_datos->>'tipoIve' NOT IN ('IVE-ASS-01', 'IVE-IR-01'))
     OR (v_sol.tipo_persona = 'JURIDICA' AND p_datos->>'tipoIve' NOT IN ('IVE-ASS-02', 'IVE-IR-02')) THEN
    RAISE EXCEPTION 'El formulario no corresponde al tipo de cliente del expediente';
  END IF;
  SELECT string_agg(nombre, ', ') INTO v_faltan FROM public.d6_documentos_faltantes(v_sol.id, true);

  PERFORM 1 FROM public.ive_invitaciones WHERE id = v_inv.id FOR UPDATE;
  UPDATE public.solicitudes_alta
  SET ive_data = p_datos,
      ive_borrador = NULL,
      ive_form_version = COALESCE(NULLIF(p_datos->>'versionFormulario', ''), 'FIDELIS-D6-2026.4'),
      ive_completed_at = now(),
      -- Si ya estaba en manos de Fidelis, se queda donde estaba: solo se actualiza.
      estado_operativo = CASE WHEN v_sol.estado_operativo IN ('EXPEDIENTE_RECIBIDO', 'EN_REVISION')
                              THEN v_sol.estado_operativo ELSE 'EXPEDIENTE_RECIBIDO' END,
      faltantes = COALESCE((SELECT jsonb_agg(categoria) FROM public.d6_documentos_faltantes(v_sol.id, true)), '[]'::jsonb)
  WHERE id = v_sol.id;
  UPDATE public.ive_invitaciones SET used_at = now() WHERE id = v_inv.id;
  INSERT INTO public.solicitud_revisiones (solicitud_alta_id, estado_anterior, estado_nuevo, comentario, creado_por)
  VALUES (v_sol.id, v_sol.estado_operativo,
          CASE WHEN v_sol.estado_operativo IN ('EXPEDIENTE_RECIBIDO', 'EN_REVISION') THEN v_sol.estado_operativo ELSE 'EXPEDIENTE_RECIBIDO' END,
          CASE WHEN v_sol.estado_operativo IN ('EXPEDIENTE_RECIBIDO', 'EN_REVISION') THEN 'El distribuidor actualizó su solicitud'
               ELSE 'Solicitud enviada por el distribuidor' END
            || COALESCE('. Documentos pendientes: ' || v_faltan, ''),
          NULL);
  RETURN v_sol.id;
END;
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
  IF v_correo IS NULL OR v_correo !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
    RAISE EXCEPTION 'Indique un correo válido del distribuidor';
  END IF;
  IF NOT (v_solicitud.estado_operativo = 'BORRADOR' OR public.d6_estado_actualizable(v_solicitud.estado_operativo))
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
  IF v_correo IS NULL OR v_correo !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
    RAISE EXCEPTION 'El correo del distribuidor es obligatorio';
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
    v_requeridos := ARRAY['primerNombre', 'primerApellido', 'dpi', 'nit', 'telefono', 'correo', 'direccion', 'municipio', 'departamento', 'nacionalidad', 'profesion', 'lugarTrabajo', 'cargoTrabajo', 'ingresosMensuales', 'egresosMensuales', 'estadoCivil', 'refNombre1', 'refTelefono1'];
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

CREATE OR REPLACE FUNCTION public.transicionar_solicitud_alta(
  p_solicitud_id UUID,
  p_estado public.d6_solicitud_status,
  p_comentario TEXT DEFAULT NULL,
  p_monto_aprobado NUMERIC DEFAULT NULL,
  p_condiciones TEXT DEFAULT NULL,
  p_faltantes JSONB DEFAULT NULL,
  p_contragarantia TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_sol public.solicitudes_alta%ROWTYPE;
BEGIN
  IF NOT public.has_d6_role(ARRAY['admin', 'suscripcion']::public.d6_role[]) THEN
    RAISE EXCEPTION 'Solo Suscripcion puede resolver un expediente';
  END IF;
  SELECT * INTO v_sol FROM public.solicitudes_alta WHERE id = p_solicitud_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Solicitud no encontrada'; END IF;
  IF p_estado = 'EMITIDA' THEN RAISE EXCEPTION 'La emision se confirma con emitir_fianza_d6'; END IF;
  IF NOT (public.d6_transiciones_alta() -> v_sol.estado_operativo::text) ? p_estado::text THEN
    RAISE EXCEPTION 'No se puede pasar de % a %', v_sol.estado_operativo, p_estado;
  END IF;

  IF p_estado IN ('INFORMACION_COMPLEMENTARIA', 'SUSPENDIDA', 'NO_ELEGIBLE')
     AND NULLIF(btrim(COALESCE(p_comentario, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Explique el motivo: el comentario lo recibe la marca y el afianzado';
  END IF;
  IF p_estado = 'APROBADA_PARCIAL' AND (p_monto_aprobado IS NULL OR p_monto_aprobado <= 0) THEN
    RAISE EXCEPTION 'Una aprobacion parcial requiere el monto aprobado';
  END IF;
  IF p_estado = 'APROBADA_PARCIAL' AND p_monto_aprobado >= v_sol.monto_solicitado THEN
    RAISE EXCEPTION 'Una aprobacion parcial debe ser menor al monto solicitado';
  END IF;
  IF p_estado IN ('APROBADA_TOTAL', 'APROBADA_PARCIAL') THEN
    IF p_monto_aprobado IS NOT NULL AND p_monto_aprobado > v_sol.monto_solicitado THEN
      RAISE EXCEPTION 'El monto aprobado no puede superar el monto solicitado';
    END IF;
    IF EXISTS (SELECT 1 FROM public.documentos d
               WHERE d.solicitud_alta_id = p_solicitud_id AND NOT d.carga_pendiente
                 AND d.estado_revision = 'PENDIENTE') THEN
      RAISE EXCEPTION 'Revise todos los documentos (aceptar o rechazar) antes de aprobar';
    END IF;
    PERFORM public.validar_documentos_ive_d6(p_solicitud_id);
  END IF;

  UPDATE public.solicitudes_alta SET
    estado_operativo = p_estado,
    monto_aprobado = CASE
      WHEN p_estado = 'APROBADA_TOTAL' THEN monto_solicitado
      WHEN p_estado = 'APROBADA_PARCIAL' THEN p_monto_aprobado
      ELSE monto_aprobado END,
    condiciones_emision = COALESCE(NULLIF(btrim(p_condiciones), ''), condiciones_emision),
    contragarantia = COALESCE(NULLIF(btrim(p_contragarantia), ''), contragarantia),
    faltantes = CASE WHEN p_estado IN ('INFORMACION_COMPLEMENTARIA', 'SUSPENDIDA') THEN COALESCE(p_faltantes, '[]'::jsonb)
                     WHEN p_estado = 'EN_REVISION' THEN faltantes ELSE '[]'::jsonb END,
    resolucion_comentario = p_comentario,
    revisado_por = auth.uid()
  WHERE id = p_solicitud_id;

  INSERT INTO public.solicitud_revisiones (solicitud_alta_id, estado_anterior, estado_nuevo, comentario, monto_aprobado, faltantes, creado_por)
  VALUES (p_solicitud_id, v_sol.estado_operativo, p_estado, p_comentario,
          CASE WHEN p_estado = 'APROBADA_TOTAL' THEN v_sol.monto_solicitado ELSE p_monto_aprobado END,
          p_faltantes, auth.uid());
END;
$$;

CREATE OR REPLACE FUNCTION public.d6_alta_recibe_documentos(p_sol public.solicitudes_alta)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT (p_sol.estado_operativo = 'BORRADOR' OR public.d6_estado_actualizable(p_sol.estado_operativo))
    AND (public.has_d6_role(ARRAY['admin', 'comercial', 'suscripcion']::public.d6_role[])
         OR public.d6_beneficiario_es_mio(p_sol.beneficiario_id));
$$;
REVOKE EXECUTE ON FUNCTION public.d6_alta_recibe_documentos(public.solicitudes_alta) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.d6_alta_preparar_carga(
  p_solicitud_id UUID, p_categoria public.doc_categoria, p_nombre_archivo TEXT, p_mime TEXT, p_tamano INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_sol public.solicitudes_alta;
  v_ext TEXT;
  v_path TEXT;
  v_id UUID;
BEGIN
  SELECT * INTO v_sol FROM public.solicitudes_alta WHERE id = p_solicitud_id;
  IF NOT FOUND OR NOT public.d6_alta_recibe_documentos(v_sol) THEN
    RAISE EXCEPTION 'Esta solicitud ya no recibe documentos desde aquí';
  END IF;
  IF p_mime NOT IN ('application/pdf', 'image/png', 'image/jpeg') THEN
    RAISE EXCEPTION 'Solo se aceptan archivos PDF, PNG o JPG';
  END IF;
  IF COALESCE(p_tamano, 0) <= 0 OR p_tamano > 15728640 THEN
    RAISE EXCEPTION 'El archivo debe pesar menos de 15 MB';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.ive_requisitos_d6 r
                 WHERE r.activo AND r.tipo_persona = v_sol.tipo_persona AND r.categoria = p_categoria) THEN
    RAISE EXCEPTION 'Ese tipo de documento no corresponde a esta solicitud';
  END IF;
  IF (SELECT count(*) FROM public.documentos WHERE solicitud_alta_id = v_sol.id) >= 60 THEN
    RAISE EXCEPTION 'La solicitud alcanzó el límite de archivos. Contacte a Fidelis.';
  END IF;
  v_ext := CASE p_mime WHEN 'application/pdf' THEN 'pdf' WHEN 'image/png' THEN 'png' ELSE 'jpg' END;
  v_id := gen_random_uuid();
  v_path := 'altas/' || v_sol.id || '/' || v_id || '.' || v_ext;
  INSERT INTO public.documentos (id, solicitud_alta_id, categoria, nombre_archivo, file_path, file_size, mime_type,
                                 origen, subido_por, carga_pendiente, carga_expira, requerido)
  VALUES (v_id, v_sol.id, p_categoria, left(regexp_replace(COALESCE(p_nombre_archivo, 'documento'), '[\\/]', '_', 'g'), 180),
          v_path, p_tamano, p_mime,
          CASE WHEN public.d6_es_personal_aseguradora() THEN 'FIDELIS' ELSE 'MARCA' END,
          auth.uid(), true, now() + INTERVAL '15 minutes', true);
  RETURN jsonb_build_object('documento_id', v_id, 'path', v_path);
END;
$$;

CREATE OR REPLACE FUNCTION public.d6_alta_confirmar_carga(p_documento_id UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, storage
AS $$
DECLARE
  v_doc public.documentos;
  v_sol public.solicitudes_alta;
BEGIN
  SELECT * INTO v_doc FROM public.documentos WHERE id = p_documento_id AND carga_pendiente AND subido_por = auth.uid() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No hay una carga pendiente con ese identificador'; END IF;
  SELECT * INTO v_sol FROM public.solicitudes_alta WHERE id = v_doc.solicitud_alta_id;
  IF NOT public.d6_alta_recibe_documentos(v_sol) THEN RAISE EXCEPTION 'Esta solicitud ya no recibe documentos desde aquí'; END IF;
  IF NOT EXISTS (SELECT 1 FROM storage.objects o WHERE o.bucket_id = 'expedientes' AND o.name = v_doc.file_path) THEN
    RAISE EXCEPTION 'El archivo no llegó al servidor. Intente subirlo de nuevo.';
  END IF;
  UPDATE public.documentos SET carga_pendiente = false, carga_expira = NULL WHERE id = v_doc.id;
END;
$$;

CREATE OR REPLACE FUNCTION public.d6_alta_quitar_documento(p_documento_id UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_doc public.documentos;
  v_sol public.solicitudes_alta;
BEGIN
  SELECT * INTO v_doc FROM public.documentos WHERE id = p_documento_id;
  SELECT * INTO v_sol FROM public.solicitudes_alta WHERE id = v_doc.solicitud_alta_id;
  IF NOT FOUND OR NOT public.d6_alta_recibe_documentos(v_sol) THEN RAISE EXCEPTION 'Esta solicitud ya no se puede editar'; END IF;
  UPDATE public.documentos SET estado_revision = 'RECHAZADO', comentario_revision = 'Retirado antes de enviar'
  WHERE id = p_documento_id AND estado_revision = 'PENDIENTE';
  IF NOT FOUND THEN RAISE EXCEPTION 'Ese documento ya fue revisado y no se puede retirar'; END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.d6_alta_compartida(p_solicitud_id UUID)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_sol public.solicitudes_alta;
  v_editable BOOLEAN;
BEGIN
  SELECT * INTO v_sol FROM public.solicitudes_alta WHERE id = p_solicitud_id;
  IF NOT FOUND OR NOT public.d6_puede_ver_beneficiario(v_sol.beneficiario_id) THEN
    RAISE EXCEPTION 'Solicitud no encontrada';
  END IF;
  v_editable := public.d6_alta_editable(v_sol);
  RETURN jsonb_build_object(
    'id', v_sol.id,
    'numero_solicitud', v_sol.numero_solicitud,
    'estado', v_sol.estado_operativo,
    'tipo_persona', v_sol.tipo_persona,
    'afianzado', v_sol.cliente_nombre_tmp,
    'monto_solicitado', v_sol.monto_solicitado,
    'editable', v_editable,
    'recibe_documentos', public.d6_alta_recibe_documentos(v_sol),
    'enviado', v_sol.ive_completed_at IS NOT NULL,
    -- Mientras se llena, la marca ve el borrador para adelantar. Ya enviado, el IVE es de Fidelis.
    'borrador', CASE WHEN v_editable THEN COALESCE(v_sol.ive_borrador, '{}'::jsonb) END,
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

-- Sin pedir firmas que el distribuidor no sabe conseguir.
UPDATE public.ive_requisitos_d6 SET ayuda = 'Lista de sus bienes y deudas.' WHERE categoria = 'ESTADO_PATRIMONIAL';
