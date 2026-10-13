-- Migracion 022: expediente D-6 de punta a punta.
--
-- Lleva al modelo lo que muestran el procedimiento v01 y los casos reales:
--   * La "aprobacion de fianza" que llega es la resolucion de credito de la marca.
--     Se guarda aparte de la decision de Suscripcion.
--   * El afianzado llena el IVE y sube su expediente desde el portal con su enlace.
--   * Suscripcion lleva un checklist de analisis, acepta o rechaza cada documento y
--     decide (total, parcial, no elegible, suspendida, informacion complementaria).
--   * La emision exige numero de contrato y calcula prima, derechos e IVA.
--   * Las bajas se aprueban por RPC y siguen el calendario de cobro a mes vencido.
--   * Vigencia calculada por fechas, no por STATUS.

-- ============================================================================
-- 1. Columnas nuevas
-- ============================================================================
ALTER TABLE public.solicitudes_alta
  ADD COLUMN IF NOT EXISTS tipo_persona public.tipo_persona,
  ADD COLUMN IF NOT EXISTS cliente_email_tmp TEXT,
  ADD COLUMN IF NOT EXISTS cliente_telefono_tmp TEXT,
  ADD COLUMN IF NOT EXISTS resolucion_marca_numero TEXT,
  ADD COLUMN IF NOT EXISTS resolucion_marca_fecha DATE,
  ADD COLUMN IF NOT EXISTS resolucion_marca_monto NUMERIC(15,2),
  ADD COLUMN IF NOT EXISTS resolucion_marca_plazo_dias INTEGER,
  ADD COLUMN IF NOT EXISTS ive_borrador JSONB,
  ADD COLUMN IF NOT EXISTS analisis_suscripcion JSONB NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS contragarantia TEXT,
  ADD COLUMN IF NOT EXISTS faltantes JSONB NOT NULL DEFAULT '[]'::jsonb;

UPDATE public.solicitudes_alta sa SET tipo_persona = c.tipo_persona
FROM public.clientes c WHERE c.id = sa.cliente_id AND sa.tipo_persona IS NULL;
UPDATE public.solicitudes_alta SET tipo_persona = 'INDIVIDUAL' WHERE tipo_persona IS NULL;
ALTER TABLE public.solicitudes_alta ALTER COLUMN tipo_persona SET DEFAULT 'INDIVIDUAL';
ALTER TABLE public.solicitudes_alta ALTER COLUMN tipo_persona SET NOT NULL;

ALTER TABLE public.solicitud_revisiones
  ADD COLUMN IF NOT EXISTS faltantes JSONB;

ALTER TABLE public.documentos
  ADD COLUMN IF NOT EXISTS origen TEXT NOT NULL DEFAULT 'FIDELIS'
    CHECK (origen IN ('AFIANZADO', 'FIDELIS', 'MARCA')),
  ADD COLUMN IF NOT EXISTS carga_pendiente BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS carga_expira TIMESTAMPTZ;

ALTER TABLE public.grupos_beneficiarios
  ADD COLUMN IF NOT EXISTS tarifa_prima NUMERIC(6,4) NOT NULL DEFAULT 0.02,
  ADD COLUMN IF NOT EXISTS codigo_regla_cobro TEXT;

-- Tarifas observadas en d6-consignacion.csv: 2 % general, 2.25 % UMA.
UPDATE public.grupos_beneficiarios SET tarifa_prima = 0.0225, codigo_regla_cobro = 'GRUPO_UMA'
WHERE codigo = 'GRP-UNIDADES-MOVILES';
UPDATE public.grupos_beneficiarios SET codigo_regla_cobro = 'ADMOSA'
WHERE codigo = 'GRP-CENTRAL-MOTOPREMIUM';

ALTER TABLE public.ive_requisitos_d6
  ADD COLUMN IF NOT EXISTS orden INTEGER NOT NULL DEFAULT 100,
  ADD COLUMN IF NOT EXISTS ayuda TEXT;

UPDATE storage.buckets SET file_size_limit = 15728640 WHERE id = 'expedientes';

-- ============================================================================
-- 2. Catalogo de requisitos 2026.2
-- ============================================================================
UPDATE public.ive_requisitos_d6 SET activo = false WHERE version = 'FIDELIS-D6-2026.1';

INSERT INTO public.ive_requisitos_d6 (version, tipo_persona, categoria, nombre, obligatorio, requiere_umbral_exposicion, orden, ayuda)
VALUES
  ('FIDELIS-D6-2026.2', 'INDIVIDUAL', 'IVE_ASS_01', 'Formulario IVE', true, false, 10, 'Se completa en este mismo portal.'),
  ('FIDELIS-D6-2026.2', 'INDIVIDUAL', 'DPI', 'DPI vigente, ambos lados', true, false, 20, NULL),
  ('FIDELIS-D6-2026.2', 'INDIVIDUAL', 'RTU', 'RTU actualizado (constancia de inscripcion SAT)', true, false, 30, NULL),
  ('FIDELIS-D6-2026.2', 'INDIVIDUAL', 'PATENTE_EMPRESA', 'Patente de comercio de empresa', true, false, 40, NULL),
  ('FIDELIS-D6-2026.2', 'INDIVIDUAL', 'RECIBO_SERVICIO', 'Recibo de agua, luz o telefono de la direccion declarada', true, false, 50, 'Puede estar a nombre de otra persona si la direccion coincide.'),
  ('FIDELIS-D6-2026.2', 'INDIVIDUAL', 'ESTADO_CUENTA', 'Estados de cuenta bancarios de los ultimos 3 meses', true, false, 60, 'Los tres meses mas recientes, con el nombre del titular visible.'),
  ('FIDELIS-D6-2026.2', 'INDIVIDUAL', 'ESTADO_PATRIMONIAL', 'Estado patrimonial firmado', true, false, 70, NULL),
  ('FIDELIS-D6-2026.2', 'INDIVIDUAL', 'APROBACION_FIANZA', 'Resolucion de credito de la marca', true, false, 80, 'Nota de resolucion o solicitud de distribucion aprobada por la marca.'),
  ('FIDELIS-D6-2026.2', 'INDIVIDUAL', 'ESTADOS_FINANCIEROS', 'Estados financieros (balance y estado de resultados)', false, false, 90, 'Solo si su RTU indica contador registrado o regimen sobre utilidades.'),
  ('FIDELIS-D6-2026.2', 'INDIVIDUAL', 'DOCUMENTO_ACCESORIO', 'Documento accesorio de contragarantia', true, true, 100, 'Requerido cuando el monto o la exposicion total supera Q300,000.'),
  ('FIDELIS-D6-2026.2', 'JURIDICA', 'IVE_ASS_02', 'Formulario IVE de persona juridica', true, false, 10, 'Se completa en este mismo portal.'),
  ('FIDELIS-D6-2026.2', 'JURIDICA', 'RTU', 'RTU actualizado de la entidad', true, false, 20, NULL),
  ('FIDELIS-D6-2026.2', 'JURIDICA', 'PATENTE_SOCIEDAD', 'Patente de comercio de sociedad', true, false, 30, NULL),
  ('FIDELIS-D6-2026.2', 'JURIDICA', 'PATENTE_EMPRESA', 'Patente de comercio de empresa', true, false, 40, NULL),
  ('FIDELIS-D6-2026.2', 'JURIDICA', 'ESCRITURA_CONSTITUCION', 'Escritura de constitucion y modificaciones', true, false, 50, NULL),
  ('FIDELIS-D6-2026.2', 'JURIDICA', 'NOMBRAMIENTO_REPRESENTANTE', 'Nombramiento vigente del representante legal', true, false, 60, NULL),
  ('FIDELIS-D6-2026.2', 'JURIDICA', 'DPI', 'DPI del representante legal', true, false, 70, NULL),
  ('FIDELIS-D6-2026.2', 'JURIDICA', 'ESTADO_CUENTA', 'Estados de cuenta bancarios de los ultimos 3 meses', true, false, 80, NULL),
  ('FIDELIS-D6-2026.2', 'JURIDICA', 'ESTADOS_FINANCIEROS', 'Estados financieros del ultimo cierre', true, false, 90, NULL),
  ('FIDELIS-D6-2026.2', 'JURIDICA', 'APROBACION_FIANZA', 'Resolucion de credito de la marca', true, false, 100, NULL),
  ('FIDELIS-D6-2026.2', 'JURIDICA', 'DOCUMENTO_ACCESORIO', 'Documento accesorio de contragarantia', true, true, 110, 'Requerido cuando el monto o la exposicion total supera Q300,000.')
ON CONFLICT (version, tipo_persona, categoria) DO UPDATE SET
  nombre = EXCLUDED.nombre, obligatorio = EXCLUDED.obligatorio,
  requiere_umbral_exposicion = EXCLUDED.requiere_umbral_exposicion,
  orden = EXCLUDED.orden, ayuda = EXCLUDED.ayuda, activo = true;

-- ============================================================================
-- 3. Flujo del expediente: una sola tabla de transiciones
-- ============================================================================
-- La interfaz lee esta funcion para decidir que botones mostrar. No hay una copia
-- de la tabla en JavaScript.
CREATE OR REPLACE FUNCTION public.d6_transiciones_alta()
RETURNS JSONB
LANGUAGE sql IMMUTABLE
AS $$
  SELECT jsonb_build_object(
    'BORRADOR',                   jsonb_build_array('IVE_PENDIENTE', 'SUSPENDIDA'),
    'IVE_PENDIENTE',              jsonb_build_array('SUSPENDIDA'),
    'EXPEDIENTE_RECIBIDO',        jsonb_build_array('EN_REVISION', 'INFORMACION_COMPLEMENTARIA', 'SUSPENDIDA'),
    'EN_REVISION',                jsonb_build_array('INFORMACION_COMPLEMENTARIA', 'APROBADA_TOTAL', 'APROBADA_PARCIAL', 'NO_ELEGIBLE', 'SUSPENDIDA'),
    'INFORMACION_COMPLEMENTARIA', jsonb_build_array('EN_REVISION', 'SUSPENDIDA'),
    'SUSPENDIDA',                 jsonb_build_array('EN_REVISION', 'NO_ELEGIBLE'),
    'APROBADA_TOTAL',             jsonb_build_array('SUSPENDIDA'),
    'APROBADA_PARCIAL',           jsonb_build_array('SUSPENDIDA'),
    'NO_ELEGIBLE',                jsonb_build_array(),
    'EMITIDA',                    jsonb_build_array()
  );
$$;
GRANT EXECUTE ON FUNCTION public.d6_transiciones_alta() TO authenticated;

-- Documentos obligatorios para un expediente. El IVE cuenta como entregado si el
-- afianzado lo envio por el portal. Un documento rechazado o a medio subir no cuenta.
CREATE OR REPLACE FUNCTION public.d6_documentos_faltantes(p_solicitud_id UUID)
RETURNS TABLE(categoria public.doc_categoria, nombre TEXT)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT r.categoria, r.nombre
  FROM public.solicitudes_alta sa
  JOIN public.ive_requisitos_d6 r ON r.tipo_persona = sa.tipo_persona AND r.activo AND r.obligatorio
  WHERE sa.id = p_solicitud_id
    AND (NOT r.requiere_umbral_exposicion OR sa.requiere_documento_accesorio)
    AND NOT (r.categoria IN ('IVE_ASS_01', 'IVE_ASS_02') AND sa.ive_data IS NOT NULL)
    AND NOT EXISTS (
      SELECT 1 FROM public.documentos d
      WHERE d.solicitud_alta_id = sa.id AND d.categoria = r.categoria
        AND NOT d.carga_pendiente AND d.estado_revision <> 'RECHAZADO'
    )
  ORDER BY r.orden;
$$;

REVOKE EXECUTE ON FUNCTION public.d6_documentos_faltantes(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.d6_documentos_faltantes(UUID) TO authenticated;

CREATE OR REPLACE FUNCTION public.validar_documentos_ive_d6(p_solicitud_id UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_faltan TEXT;
BEGIN
  SELECT string_agg(nombre, ', ') INTO v_faltan FROM public.d6_documentos_faltantes(p_solicitud_id);
  IF v_faltan IS NOT NULL THEN
    RAISE EXCEPTION 'Faltan documentos obligatorios: %', v_faltan;
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

  IF p_estado = 'EN_REVISION' THEN
    PERFORM public.validar_documentos_ive_d6(p_solicitud_id);
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
    faltantes = CASE WHEN p_estado IN ('INFORMACION_COMPLEMENTARIA', 'SUSPENDIDA')
                     THEN COALESCE(p_faltantes, '[]'::jsonb) ELSE '[]'::jsonb END,
    resolucion_comentario = p_comentario,
    revisado_por = auth.uid()
  WHERE id = p_solicitud_id;

  INSERT INTO public.solicitud_revisiones (solicitud_alta_id, estado_anterior, estado_nuevo, comentario, monto_aprobado, faltantes, creado_por)
  VALUES (p_solicitud_id, v_sol.estado_operativo, p_estado, p_comentario,
          CASE WHEN p_estado = 'APROBADA_TOTAL' THEN v_sol.monto_solicitado ELSE p_monto_aprobado END,
          p_faltantes, auth.uid());
END;
$$;

DROP FUNCTION IF EXISTS public.transicionar_solicitud_alta(UUID, public.d6_solicitud_status, TEXT, NUMERIC, TEXT);
REVOKE EXECUTE ON FUNCTION public.transicionar_solicitud_alta(UUID, public.d6_solicitud_status, TEXT, NUMERIC, TEXT, JSONB, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.transicionar_solicitud_alta(UUID, public.d6_solicitud_status, TEXT, NUMERIC, TEXT, JSONB, TEXT) TO authenticated;

-- Informacion complementaria: Suscripcion reabre el enlace para que el afianzado
-- complete lo que falta. Mismo enlace, mismo portal.
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
    RAISE EXCEPTION 'No tiene permiso para enviar el enlace de este expediente';
  END IF;
  v_correo := COALESCE(NULLIF(btrim(p_destinatario_email), ''), v_solicitud.cliente_email_tmp);
  IF v_correo IS NULL OR v_correo !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
    RAISE EXCEPTION 'Indique un correo valido para el afianzado';
  END IF;
  IF v_solicitud.estado_operativo NOT IN ('BORRADOR', 'IVE_PENDIENTE', 'INFORMACION_COMPLEMENTARIA')
     AND NOT (v_es_personal AND v_solicitud.estado_operativo = 'SUSPENDIDA') THEN
    RAISE EXCEPTION 'El expediente esta en estado % y no admite un enlace nuevo', v_solicitud.estado_operativo;
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

-- ============================================================================
-- 4. Solicitud de alta (marca o personal)
-- ============================================================================
DROP FUNCTION IF EXISTS public.d6_marca_crear_solicitud_alta(
  INTEGER, TEXT, TEXT, NUMERIC, TEXT, TEXT, public.tipo_persona, DATE, DATE, TEXT, INTEGER);

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
    RAISE EXCEPTION 'El nombre del afianzado es obligatorio';
  END IF;
  IF p_cliente_email IS NULL OR btrim(p_cliente_email) !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
    RAISE EXCEPTION 'El correo del afianzado es obligatorio y debe ser valido: ahi recibe el enlace del expediente';
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
            COALESCE(p_tipo_persona, 'INDIVIDUAL'), NULLIF(btrim(COALESCE(p_cliente_telefono, '')), ''), btrim(p_cliente_email))
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
    v_numero, v_cliente_id, v_nombre, NULLIF(btrim(COALESCE(p_cliente_nit, '')), ''), btrim(p_cliente_email),
    NULLIF(btrim(COALESCE(p_cliente_telefono, '')), ''), COALESCE(p_tipo_persona, 'INDIVIDUAL'),
    v_beneficiario.id, p_monto, CURRENT_DATE, (CURRENT_DATE + INTERVAL '1 year' - INTERVAL '1 day')::date,
    'Consignacion comercial de linea de productos',
    NULLIF(btrim(COALESCE(p_resolucion_numero, '')), ''), p_resolucion_fecha, p_resolucion_monto, p_resolucion_plazo_dias,
    NULLIF(btrim(COALESCE(p_observaciones, '')), ''), 'BORRADOR', 'IVE_PENDIENTE',
    (p_monto > 300000 OR p_monto + v_exposicion > 300000), v_exposicion, auth.uid()
  )
  RETURNING id INTO v_solicitud_id;

  INSERT INTO public.ive_invitaciones (solicitud_alta_id, token_hash, destinatario_email, expires_at, created_by)
  VALUES (v_solicitud_id, encode(extensions.digest(v_token, 'sha256'), 'hex'), btrim(p_cliente_email), v_expira, auth.uid());
  INSERT INTO public.solicitud_revisiones (solicitud_alta_id, estado_anterior, estado_nuevo, comentario, creado_por)
  VALUES (v_solicitud_id, NULL, 'IVE_PENDIENTE', 'Alta solicitada', auth.uid());

  RETURN QUERY SELECT v_solicitud_id, v_numero, v_token, v_expira;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.d6_solicitar_alta(
  INTEGER, TEXT, TEXT, NUMERIC, public.tipo_persona, TEXT, TEXT, TEXT, DATE, NUMERIC, INTEGER, TEXT, INTEGER
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.d6_solicitar_alta(
  INTEGER, TEXT, TEXT, NUMERIC, public.tipo_persona, TEXT, TEXT, TEXT, DATE, NUMERIC, INTEGER, TEXT, INTEGER
) TO authenticated;

-- ============================================================================
-- 5. Portal del afianzado (sin sesion, con el enlace)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.d6_invitacion_por_token(p_token TEXT)
RETURNS public.ive_invitaciones
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions
AS $$
  SELECT * FROM public.ive_invitaciones
  WHERE token_hash = encode(extensions.digest(COALESCE(p_token, ''), 'sha256'), 'hex')
  LIMIT 1;
$$;
REVOKE EXECUTE ON FUNCTION public.d6_invitacion_por_token(TEXT) FROM PUBLIC, anon, authenticated;

-- Valida el enlace y devuelve la solicitud abierta. Lanza error si no sirve.
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
  IF v_sol.estado_operativo NOT IN ('IVE_PENDIENTE', 'INFORMACION_COMPLEMENTARIA') THEN
    RAISE EXCEPTION 'Este expediente ya no recibe cambios (estado %)', v_sol.estado_operativo;
  END IF;
  RETURN v_sol;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.d6_portal_solicitud(TEXT) FROM PUBLIC, anon, authenticated;

-- Lo que el afianzado necesita ver: nada de otra persona ni de otra marca.
CREATE OR REPLACE FUNCTION public.portal_ive_contexto(p_token TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_inv public.ive_invitaciones;
  v_sol public.solicitudes_alta;
  v_motivo TEXT;
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
  IF v_sol.estado_operativo NOT IN ('IVE_PENDIENTE', 'INFORMACION_COMPLEMENTARIA') THEN
    RETURN jsonb_build_object('valido', false, 'motivo', 'CERRADO');
  END IF;

  RETURN jsonb_build_object(
    'valido', true,
    'numero_solicitud', v_sol.numero_solicitud,
    'estado', v_sol.estado_operativo,
    'marca', (SELECT nombre FROM public.beneficiarios WHERE id = v_sol.beneficiario_id),
    'afianzado', v_sol.cliente_nombre_tmp,
    'tipo_persona', v_sol.tipo_persona,
    'monto_solicitado', v_sol.monto_solicitado,
    'expira', v_inv.expires_at,
    'comentario', CASE WHEN v_sol.estado_operativo = 'INFORMACION_COMPLEMENTARIA' THEN v_sol.resolucion_comentario END,
    'faltantes', v_sol.faltantes,
    'borrador', COALESCE(v_sol.ive_borrador, v_sol.ive_data),
    'requisitos', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'categoria', r.categoria, 'nombre', r.nombre, 'ayuda', r.ayuda, 'obligatorio', r.obligatorio,
        'documentos', COALESCE((
          SELECT jsonb_agg(jsonb_build_object(
            'id', d.id, 'nombre_archivo', d.nombre_archivo, 'estado', d.estado_revision,
            'comentario', d.comentario_revision, 'subido', d.created_at) ORDER BY d.created_at)
          FROM public.documentos d
          WHERE d.solicitud_alta_id = v_sol.id AND d.categoria = r.categoria AND NOT d.carga_pendiente
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
  IF pg_column_size(p_datos) > 512000 THEN
    RAISE EXCEPTION 'El borrador es demasiado grande';
  END IF;
  UPDATE public.solicitudes_alta SET ive_borrador = p_datos WHERE id = v_sol.id;
END;
$$;

-- Carga en dos pasos sin Edge Function. 1) La RPC valida el enlace, reserva una ruta
-- aleatoria y deja un registro con carga_pendiente. 2) El navegador sube a esa ruta:
-- la politica de Storage solo admite rutas reservadas hace menos de 15 minutos.
-- 3) La confirmacion verifica que el archivo exista y libera el registro.
CREATE OR REPLACE FUNCTION public.portal_ive_preparar_carga(
  p_token TEXT, p_categoria public.doc_categoria, p_nombre_archivo TEXT, p_mime TEXT, p_tamano INTEGER
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
  v_sol := public.d6_portal_solicitud(p_token);
  IF p_mime NOT IN ('application/pdf', 'image/png', 'image/jpeg') THEN
    RAISE EXCEPTION 'Solo se aceptan archivos PDF, PNG o JPG';
  END IF;
  IF COALESCE(p_tamano, 0) <= 0 OR p_tamano > 15728640 THEN
    RAISE EXCEPTION 'El archivo debe pesar menos de 15 MB';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.ive_requisitos_d6 r
    WHERE r.activo AND r.tipo_persona = v_sol.tipo_persona AND r.categoria = p_categoria
  ) THEN
    RAISE EXCEPTION 'Ese tipo de documento no corresponde a este expediente';
  END IF;
  IF (SELECT count(*) FROM public.documentos WHERE solicitud_alta_id = v_sol.id) >= 60 THEN
    RAISE EXCEPTION 'El expediente alcanzo el limite de archivos. Contacte a Fidelis.';
  END IF;

  v_ext := CASE p_mime WHEN 'application/pdf' THEN 'pdf' WHEN 'image/png' THEN 'png' ELSE 'jpg' END;
  v_id := gen_random_uuid();
  v_path := 'altas/' || v_sol.id || '/' || v_id || '.' || v_ext;

  INSERT INTO public.documentos (id, solicitud_alta_id, categoria, nombre_archivo, file_path, file_size, mime_type,
                                 origen, carga_pendiente, carga_expira, requerido)
  VALUES (v_id, v_sol.id, p_categoria, left(regexp_replace(COALESCE(p_nombre_archivo, 'documento'), '[\\/]', '_', 'g'), 180),
          v_path, p_tamano, p_mime, 'AFIANZADO', true, now() + INTERVAL '15 minutes', true);
  RETURN jsonb_build_object('documento_id', v_id, 'path', v_path);
END;
$$;

CREATE OR REPLACE FUNCTION public.portal_ive_confirmar_carga(p_token TEXT, p_documento_id UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, storage
AS $$
DECLARE
  v_sol public.solicitudes_alta;
  v_doc public.documentos;
BEGIN
  v_sol := public.d6_portal_solicitud(p_token);
  SELECT * INTO v_doc FROM public.documentos
  WHERE id = p_documento_id AND solicitud_alta_id = v_sol.id AND carga_pendiente FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No hay una carga pendiente con ese identificador'; END IF;
  IF NOT EXISTS (SELECT 1 FROM storage.objects o WHERE o.bucket_id = 'expedientes' AND o.name = v_doc.file_path) THEN
    RAISE EXCEPTION 'El archivo no llego al servidor. Intente subirlo de nuevo.';
  END IF;

  -- Un archivo nuevo de la misma categoria reemplaza a los anteriores no aprobados.
  UPDATE public.documentos SET estado_revision = 'RECHAZADO', comentario_revision = 'Reemplazado por una carga nueva del afianzado'
  WHERE solicitud_alta_id = v_sol.id AND categoria = v_doc.categoria AND id <> v_doc.id
    AND origen = 'AFIANZADO' AND estado_revision = 'PENDIENTE' AND NOT carga_pendiente;
  UPDATE public.documentos SET carga_pendiente = false, carga_expira = NULL WHERE id = v_doc.id;
END;
$$;

CREATE OR REPLACE FUNCTION public.portal_ive_quitar_documento(p_token TEXT, p_documento_id UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_sol public.solicitudes_alta;
BEGIN
  v_sol := public.d6_portal_solicitud(p_token);
  UPDATE public.documentos SET estado_revision = 'RECHAZADO', comentario_revision = 'Retirado por el afianzado'
  WHERE id = p_documento_id AND solicitud_alta_id = v_sol.id AND origen = 'AFIANZADO' AND estado_revision = 'PENDIENTE';
  IF NOT FOUND THEN RAISE EXCEPTION 'Ese documento ya fue revisado y no se puede retirar'; END IF;
END;
$$;

-- Envio final: guarda el IVE y exige el expediente completo.
CREATE OR REPLACE FUNCTION public.completar_ive_invitacion(p_token TEXT, p_datos JSONB)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_sol public.solicitudes_alta;
  v_inv public.ive_invitaciones;
BEGIN
  v_sol := public.d6_portal_solicitud(p_token);
  v_inv := public.d6_invitacion_por_token(p_token);
  PERFORM public.validar_datos_ive_d6(p_datos);
  IF (v_sol.tipo_persona = 'INDIVIDUAL' AND p_datos->>'tipoIve' NOT IN ('IVE-ASS-01', 'IVE-IR-01'))
     OR (v_sol.tipo_persona = 'JURIDICA' AND p_datos->>'tipoIve' NOT IN ('IVE-ASS-02', 'IVE-IR-02')) THEN
    RAISE EXCEPTION 'El formulario no corresponde al tipo de cliente del expediente';
  END IF;

  PERFORM 1 FROM public.ive_invitaciones WHERE id = v_inv.id FOR UPDATE;
  UPDATE public.solicitudes_alta
  SET ive_data = p_datos,
      ive_borrador = NULL,
      ive_form_version = COALESCE(NULLIF(p_datos->>'versionFormulario', ''), 'FIDELIS-D6-2026.2'),
      ive_completed_at = now()
  WHERE id = v_sol.id;
  PERFORM public.validar_documentos_ive_d6(v_sol.id);

  UPDATE public.ive_invitaciones SET used_at = now() WHERE id = v_inv.id;
  UPDATE public.solicitudes_alta SET estado_operativo = 'EXPEDIENTE_RECIBIDO', faltantes = '[]'::jsonb WHERE id = v_sol.id;
  INSERT INTO public.solicitud_revisiones (solicitud_alta_id, estado_anterior, estado_nuevo, comentario, creado_por)
  VALUES (v_sol.id, v_sol.estado_operativo, 'EXPEDIENTE_RECIBIDO', 'Expediente enviado por el afianzado', NULL);
  RETURN v_sol.id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.portal_ive_contexto(TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.portal_ive_guardar_borrador(TEXT, JSONB) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.portal_ive_preparar_carga(TEXT, public.doc_categoria, TEXT, TEXT, INTEGER) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.portal_ive_confirmar_carga(TEXT, UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.portal_ive_quitar_documento(TEXT, UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.completar_ive_invitacion(TEXT, JSONB) TO anon, authenticated;

-- Storage: el portal solo puede escribir en una ruta reservada y vigente. La politica
-- corre como anon, que no lee documentos, por eso el chequeo va en una funcion definer.
CREATE OR REPLACE FUNCTION public.d6_ruta_reservada(p_name TEXT)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.documentos d
    WHERE d.file_path = p_name AND d.carga_pendiente AND d.carga_expira > now()
  );
$$;
GRANT EXECUTE ON FUNCTION public.d6_ruta_reservada(TEXT) TO anon, authenticated;

DROP POLICY IF EXISTS "expedientes: afianzado sube a ruta reservada" ON storage.objects;
CREATE POLICY "expedientes: afianzado sube a ruta reservada" ON storage.objects FOR INSERT
  TO anon, authenticated
  WITH CHECK (
    bucket_id = 'expedientes'
    AND split_part(name, '/', 1) = 'altas'
    AND public.d6_ruta_reservada(name)
  );

-- ============================================================================
-- 6. Emision
-- ============================================================================
DROP FUNCTION IF EXISTS public.emitir_fianza_d6(UUID, BIGINT, DATE, DATE, NUMERIC, TEXT);

CREATE OR REPLACE FUNCTION public.emitir_fianza_d6(
  p_solicitud_id UUID,
  p_numero_fianza BIGINT,
  p_vigencia_desde DATE,
  p_vigencia_hasta DATE,
  p_prima NUMERIC,
  p_derechos NUMERIC,
  p_iva NUMERIC,
  p_contrato_numero TEXT,
  p_contrato_fecha DATE,
  p_lote_fiso TEXT DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_sol public.solicitudes_alta%ROWTYPE;
  v_contrato_id UUID;
  v_fianza_id UUID;
  v_monto NUMERIC(15,2);
  v_agente UUID;
BEGIN
  IF NOT public.has_d6_role(ARRAY['admin', 'suscripcion']::public.d6_role[]) THEN
    RAISE EXCEPTION 'Solo Suscripcion puede confirmar una emision';
  END IF;
  SELECT * INTO v_sol FROM public.solicitudes_alta WHERE id = p_solicitud_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Solicitud no encontrada'; END IF;
  IF v_sol.estado_operativo NOT IN ('APROBADA_TOTAL', 'APROBADA_PARCIAL') THEN
    RAISE EXCEPTION 'El expediente debe estar aprobado antes de emitir';
  END IF;
  IF COALESCE(p_numero_fianza, 0) <= 0 THEN RAISE EXCEPTION 'Indique el numero de fianza de FISO'; END IF;
  IF EXISTS (SELECT 1 FROM public.fianzas WHERE fianza = p_numero_fianza) THEN
    RAISE EXCEPTION 'La fianza % ya existe', p_numero_fianza;
  END IF;
  IF NULLIF(btrim(COALESCE(p_contrato_numero, '')), '') IS NULL OR p_contrato_fecha IS NULL THEN
    RAISE EXCEPTION 'Indique el numero y la fecha de la escritura del contrato de consignacion';
  END IF;
  IF p_vigencia_desde IS NULL OR p_vigencia_hasta IS NULL OR p_vigencia_hasta <= p_vigencia_desde THEN
    RAISE EXCEPTION 'Revise las fechas de vigencia';
  END IF;
  IF COALESCE(p_prima, 0) <= 0 THEN RAISE EXCEPTION 'La prima debe ser mayor que cero'; END IF;

  v_monto := COALESCE(v_sol.monto_aprobado, v_sol.monto_solicitado);
  SELECT id INTO v_agente FROM public.agentes WHERE numero_agente = 0 AND indice_agente = 0 LIMIT 1;

  -- Contrato a 5 anos: se reutiliza el vigente del mismo afianzado con la misma marca.
  SELECT id INTO v_contrato_id FROM public.contratos_consignacion
  WHERE cliente_id = v_sol.cliente_id AND beneficiario_id = v_sol.beneficiario_id
    AND estado = 'VIGENTE' AND fecha_fin >= p_vigencia_desde
  ORDER BY fecha_inicio DESC LIMIT 1;
  IF v_contrato_id IS NULL THEN
    INSERT INTO public.contratos_consignacion (numero, cliente_id, beneficiario_id, agente_id, fecha_inicio, fecha_fin, valor)
    VALUES (btrim(p_contrato_numero), v_sol.cliente_id, v_sol.beneficiario_id, COALESCE(v_sol.agente_id, v_agente),
            p_contrato_fecha, (p_contrato_fecha + INTERVAL '5 years')::date, v_monto)
    ON CONFLICT (numero) DO NOTHING
    RETURNING id INTO v_contrato_id;
    IF v_contrato_id IS NULL THEN
      RAISE EXCEPTION 'Ya existe un contrato con el numero %. Verifique la escritura.', p_contrato_numero;
    END IF;
  END IF;

  INSERT INTO public.fianzas (
    fianza, endoso, cliente_id, beneficiario_id, agente_id, fecha_emision, vigencia_desde, vigencia_hasta,
    cod_estado_poliza, status_raw, status, operational_status,
    monto_afianzado, prima, derechos, iva, prima_anual, contrato_id, contrato_numero, contrato_fecha,
    contrato_valor, tema_de_fianza, lote_fiso
  ) VALUES (
    p_numero_fianza, 0, v_sol.cliente_id, v_sol.beneficiario_id, COALESCE(v_sol.agente_id, v_agente),
    CURRENT_DATE, p_vigencia_desde, p_vigencia_hasta, 'EN', 'V', 'VIGENTE', 'VIGENTE',
    v_monto, round(p_prima, 2), round(COALESCE(p_derechos, 0), 2), round(COALESCE(p_iva, 0), 2), round(p_prima, 2),
    v_contrato_id, btrim(p_contrato_numero), p_contrato_fecha, v_monto, v_sol.tema_de_fianza,
    NULLIF(btrim(COALESCE(p_lote_fiso, '')), '')
  ) RETURNING id INTO v_fianza_id;

  UPDATE public.solicitudes_alta SET
    estado_operativo = 'EMITIDA', estado = 'APROBADA', contrato_id = v_contrato_id,
    contrato_numero = btrim(p_contrato_numero), contrato_fecha = p_contrato_fecha, contrato_valor = v_monto,
    vigencia_desde = p_vigencia_desde, vigencia_hasta = p_vigencia_hasta,
    emitida_en = now(), revisado_por = auth.uid()
  WHERE id = p_solicitud_id;
  INSERT INTO public.solicitud_revisiones (solicitud_alta_id, estado_anterior, estado_nuevo, comentario, monto_aprobado, creado_por)
  VALUES (p_solicitud_id, v_sol.estado_operativo, 'EMITIDA', 'Fianza ' || p_numero_fianza || ' emitida', v_monto, auth.uid());
  RETURN v_fianza_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.emitir_fianza_d6(UUID, BIGINT, DATE, DATE, NUMERIC, NUMERIC, NUMERIC, TEXT, DATE, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.emitir_fianza_d6(UUID, BIGINT, DATE, DATE, NUMERIC, NUMERIC, NUMERIC, TEXT, DATE, TEXT) TO authenticated;

-- ============================================================================
-- 7. Bajas
-- ============================================================================
-- Calendario de cobro a mes vencido: la baja pedida en el mes A se cobra completa en
-- el estado de cuenta del mes B y Fidelis la cierra cuando ese pago queda aplicado.
-- Aprobar deja la poliza en PENDIENTE_ANULACION con fecha efectiva al cierre del mes A.

CREATE OR REPLACE FUNCTION public.d6_solicitar_baja(
  p_fianza_id UUID, p_tipo public.tipo_baja, p_motivo TEXT
) RETURNS TABLE(baja_id UUID, numero_solicitud TEXT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_f public.fianzas%ROWTYPE;
  v_id UUID;
  v_numero TEXT;
BEGIN
  SELECT * INTO v_f FROM public.fianzas WHERE id = p_fianza_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Poliza no encontrada'; END IF;
  IF NOT public.has_d6_role(ARRAY['admin', 'comercial', 'suscripcion']::public.d6_role[])
     AND NOT public.d6_beneficiario_es_mio(v_f.beneficiario_id) THEN
    RAISE EXCEPTION 'No puede pedir la baja de una poliza que no es de su marca';
  END IF;
  IF v_f.operational_status IN ('CANCELADA', 'ANULADA', 'PENDIENTE_ANULACION') THEN
    RAISE EXCEPTION 'La poliza ya esta cancelada o en proceso de baja';
  END IF;
  IF EXISTS (SELECT 1 FROM public.solicitudes_baja WHERE fianza_id = p_fianza_id AND estado = 'PENDIENTE_REVISION') THEN
    RAISE EXCEPTION 'Ya hay una solicitud de baja pendiente para esta poliza';
  END IF;
  IF NULLIF(btrim(COALESCE(p_motivo, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Describa el motivo de la baja';
  END IF;
  v_numero := 'BAJ-' || to_char(now(), 'YYYY') || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
  INSERT INTO public.solicitudes_baja (numero_solicitud, fianza_id, tipo_baja, motivo, estado, solicitado_por)
  VALUES (v_numero, p_fianza_id, COALESCE(p_tipo, 'OTRO'), btrim(p_motivo), 'PENDIENTE_REVISION', auth.uid())
  RETURNING id INTO v_id;
  RETURN QUERY SELECT v_id, v_numero;
END;
$$;

CREATE OR REPLACE FUNCTION public.d6_resolver_baja(p_baja_id UUID, p_aprobar BOOLEAN, p_comentario TEXT DEFAULT NULL)
RETURNS DATE
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_b public.solicitudes_baja%ROWTYPE;
  v_efectiva DATE;
BEGIN
  IF NOT public.has_d6_role(ARRAY['admin', 'suscripcion']::public.d6_role[]) THEN
    RAISE EXCEPTION 'Solo Suscripcion resuelve bajas';
  END IF;
  SELECT * INTO v_b FROM public.solicitudes_baja WHERE id = p_baja_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Solicitud de baja no encontrada'; END IF;
  IF v_b.estado <> 'PENDIENTE_REVISION' THEN RAISE EXCEPTION 'La solicitud ya fue resuelta'; END IF;

  IF NOT p_aprobar THEN
    IF NULLIF(btrim(COALESCE(p_comentario, '')), '') IS NULL THEN
      RAISE EXCEPTION 'Explique por que se rechaza la baja';
    END IF;
    UPDATE public.solicitudes_baja SET estado = 'RECHAZADA', observaciones = p_comentario, procesado_por = auth.uid()
    WHERE id = p_baja_id;
    RETURN NULL;
  END IF;

  v_efectiva := (date_trunc('month', v_b.created_at) + INTERVAL '1 month - 1 day')::date;
  UPDATE public.solicitudes_baja SET estado = 'APROBADA', observaciones = p_comentario, procesado_por = auth.uid()
  WHERE id = p_baja_id;
  UPDATE public.fianzas SET operational_status = 'PENDIENTE_ANULACION', fecha_cancelacion = v_efectiva
  WHERE id = v_b.fianza_id;
  RETURN v_efectiva;
END;
$$;

-- Cierre: con el ultimo mes cobrado, la poliza queda cancelada.
CREATE OR REPLACE FUNCTION public.d6_cerrar_baja(p_baja_id UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_b public.solicitudes_baja%ROWTYPE;
BEGIN
  IF NOT public.has_d6_role(ARRAY['admin', 'suscripcion', 'cobros']::public.d6_role[]) THEN
    RAISE EXCEPTION 'Solo Suscripcion o Cobros cierran una baja';
  END IF;
  SELECT * INTO v_b FROM public.solicitudes_baja WHERE id = p_baja_id FOR UPDATE;
  IF NOT FOUND OR v_b.estado <> 'APROBADA' THEN RAISE EXCEPTION 'La baja debe estar aprobada para cerrarla'; END IF;
  UPDATE public.fianzas SET operational_status = 'CANCELADA', status = 'CANCELADA', status_raw = 'C'
  WHERE id = v_b.fianza_id AND operational_status = 'PENDIENTE_ANULACION';
  IF NOT FOUND THEN RAISE EXCEPTION 'La poliza no esta pendiente de anulacion'; END IF;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.d6_solicitar_baja(UUID, public.tipo_baja, TEXT) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.d6_resolver_baja(UUID, BOOLEAN, TEXT) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.d6_cerrar_baja(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.d6_solicitar_baja(UUID, public.tipo_baja, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.d6_resolver_baja(UUID, BOOLEAN, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.d6_cerrar_baja(UUID) TO authenticated;

-- La marca solo puede crear bajas por la RPC; ya no por insert directo.
DROP POLICY IF EXISTS "bajas: marca crea solo pendientes de su cartera" ON public.solicitudes_baja;

-- ============================================================================
-- 8. Vistas de lectura (respetan RLS del usuario)
-- ============================================================================
CREATE OR REPLACE VIEW public.v_fianzas
WITH (security_invoker = true)
AS
SELECT
  f.id, f.fianza, f.endoso, f.clase,
  f.cliente_id, c.codigo_contacto AS cliente_codigo, c.nombre AS cliente_nombre, c.nit AS cliente_nit,
  f.beneficiario_id, b.codigo_contacto AS beneficiario_codigo, b.nombre AS beneficiario_nombre,
  g.id AS marca_id, g.nombre AS marca_nombre,
  f.fecha_emision, f.vigencia_desde, f.vigencia_hasta, f.fecha_cancelacion, f.fecha_anulacion,
  f.status_raw, f.cod_estado_poliza, f.operational_status,
  CASE
    WHEN f.operational_status = 'ANULADA' OR f.status = 'ANULADA' THEN 'ANULADA'
    WHEN f.operational_status = 'CANCELADA' OR f.status = 'CANCELADA' OR f.status_raw = 'C' THEN 'CANCELADA'
    WHEN f.operational_status = 'PENDIENTE_ANULACION' THEN 'EN_BAJA'
    WHEN f.vigencia_hasta < CURRENT_DATE THEN 'VENCIDA'
    WHEN f.vigencia_hasta <= CURRENT_DATE + 60 THEN 'POR_RENOVAR'
    ELSE 'VIGENTE'
  END AS estado,
  f.monto_afianzado,
  CASE WHEN COALESCE(f.monto_afianzado, 0) = 0 THEN COALESCE(f.contrato_valor, 0) ELSE f.monto_afianzado END AS monto_original,
  f.prima, f.derechos, f.iva, f.prima_anual,
  f.contrato_numero, f.contrato_fecha, f.contrato_valor, f.lote_fiso, f.dte_numero,
  f.created_at, f.updated_at
FROM public.fianzas f
JOIN public.clientes c ON c.id = f.cliente_id
JOIN public.beneficiarios b ON b.id = f.beneficiario_id
LEFT JOIN LATERAL (
  SELECT gb.id, gb.nombre FROM public.grupo_beneficiario_rel r
  JOIN public.grupos_beneficiarios gb ON gb.id = r.grupo_id
  WHERE r.beneficiario_id = b.id AND gb.codigo <> 'GRP-GENERAL'
  ORDER BY gb.codigo LIMIT 1
) g ON true;
GRANT SELECT ON public.v_fianzas TO authenticated;
REVOKE ALL ON public.v_fianzas FROM anon;

-- Exposicion vigente por afianzado sumando todas las marcas (regla del accesorio).
CREATE OR REPLACE VIEW public.v_exposicion_afianzados
WITH (security_invoker = true)
AS
SELECT
  f.cliente_id,
  count(*) AS polizas_vigentes,
  count(DISTINCT f.beneficiario_id) AS marcas,
  sum(f.monto_afianzado) AS exposicion
FROM public.fianzas f
WHERE f.operational_status IN ('VIGENTE', 'POR_RENOVAR', 'PENDIENTE_ANULACION')
  AND f.vigencia_hasta >= CURRENT_DATE
GROUP BY f.cliente_id;
GRANT SELECT ON public.v_exposicion_afianzados TO authenticated;
REVOKE ALL ON public.v_exposicion_afianzados FROM anon;

-- Bandeja de Suscripcion: un renglon por expediente con lo que hace falta para priorizar.
CREATE OR REPLACE VIEW public.v_bandeja_altas
WITH (security_invoker = true)
AS
SELECT
  sa.id, sa.numero_solicitud, sa.estado_operativo, sa.tipo_persona,
  sa.beneficiario_id, b.nombre AS beneficiario_nombre, b.codigo_contacto AS beneficiario_codigo,
  sa.cliente_id, COALESCE(sa.cliente_nombre_tmp, c.nombre) AS afianzado_nombre,
  COALESCE(sa.cliente_nit_tmp, c.nit) AS afianzado_nit, sa.cliente_email_tmp AS afianzado_email,
  sa.monto_solicitado, sa.monto_aprobado,
  COALESCE(e.exposicion, 0) AS exposicion_actual,
  COALESCE(e.marcas, 0) AS marcas_con_poliza,
  (sa.monto_solicitado > 300000 OR sa.monto_solicitado + COALESCE(e.exposicion, 0) > 300000) AS requiere_accesorio,
  sa.resolucion_marca_numero, sa.resolucion_marca_fecha, sa.resolucion_marca_monto,
  (sa.resolucion_marca_fecha + 30) AS resolucion_vence,
  (COALESCE(sa.ive_data->>'esPEP', sa.ive_data->>'repEsPEP') = 'SI'
     OR sa.ive_data->>'parientePEP' = 'SI' OR sa.ive_data->>'asociadoPEP' = 'SI') AS es_pep,
  sa.ive_completed_at,
  (SELECT count(*) FROM public.d6_documentos_faltantes(sa.id)) AS documentos_faltantes,
  (SELECT count(*) FROM public.documentos d WHERE d.solicitud_alta_id = sa.id AND NOT d.carga_pendiente
     AND d.estado_revision = 'PENDIENTE') AS documentos_por_revisar,
  (SELECT max(r.created_at) FROM public.solicitud_revisiones r WHERE r.solicitud_alta_id = sa.id) AS ultimo_cambio,
  sa.created_at, sa.updated_at, sa.emitida_en
FROM public.solicitudes_alta sa
JOIN public.beneficiarios b ON b.id = sa.beneficiario_id
LEFT JOIN public.clientes c ON c.id = sa.cliente_id
LEFT JOIN public.v_exposicion_afianzados e ON e.cliente_id = sa.cliente_id;
GRANT SELECT ON public.v_bandeja_altas TO authenticated;
REVOKE ALL ON public.v_bandeja_altas FROM anon;

-- La vista de la marca suma el motivo cuando hay que actuar (informacion complementaria).
DROP VIEW IF EXISTS public.v_solicitudes_alta_marca;
CREATE VIEW public.v_solicitudes_alta_marca
WITH (security_barrier = true)
AS
SELECT
  sa.id,
  sa.numero_solicitud,
  sa.beneficiario_id,
  b.codigo_contacto AS beneficiario_codigo,
  b.nombre AS beneficiario_nombre,
  COALESCE(sa.cliente_nombre_tmp, c.nombre) AS afianzado_nombre,
  sa.cliente_email_tmp AS afianzado_email,
  sa.tipo_persona,
  sa.monto_solicitado,
  sa.monto_aprobado,
  sa.estado_operativo,
  CASE WHEN sa.estado_operativo IN ('INFORMACION_COMPLEMENTARIA', 'SUSPENDIDA', 'NO_ELEGIBLE')
       THEN sa.resolucion_comentario END AS motivo,
  sa.faltantes,
  sa.resolucion_marca_numero,
  sa.ive_completed_at IS NOT NULL AS ive_completado,
  inv.expires_at AS enlace_expira,
  f.fianza AS fianza_emitida,
  sa.emitida_en,
  sa.created_at,
  sa.updated_at
FROM public.solicitudes_alta sa
JOIN public.beneficiarios b ON b.id = sa.beneficiario_id
LEFT JOIN public.clientes c ON c.id = sa.cliente_id
LEFT JOIN LATERAL (
  SELECT i.expires_at FROM public.ive_invitaciones i
  WHERE i.solicitud_alta_id = sa.id AND i.used_at IS NULL AND i.revoked_at IS NULL
  ORDER BY i.created_at DESC LIMIT 1
) inv ON true
LEFT JOIN LATERAL (
  SELECT fz.fianza FROM public.fianzas fz
  WHERE sa.estado_operativo = 'EMITIDA' AND fz.cliente_id = sa.cliente_id AND fz.beneficiario_id = sa.beneficiario_id
    AND fz.contrato_id = sa.contrato_id
  ORDER BY fz.created_at DESC LIMIT 1
) f ON true
WHERE public.d6_puede_ver_beneficiario(sa.beneficiario_id);

REVOKE ALL ON public.v_solicitudes_alta_marca FROM PUBLIC, anon;
GRANT SELECT ON public.v_solicitudes_alta_marca TO authenticated;

-- ============================================================================
-- 9. Notificaciones al cambiar el estado operativo
-- ============================================================================
CREATE OR REPLACE FUNCTION public.d6_notificar_estado_alta()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_texto TEXT;
BEGIN
  IF OLD.estado_operativo IS NOT DISTINCT FROM NEW.estado_operativo THEN
    RETURN NEW;
  END IF;
  v_texto := CASE NEW.estado_operativo
    WHEN 'EXPEDIENTE_RECIBIDO' THEN 'El afianzado envio su expediente'
    WHEN 'EN_REVISION' THEN 'Suscripcion empezo la revision'
    WHEN 'INFORMACION_COMPLEMENTARIA' THEN 'Suscripcion pide informacion adicional'
    WHEN 'APROBADA_TOTAL' THEN 'Aprobada por el monto solicitado'
    WHEN 'APROBADA_PARCIAL' THEN 'Aprobada por un monto menor'
    WHEN 'NO_ELEGIBLE' THEN 'No elegible'
    WHEN 'SUSPENDIDA' THEN 'Suspendida'
    WHEN 'EMITIDA' THEN 'Fianza emitida'
    ELSE NULL END;
  IF v_texto IS NULL THEN RETURN NEW; END IF;

  -- Quien pidio el alta y, si es una marca, todos los usuarios de esa marca.
  INSERT INTO public.notificaciones (user_id, titulo, mensaje, link)
  SELECT DISTINCT u.user_id, 'Alta ' || NEW.numero_solicitud,
         v_texto || ': ' || COALESCE(NEW.cliente_nombre_tmp, 'afianzado'), '/altas/' || NEW.id
  FROM (
    SELECT NEW.creado_por AS user_id WHERE NEW.creado_por IS NOT NULL
    UNION
    SELECT ug.user_id FROM public.user_grupos ug
    JOIN public.grupo_beneficiario_rel r ON r.grupo_id = ug.grupo_id
    WHERE r.beneficiario_id = NEW.beneficiario_id
  ) u
  WHERE u.user_id IS DISTINCT FROM auth.uid();

  -- Suscripcion se entera cuando llega un expediente.
  IF NEW.estado_operativo = 'EXPEDIENTE_RECIBIDO' THEN
    INSERT INTO public.notificaciones (user_id, titulo, mensaje, link)
    SELECT DISTINCT ura.user_id, 'Expediente por revisar', NEW.numero_solicitud || ': ' || COALESCE(NEW.cliente_nombre_tmp, ''),
           '/altas/' || NEW.id
    FROM public.user_role_assignments ura WHERE ura.role = 'suscripcion';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_sol_alta ON public.solicitudes_alta;
DROP TRIGGER IF EXISTS trg_d6_notificar_estado_alta ON public.solicitudes_alta;
CREATE TRIGGER trg_d6_notificar_estado_alta
  AFTER UPDATE OF estado_operativo ON public.solicitudes_alta
  FOR EACH ROW EXECUTE FUNCTION public.d6_notificar_estado_alta();

CREATE OR REPLACE FUNCTION public.d6_notificar_baja()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO public.notificaciones (user_id, titulo, mensaje, link)
    SELECT DISTINCT ura.user_id, 'Baja por revisar', NEW.numero_solicitud, '/bajas'
    FROM public.user_role_assignments ura WHERE ura.role = 'suscripcion' AND ura.user_id IS DISTINCT FROM auth.uid();
  ELSIF OLD.estado IS DISTINCT FROM NEW.estado AND NEW.solicitado_por IS NOT NULL AND NEW.solicitado_por IS DISTINCT FROM auth.uid() THEN
    INSERT INTO public.notificaciones (user_id, titulo, mensaje, link)
    VALUES (NEW.solicitado_por, 'Baja ' || NEW.numero_solicitud,
            CASE NEW.estado WHEN 'APROBADA' THEN 'Baja aprobada' WHEN 'RECHAZADA' THEN 'Baja rechazada' ELSE NEW.estado::text END,
            '/bajas');
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_sol_baja ON public.solicitudes_baja;
DROP TRIGGER IF EXISTS trg_d6_notificar_baja ON public.solicitudes_baja;
CREATE TRIGGER trg_d6_notificar_baja
  AFTER INSERT OR UPDATE OF estado ON public.solicitudes_baja
  FOR EACH ROW EXECUTE FUNCTION public.d6_notificar_baja();

-- Realtime para la campana.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime')
     AND NOT EXISTS (SELECT 1 FROM pg_publication_tables WHERE pubname = 'supabase_realtime' AND tablename = 'notificaciones') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.notificaciones;
  END IF;
END $$;
