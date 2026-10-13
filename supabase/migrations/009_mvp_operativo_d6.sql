-- MVP operativo D-6: flujo, expedientes, cobros e invitaciones seguras.
-- Esta migraciÃ³n es aditiva y conserva las tablas y registros existentes.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'd6_role') THEN
    CREATE TYPE public.d6_role AS ENUM (
      'admin', 'comercial', 'suscripcion', 'coordinacion_comercial',
      'cobros', 'contabilidad', 'beneficiario'
    );
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'd6_solicitud_status') THEN
    CREATE TYPE public.d6_solicitud_status AS ENUM (
      'BORRADOR', 'IVE_PENDIENTE', 'EXPEDIENTE_RECIBIDO', 'EN_REVISION',
      'INFORMACION_COMPLEMENTARIA', 'APROBADA_TOTAL', 'APROBADA_PARCIAL',
      'NO_ELEGIBLE', 'SUSPENDIDA', 'EMITIDA'
    );
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'd6_poliza_status') THEN
    CREATE TYPE public.d6_poliza_status AS ENUM (
      'VIGENTE', 'POR_RENOVAR', 'PENDIENTE_ANULACION',
      'REEMPLAZADA_POR_ENDOSO', 'CANCELADA', 'ANULADA', 'VENCIDA'
    );
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'd6_document_status') THEN
    CREATE TYPE public.d6_document_status AS ENUM ('PENDIENTE', 'APROBADO', 'RECHAZADO');
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.user_role_assignments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  role public.d6_role NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, role)
);

CREATE OR REPLACE FUNCTION public.has_d6_role(p_roles public.d6_role[])
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_role_assignments
    WHERE user_id = auth.uid() AND role = ANY (p_roles)
  ) OR public.get_user_role(auth.uid()) IN ('admin', 'operaciones');
$$;

CREATE TABLE IF NOT EXISTS public.contratos_consignacion (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  numero TEXT NOT NULL UNIQUE,
  cliente_id UUID NOT NULL REFERENCES public.clientes(id) ON DELETE RESTRICT,
  beneficiario_id UUID NOT NULL REFERENCES public.beneficiarios(id) ON DELETE RESTRICT,
  agente_id UUID REFERENCES public.agentes(id) ON DELETE SET NULL,
  fecha_inicio DATE NOT NULL,
  fecha_fin DATE NOT NULL,
  valor NUMERIC(15,2),
  estado TEXT NOT NULL DEFAULT 'VIGENTE' CHECK (estado IN ('VIGENTE', 'FINALIZADO', 'SUSPENDIDO')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (fecha_fin = (fecha_inicio + INTERVAL '5 years')::date)
);

ALTER TABLE public.solicitudes_alta
  ADD COLUMN IF NOT EXISTS estado_operativo public.d6_solicitud_status NOT NULL DEFAULT 'BORRADOR',
  ADD COLUMN IF NOT EXISTS monto_aprobado NUMERIC(15,2),
  ADD COLUMN IF NOT EXISTS condiciones_emision TEXT,
  ADD COLUMN IF NOT EXISTS requiere_documento_accesorio BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS exposicion_vigente NUMERIC(15,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS contrato_id UUID REFERENCES public.contratos_consignacion(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS agente_id UUID REFERENCES public.agentes(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS ive_data JSONB,
  ADD COLUMN IF NOT EXISTS emitida_en TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS resolucion_comentario TEXT;

ALTER TABLE public.fianzas
  ADD COLUMN IF NOT EXISTS contrato_id UUID REFERENCES public.contratos_consignacion(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS operational_status public.d6_poliza_status NOT NULL DEFAULT 'VIGENTE',
  ADD COLUMN IF NOT EXISTS reemplaza_fianza_id UUID REFERENCES public.fianzas(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS pago_confirmado_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS lote_fiso TEXT,
  ADD COLUMN IF NOT EXISTS dte_numero TEXT;

ALTER TABLE public.documentos
  ADD COLUMN IF NOT EXISTS requerido BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS estado_revision public.d6_document_status NOT NULL DEFAULT 'PENDIENTE',
  ADD COLUMN IF NOT EXISTS comentario_revision TEXT,
  ADD COLUMN IF NOT EXISTS revisado_por UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS revisado_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS checksum TEXT;

CREATE TABLE IF NOT EXISTS public.ive_invitaciones (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  solicitud_alta_id UUID NOT NULL REFERENCES public.solicitudes_alta(id) ON DELETE CASCADE,
  token_hash TEXT NOT NULL UNIQUE,
  destinatario_email TEXT NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  used_at TIMESTAMPTZ,
  revoked_at TIMESTAMPTZ,
  created_by UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.solicitud_revisiones (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  solicitud_alta_id UUID NOT NULL REFERENCES public.solicitudes_alta(id) ON DELETE CASCADE,
  estado_anterior public.d6_solicitud_status,
  estado_nuevo public.d6_solicitud_status NOT NULL,
  comentario TEXT,
  monto_aprobado NUMERIC(15,2),
  creado_por UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.importaciones_d6 (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tipo TEXT NOT NULL CHECK (tipo IN ('FISO_MENSUAL', 'BANCO_DIARIO')),
  nombre_archivo TEXT NOT NULL,
  storage_path TEXT,
  periodo DATE,
  registros_total INTEGER NOT NULL DEFAULT 0,
  registros_procesados INTEGER NOT NULL DEFAULT 0,
  estado TEXT NOT NULL DEFAULT 'CARGADO' CHECK (estado IN ('CARGADO', 'PROCESADO', 'CON_ERRORES')),
  errores JSONB NOT NULL DEFAULT '[]'::jsonb,
  creado_por UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.estados_cuenta_d6 (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  beneficiario_id UUID NOT NULL REFERENCES public.beneficiarios(id) ON DELETE RESTRICT,
  importacion_id UUID REFERENCES public.importaciones_d6(id) ON DELETE SET NULL,
  periodo DATE NOT NULL,
  fecha_vencimiento DATE NOT NULL,
  total NUMERIC(15,2) NOT NULL DEFAULT 0,
  estado TEXT NOT NULL DEFAULT 'BORRADOR' CHECK (estado IN ('BORRADOR', 'ENVIADO', 'PAGADO', 'PARCIAL', 'VENCIDO')),
  enviado_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (beneficiario_id, periodo)
);

CREATE TABLE IF NOT EXISTS public.estado_cuenta_items_d6 (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  estado_cuenta_id UUID NOT NULL REFERENCES public.estados_cuenta_d6(id) ON DELETE CASCADE,
  fianza_id UUID NOT NULL REFERENCES public.fianzas(id) ON DELETE RESTRICT,
  concepto TEXT NOT NULL,
  monto NUMERIC(15,2) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (estado_cuenta_id, fianza_id, concepto)
);

CREATE TABLE IF NOT EXISTS public.conciliacion_propuestas_d6 (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  importacion_id UUID REFERENCES public.importaciones_d6(id) ON DELETE CASCADE,
  pago_id UUID REFERENCES public.pagos(id) ON DELETE SET NULL,
  referencia_bancaria TEXT,
  monto_recibido NUMERIC(15,2) NOT NULL,
  fecha_pago DATE,
  resultado public.resultado_conciliacion NOT NULL DEFAULT 'PENDIENTE',
  confianza TEXT NOT NULL DEFAULT 'NINGUNA' CHECK (confianza IN ('ALTA', 'MEDIA', 'BAJA', 'NINGUNA')),
  resuelto_at TIMESTAMPTZ,
  resuelto_por UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.notificaciones_envio (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  notificacion_id UUID REFERENCES public.notificaciones(id) ON DELETE CASCADE,
  canal TEXT NOT NULL CHECK (canal IN ('IN_APP', 'EMAIL')),
  destinatario TEXT NOT NULL,
  plantilla TEXT NOT NULL,
  estado TEXT NOT NULL DEFAULT 'PENDIENTE' CHECK (estado IN ('PENDIENTE', 'ENVIADO', 'FALLIDO')),
  provider_id TEXT,
  error TEXT,
  enviado_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.reglas_cobro_d6 (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  codigo_marca TEXT NOT NULL UNIQUE,
  modalidad TEXT NOT NULL CHECK (modalidad IN ('CUOTAS', 'CONTADO')),
  entrega_condicionada_pago BOOLEAN NOT NULL DEFAULT false,
  vencimiento TEXT NOT NULL,
  activa BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO public.reglas_cobro_d6 (codigo_marca, modalidad, entrega_condicionada_pago, vencimiento)
VALUES
  ('ADMOSA', 'CUOTAS', false, 'ULTIMO_DIA_MES_SIGUIENTE'),
  ('GRUPO_UMA', 'CONTADO', true, 'ANTES_DE_ENTREGA')
ON CONFLICT (codigo_marca) DO UPDATE SET
  modalidad = EXCLUDED.modalidad,
  entrega_condicionada_pago = EXCLUDED.entrega_condicionada_pago,
  vencimiento = EXCLUDED.vencimiento;

CREATE OR REPLACE FUNCTION public.d6_requiere_documento_accesorio(p_cliente_id UUID, p_monto NUMERIC)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT p_monto > 300000 OR p_monto + COALESCE((
    SELECT SUM(monto_afianzado) FROM public.fianzas
    WHERE cliente_id = p_cliente_id
      AND operational_status IN ('VIGENTE', 'POR_RENOVAR', 'PENDIENTE_ANULACION')
  ), 0) > 300000;
$$;

CREATE OR REPLACE FUNCTION public.crear_invitacion_ive(p_solicitud_id UUID, p_destinatario_email TEXT, p_horas INTEGER DEFAULT 72)
RETURNS TABLE(token TEXT, expires_at TIMESTAMPTZ)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_token TEXT := encode(gen_random_bytes(32), 'hex');
  v_expires_at TIMESTAMPTZ := now() + make_interval(hours => GREATEST(p_horas, 1));
BEGIN
  IF NOT public.has_d6_role(ARRAY['admin', 'comercial', 'suscripcion']::public.d6_role[]) THEN
    RAISE EXCEPTION 'No tiene permiso para crear invitaciones IVE';
  END IF;
  UPDATE public.ive_invitaciones SET revoked_at = now()
    WHERE solicitud_alta_id = p_solicitud_id AND used_at IS NULL AND revoked_at IS NULL;
  INSERT INTO public.ive_invitaciones (solicitud_alta_id, token_hash, destinatario_email, expires_at, created_by)
    VALUES (p_solicitud_id, encode(digest(v_token, 'sha256'), 'hex'), p_destinatario_email, v_expires_at, auth.uid());
  UPDATE public.solicitudes_alta SET estado_operativo = 'IVE_PENDIENTE' WHERE id = p_solicitud_id;
  RETURN QUERY SELECT v_token, v_expires_at;
END;
$$;

CREATE OR REPLACE FUNCTION public.completar_ive_invitacion(p_token TEXT, p_datos JSONB)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_invitacion public.ive_invitaciones%ROWTYPE;
BEGIN
  SELECT * INTO v_invitacion FROM public.ive_invitaciones
  WHERE token_hash = encode(digest(p_token, 'sha256'), 'hex')
    AND used_at IS NULL AND revoked_at IS NULL AND expires_at > now()
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'La invitaciÃ³n no es vÃ¡lida, expirÃ³ o fue revocada'; END IF;
  UPDATE public.ive_invitaciones SET used_at = now() WHERE id = v_invitacion.id;
  UPDATE public.solicitudes_alta
    SET ive_data = p_datos, estado_operativo = 'EXPEDIENTE_RECIBIDO'
    WHERE id = v_invitacion.solicitud_alta_id;
  RETURN v_invitacion.solicitud_alta_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.transicionar_solicitud_alta(
  p_solicitud_id UUID,
  p_estado public.d6_solicitud_status,
  p_comentario TEXT DEFAULT NULL,
  p_monto_aprobado NUMERIC DEFAULT NULL,
  p_condiciones TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_actual public.d6_solicitud_status;
BEGIN
  IF NOT public.has_d6_role(ARRAY['admin', 'suscripcion']::public.d6_role[]) THEN
    RAISE EXCEPTION 'Solo SuscripciÃ³n puede resolver una solicitud';
  END IF;
  SELECT estado_operativo INTO v_actual FROM public.solicitudes_alta WHERE id = p_solicitud_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Solicitud no encontrada'; END IF;
  IF p_estado = 'EMITIDA' THEN RAISE EXCEPTION 'La emisiÃ³n debe confirmarse con emitir_fianza_d6'; END IF;
  UPDATE public.solicitudes_alta SET
    estado_operativo = p_estado,
    monto_aprobado = COALESCE(p_monto_aprobado, monto_aprobado),
    condiciones_emision = COALESCE(p_condiciones, condiciones_emision),
    resolucion_comentario = p_comentario,
    revisado_por = auth.uid()
  WHERE id = p_solicitud_id;
  INSERT INTO public.solicitud_revisiones (solicitud_alta_id, estado_anterior, estado_nuevo, comentario, monto_aprobado, creado_por)
  VALUES (p_solicitud_id, v_actual, p_estado, p_comentario, p_monto_aprobado, auth.uid());
END;
$$;

CREATE OR REPLACE FUNCTION public.emitir_fianza_d6(
  p_solicitud_id UUID,
  p_numero_fianza BIGINT,
  p_vigencia_desde DATE,
  p_vigencia_hasta DATE,
  p_prima NUMERIC,
  p_lote_fiso TEXT DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_solicitud public.solicitudes_alta%ROWTYPE;
  v_contrato_id UUID;
  v_fianza_id UUID;
BEGIN
  IF NOT public.has_d6_role(ARRAY['admin', 'suscripcion']::public.d6_role[]) THEN
    RAISE EXCEPTION 'Solo SuscripciÃ³n puede confirmar una emisiÃ³n';
  END IF;
  SELECT * INTO v_solicitud FROM public.solicitudes_alta WHERE id = p_solicitud_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Solicitud no encontrada'; END IF;
  IF v_solicitud.estado_operativo NOT IN ('APROBADA_TOTAL', 'APROBADA_PARCIAL') THEN
    RAISE EXCEPTION 'La solicitud debe estar aprobada antes de emitir';
  END IF;
  IF v_solicitud.cliente_id IS NULL THEN RAISE EXCEPTION 'La solicitud no tiene afianzado asociado'; END IF;
  v_contrato_id := v_solicitud.contrato_id;
  IF v_contrato_id IS NULL THEN
    INSERT INTO public.contratos_consignacion (numero, cliente_id, beneficiario_id, agente_id, fecha_inicio, fecha_fin, valor)
    VALUES (
      COALESCE(v_solicitud.contrato_numero, 'CON-' || p_numero_fianza), v_solicitud.cliente_id,
      v_solicitud.beneficiario_id, v_solicitud.agente_id, p_vigencia_desde,
      (p_vigencia_desde + INTERVAL '5 years')::date, v_solicitud.contrato_valor
    ) RETURNING id INTO v_contrato_id;
  END IF;
  INSERT INTO public.fianzas (
    fianza, cliente_id, beneficiario_id, agente_id, vigencia_desde, vigencia_hasta,
    fecha_emision, monto_afianzado, prima, prima_anual, contrato_id, contrato_numero,
    contrato_fecha, contrato_valor, operational_status, lote_fiso
  ) VALUES (
    p_numero_fianza, v_solicitud.cliente_id, v_solicitud.beneficiario_id, v_solicitud.agente_id,
    p_vigencia_desde, p_vigencia_hasta, current_date,
    COALESCE(v_solicitud.monto_aprobado, v_solicitud.monto_solicitado), p_prima, p_prima,
    v_contrato_id, v_solicitud.contrato_numero, v_solicitud.contrato_fecha,
    v_solicitud.contrato_valor, 'VIGENTE', p_lote_fiso
  ) RETURNING id INTO v_fianza_id;
  UPDATE public.solicitudes_alta SET
    estado_operativo = 'EMITIDA', estado = 'APROBADA', contrato_id = v_contrato_id,
    emitida_en = now(), revisado_por = auth.uid()
  WHERE id = p_solicitud_id;
  INSERT INTO public.solicitud_revisiones (solicitud_alta_id, estado_anterior, estado_nuevo, comentario, creado_por)
  VALUES (p_solicitud_id, v_solicitud.estado_operativo, 'EMITIDA', 'EmisiÃ³n confirmada en FISO', auth.uid());
  RETURN v_fianza_id;
END;
$$;

ALTER TABLE public.user_role_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.contratos_consignacion ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ive_invitaciones ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.solicitud_revisiones ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.importaciones_d6 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.estados_cuenta_d6 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.estado_cuenta_items_d6 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.conciliacion_propuestas_d6 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notificaciones_envio ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reglas_cobro_d6 ENABLE ROW LEVEL SECURITY;

CREATE POLICY "D6 admin gestiona roles" ON public.user_role_assignments FOR ALL
  USING (public.has_d6_role(ARRAY['admin']::public.d6_role[]))
  WITH CHECK (public.has_d6_role(ARRAY['admin']::public.d6_role[]));
CREATE POLICY "D6 personal autorizado ve contratos" ON public.contratos_consignacion FOR SELECT
  USING (public.has_d6_role(ARRAY['admin','comercial','suscripcion','coordinacion_comercial','cobros','contabilidad']::public.d6_role[]));
CREATE POLICY "D6 suscripcion administra contratos" ON public.contratos_consignacion FOR ALL
  USING (public.has_d6_role(ARRAY['admin','suscripcion']::public.d6_role[]))
  WITH CHECK (public.has_d6_role(ARRAY['admin','suscripcion']::public.d6_role[]));
CREATE POLICY "D6 personal autorizado administra importaciones" ON public.importaciones_d6 FOR ALL
  USING (public.has_d6_role(ARRAY['admin','coordinacion_comercial','cobros','contabilidad']::public.d6_role[]))
  WITH CHECK (public.has_d6_role(ARRAY['admin','coordinacion_comercial','cobros','contabilidad']::public.d6_role[]));
CREATE POLICY "D6 personal autorizado administra cobros" ON public.estados_cuenta_d6 FOR ALL
  USING (public.has_d6_role(ARRAY['admin','coordinacion_comercial','cobros']::public.d6_role[]))
  WITH CHECK (public.has_d6_role(ARRAY['admin','coordinacion_comercial','cobros']::public.d6_role[]));
CREATE POLICY "D6 personal autorizado administra partidas" ON public.estado_cuenta_items_d6 FOR ALL
  USING (public.has_d6_role(ARRAY['admin','coordinacion_comercial','cobros']::public.d6_role[]))
  WITH CHECK (public.has_d6_role(ARRAY['admin','coordinacion_comercial','cobros']::public.d6_role[]));
CREATE POLICY "D6 personal autorizado administra propuestas" ON public.conciliacion_propuestas_d6 FOR ALL
  USING (public.has_d6_role(ARRAY['admin','cobros','contabilidad']::public.d6_role[]))
  WITH CHECK (public.has_d6_role(ARRAY['admin','cobros','contabilidad']::public.d6_role[]));
CREATE POLICY "D6 admin administra reglas" ON public.reglas_cobro_d6 FOR ALL
  USING (public.has_d6_role(ARRAY['admin']::public.d6_role[]))
  WITH CHECK (public.has_d6_role(ARRAY['admin']::public.d6_role[]));
CREATE POLICY "D6 comercial crea y ve sus altas" ON public.solicitudes_alta FOR ALL
  USING (public.has_d6_role(ARRAY['admin','comercial','suscripcion']::public.d6_role[]))
  WITH CHECK (public.has_d6_role(ARRAY['admin','comercial','suscripcion']::public.d6_role[]));
CREATE POLICY "D6 personal ve revisiones" ON public.solicitud_revisiones FOR SELECT
  USING (public.has_d6_role(ARRAY['admin','comercial','suscripcion']::public.d6_role[]));
CREATE POLICY "D6 suscripcion escribe revisiones" ON public.solicitud_revisiones FOR INSERT
  WITH CHECK (public.has_d6_role(ARRAY['admin','suscripcion']::public.d6_role[]));
CREATE POLICY "D6 personal ve invitaciones" ON public.ive_invitaciones FOR SELECT
  USING (public.has_d6_role(ARRAY['admin','comercial','suscripcion']::public.d6_role[]));
CREATE POLICY "D6 personal ve envios" ON public.notificaciones_envio FOR SELECT
  USING (public.has_d6_role(ARRAY['admin','comercial','suscripcion','coordinacion_comercial','cobros','contabilidad']::public.d6_role[]));
CREATE POLICY "D6 sistema registra envios" ON public.notificaciones_envio FOR INSERT
  WITH CHECK (public.has_d6_role(ARRAY['admin','comercial','suscripcion','coordinacion_comercial','cobros','contabilidad']::public.d6_role[]));
CREATE POLICY "D6 equipos ven polizas" ON public.fianzas FOR SELECT
  USING (public.has_d6_role(ARRAY['admin','comercial','suscripcion','coordinacion_comercial','cobros','contabilidad']::public.d6_role[]));
CREATE POLICY "D6 suscripcion administra polizas" ON public.fianzas FOR ALL
  USING (public.has_d6_role(ARRAY['admin','suscripcion']::public.d6_role[]))
  WITH CHECK (public.has_d6_role(ARRAY['admin','suscripcion']::public.d6_role[]));

GRANT EXECUTE ON FUNCTION public.completar_ive_invitacion(TEXT, JSONB) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.crear_invitacion_ive(UUID, TEXT, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.transicionar_solicitud_alta(UUID, public.d6_solicitud_status, TEXT, NUMERIC, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.emitir_fianza_d6(UUID, BIGINT, DATE, DATE, NUMERIC, TEXT) TO authenticated;
