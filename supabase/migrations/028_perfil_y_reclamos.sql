-- Migracion 028: perfil de riesgo del afianzado y reclamos.
--
-- El producto D-6 existe para esto: el distribuidor (afianzado) recibe motos en
-- consignacion de la marca; si no paga lo vendido o pierde unidades, la marca reclama
-- la fianza y Fidelis paga y recobra contra el afianzado. Por eso:
--   * Fidelis necesita perfilar al afianzado (IVE, contragarantias, cumulo, mora, reclamos).
--   * La marca necesita avisar un incumplimiento y presentar el reclamo con evidencia.
--   * Fidelis necesita resolverlo, pagarlo y llevar el recobro.

-- ============================================================================
-- 1. Perfil traido de Oracle (lo llena integrations/oracle/perfil_afianzados.py)
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.perfil_afianzado_oracle (
  cliente_codigo INTEGER PRIMARY KEY,
  ive_fecha_renovacion DATE,
  ive_completo BOOLEAN NOT NULL DEFAULT false,
  ive_verificado BOOLEAN NOT NULL DEFAULT false,
  contragarantia_monto NUMERIC(15,2) NOT NULL DEFAULT 0,
  contragarantia_tipos TEXT,
  contragarantia_instrumentos INTEGER NOT NULL DEFAULT 0,
  cumulo NUMERIC(15,2),
  saldo NUMERIC(15,2) NOT NULL DEFAULT 0,
  saldo_atrasado NUMERIC(15,2) NOT NULL DEFAULT 0,
  saldo_atrasado_90 NUMERIC(15,2) NOT NULL DEFAULT 0,
  max_dias_atraso INTEGER NOT NULL DEFAULT 0,
  reclamos INTEGER NOT NULL DEFAULT 0,
  avisos INTEGER NOT NULL DEFAULT 0,
  ultimo_reclamo DATE,
  otras_fianzas_vigentes INTEGER NOT NULL DEFAULT 0,
  otras_fianzas_monto NUMERIC(15,2) NOT NULL DEFAULT 0,
  actualizado_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.perfil_afianzado_oracle ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "perfil_oracle: personal ve" ON public.perfil_afianzado_oracle;
CREATE POLICY "perfil_oracle: personal ve" ON public.perfil_afianzado_oracle FOR SELECT
  USING (public.d6_es_personal_aseguradora());

-- ============================================================================
-- 2. Reclamos
-- ============================================================================
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'd6_reclamo_estado') THEN
    CREATE TYPE public.d6_reclamo_estado AS ENUM (
      'AVISO', 'PRESENTADO', 'EN_ANALISIS', 'REQUERIMIENTO', 'PROCEDENTE', 'PROCEDENTE_PARCIAL',
      'IMPROCEDENTE', 'PAGADO', 'EN_RECOBRO', 'RECUPERADO', 'CERRADO', 'DESISTIDO'
    );
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'd6_reclamo_tipo') THEN
    CREATE TYPE public.d6_reclamo_tipo AS ENUM (
      'FALTA_PAGO', 'PERDIDA_UNIDADES', 'NO_DEVOLUCION_INVENTARIO', 'OTRO'
    );
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.reclamos_d6 (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  numero TEXT NOT NULL UNIQUE,
  fianza_id UUID NOT NULL REFERENCES public.fianzas(id) ON DELETE RESTRICT,
  beneficiario_id UUID NOT NULL REFERENCES public.beneficiarios(id) ON DELETE RESTRICT,
  cliente_id UUID NOT NULL REFERENCES public.clientes(id) ON DELETE RESTRICT,
  tipo public.d6_reclamo_tipo NOT NULL,
  estado public.d6_reclamo_estado NOT NULL DEFAULT 'AVISO',
  fecha_incumplimiento DATE NOT NULL,
  monto_reclamado NUMERIC(15,2) NOT NULL CHECK (monto_reclamado > 0),
  unidades INTEGER,
  descripcion TEXT NOT NULL,
  monto_aprobado NUMERIC(15,2),
  monto_pagado NUMERIC(15,2),
  fecha_pago DATE,
  monto_recuperado NUMERIC(15,2) NOT NULL DEFAULT 0,
  resolucion TEXT,
  creado_por UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  responsable_id UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.reclamo_movimientos_d6 (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reclamo_id UUID NOT NULL REFERENCES public.reclamos_d6(id) ON DELETE CASCADE,
  estado_anterior public.d6_reclamo_estado,
  estado_nuevo public.d6_reclamo_estado,
  comentario TEXT,
  monto NUMERIC(15,2),
  interno BOOLEAN NOT NULL DEFAULT false,
  creado_por UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_reclamos_fianza ON public.reclamos_d6 (fianza_id);
CREATE INDEX IF NOT EXISTS idx_reclamos_cliente ON public.reclamos_d6 (cliente_id);
CREATE INDEX IF NOT EXISTS idx_reclamo_mov ON public.reclamo_movimientos_d6 (reclamo_id, created_at);

DROP TRIGGER IF EXISTS trg_reclamos_updated_at ON public.reclamos_d6;
CREATE TRIGGER trg_reclamos_updated_at BEFORE UPDATE ON public.reclamos_d6
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
DROP TRIGGER IF EXISTS trg_reclamos_audit ON public.reclamos_d6;
CREATE TRIGGER trg_reclamos_audit AFTER INSERT OR UPDATE OR DELETE ON public.reclamos_d6
  FOR EACH ROW EXECUTE FUNCTION public.log_audit_changes();

ALTER TABLE public.documentos ADD COLUMN IF NOT EXISTS reclamo_id UUID REFERENCES public.reclamos_d6(id) ON DELETE CASCADE;

CREATE OR REPLACE FUNCTION public.d6_reclamo_es_mio(p_reclamo_id UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT EXISTS (SELECT 1 FROM public.reclamos_d6 r WHERE r.id = p_reclamo_id AND public.d6_beneficiario_es_mio(r.beneficiario_id));
$$;

ALTER TABLE public.reclamos_d6 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reclamo_movimientos_d6 ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "reclamos: personal o la propia marca ven" ON public.reclamos_d6;
CREATE POLICY "reclamos: personal o la propia marca ven" ON public.reclamos_d6 FOR SELECT
  USING (public.d6_es_personal_aseguradora() OR public.d6_beneficiario_es_mio(beneficiario_id));
-- Toda escritura pasa por RPC.
DROP POLICY IF EXISTS "movimientos: personal ve todo, marca ve lo no interno" ON public.reclamo_movimientos_d6;
CREATE POLICY "movimientos: personal ve todo, marca ve lo no interno" ON public.reclamo_movimientos_d6 FOR SELECT
  USING (public.d6_es_personal_aseguradora() OR (NOT interno AND public.d6_reclamo_es_mio(reclamo_id)));

-- Documentos de reclamos: la marca adjunta evidencia a sus reclamos y los ve.
CREATE OR REPLACE FUNCTION public.d6_puede_ver_documento(p_documento_id UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT public.d6_es_personal_aseguradora()
    OR EXISTS (
      SELECT 1
      FROM public.documentos d
      LEFT JOIN public.fianzas f ON f.id = d.fianza_id
      WHERE d.id = p_documento_id
        AND d.solicitud_alta_id IS NULL
        AND (
          (d.solicitud_baja_id IS NOT NULL AND public.d6_baja_es_mia(d.solicitud_baja_id))
          OR (d.reclamo_id IS NOT NULL AND public.d6_reclamo_es_mio(d.reclamo_id))
          OR (d.fianza_id IS NOT NULL AND public.d6_beneficiario_es_mio(f.beneficiario_id))
        )
    );
$$;

DROP POLICY IF EXISTS "documentos: marca adjunta a sus reclamos" ON public.documentos;
CREATE POLICY "documentos: marca adjunta a sus reclamos" ON public.documentos FOR INSERT
  WITH CHECK (
    reclamo_id IS NOT NULL AND solicitud_alta_id IS NULL AND solicitud_baja_id IS NULL
    AND subido_por = auth.uid() AND public.d6_reclamo_es_mio(reclamo_id)
  );

DROP POLICY IF EXISTS "expedientes: marca carga evidencia de sus reclamos" ON storage.objects;
CREATE POLICY "expedientes: marca carga evidencia de sus reclamos" ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'expedientes'
    AND split_part(name, '/', 1) = 'reclamos'
    AND split_part(name, '/', 2) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    AND public.d6_reclamo_es_mio(split_part(name, '/', 2)::uuid)
  );

-- Transiciones. La interfaz las lee igual que las de altas.
CREATE OR REPLACE FUNCTION public.d6_transiciones_reclamo()
RETURNS JSONB
LANGUAGE sql IMMUTABLE
AS $$
  SELECT jsonb_build_object(
    'AVISO',              jsonb_build_array('PRESENTADO', 'CERRADO', 'DESISTIDO'),
    'PRESENTADO',         jsonb_build_array('EN_ANALISIS', 'DESISTIDO'),
    'EN_ANALISIS',        jsonb_build_array('REQUERIMIENTO', 'PROCEDENTE', 'PROCEDENTE_PARCIAL', 'IMPROCEDENTE', 'DESISTIDO'),
    'REQUERIMIENTO',      jsonb_build_array('PROCEDENTE', 'PROCEDENTE_PARCIAL', 'IMPROCEDENTE', 'CERRADO', 'DESISTIDO'),
    'PROCEDENTE',         jsonb_build_array('PAGADO'),
    'PROCEDENTE_PARCIAL', jsonb_build_array('PAGADO'),
    'PAGADO',             jsonb_build_array('EN_RECOBRO', 'CERRADO'),
    'EN_RECOBRO',         jsonb_build_array('RECUPERADO', 'CERRADO'),
    'RECUPERADO',         jsonb_build_array('CERRADO'),
    'IMPROCEDENTE',       jsonb_build_array(),
    'CERRADO',            jsonb_build_array(),
    'DESISTIDO',          jsonb_build_array()
  );
$$;
GRANT EXECUTE ON FUNCTION public.d6_transiciones_reclamo() TO authenticated;

-- La marca avisa o reclama. Solo por fianzas suyas, por incumplimientos ocurridos
-- durante la vigencia y por montos dentro de lo afianzado.
CREATE OR REPLACE FUNCTION public.d6_reportar_incumplimiento(
  p_fianza_id UUID, p_tipo public.d6_reclamo_tipo, p_fecha DATE, p_monto NUMERIC,
  p_descripcion TEXT, p_unidades INTEGER DEFAULT NULL, p_presentar BOOLEAN DEFAULT false
) RETURNS TABLE(reclamo_id UUID, numero TEXT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_f public.fianzas%ROWTYPE;
  v_monto NUMERIC(15,2);
  v_id UUID;
  v_numero TEXT;
  v_estado public.d6_reclamo_estado := CASE WHEN p_presentar THEN 'PRESENTADO' ELSE 'AVISO' END;
BEGIN
  SELECT * INTO v_f FROM public.fianzas WHERE id = p_fianza_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Fianza no encontrada'; END IF;
  IF NOT public.has_d6_role(ARRAY['admin', 'suscripcion', 'comercial']::public.d6_role[])
     AND NOT public.d6_beneficiario_es_mio(v_f.beneficiario_id) THEN
    RAISE EXCEPTION 'Solo la marca beneficiaria puede reportar un incumplimiento de esta fianza';
  END IF;
  IF p_fecha IS NULL OR p_fecha > CURRENT_DATE THEN RAISE EXCEPTION 'Indique la fecha del incumplimiento (no puede ser futura)'; END IF;
  IF p_fecha < v_f.vigencia_desde OR p_fecha > v_f.vigencia_hasta THEN
    RAISE EXCEPTION 'El incumplimiento debe haber ocurrido durante la vigencia de la fianza (% al %)', v_f.vigencia_desde, v_f.vigencia_hasta;
  END IF;
  v_monto := CASE WHEN COALESCE(v_f.monto_afianzado, 0) = 0 THEN COALESCE(v_f.contrato_valor, 0) ELSE v_f.monto_afianzado END;
  IF COALESCE(p_monto, 0) <= 0 THEN RAISE EXCEPTION 'Indique el monto adeudado o el valor de las unidades'; END IF;
  IF p_monto > v_monto THEN RAISE EXCEPTION 'El monto reclamado supera el monto afianzado (%)', v_monto; END IF;
  IF NULLIF(btrim(COALESCE(p_descripcion, '')), '') IS NULL THEN RAISE EXCEPTION 'Describa el incumplimiento'; END IF;

  v_numero := 'REC-' || to_char(now(), 'YYYY') || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
  INSERT INTO public.reclamos_d6 (numero, fianza_id, beneficiario_id, cliente_id, tipo, estado, fecha_incumplimiento,
                                  monto_reclamado, unidades, descripcion, creado_por)
  VALUES (v_numero, v_f.id, v_f.beneficiario_id, v_f.cliente_id, p_tipo, v_estado, p_fecha, round(p_monto, 2),
          p_unidades, btrim(p_descripcion), auth.uid())
  RETURNING id INTO v_id;
  INSERT INTO public.reclamo_movimientos_d6 (reclamo_id, estado_anterior, estado_nuevo, comentario, monto, creado_por)
  VALUES (v_id, NULL, v_estado, CASE WHEN p_presentar THEN 'Reclamo presentado' ELSE 'Aviso de incumplimiento' END, round(p_monto, 2), auth.uid());

  INSERT INTO public.notificaciones (user_id, titulo, mensaje, link)
  SELECT DISTINCT ura.user_id, CASE WHEN p_presentar THEN 'Reclamo presentado' ELSE 'Aviso de incumplimiento' END,
         v_numero || ': fianza ' || v_f.fianza || ', ' || to_char(p_monto, 'FM999,999,990.00'), '/reclamos/' || v_id
  FROM public.user_role_assignments ura WHERE ura.role IN ('suscripcion', 'admin') AND ura.user_id IS DISTINCT FROM auth.uid();

  RETURN QUERY SELECT v_id, v_numero;
END;
$$;

CREATE OR REPLACE FUNCTION public.d6_avanzar_reclamo(
  p_reclamo_id UUID, p_estado public.d6_reclamo_estado, p_comentario TEXT DEFAULT NULL,
  p_monto NUMERIC DEFAULT NULL, p_interno BOOLEAN DEFAULT false
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_r public.reclamos_d6%ROWTYPE;
  v_personal BOOLEAN := public.has_d6_role(ARRAY['admin', 'suscripcion']::public.d6_role[]);
  v_marca BOOLEAN;
BEGIN
  SELECT * INTO v_r FROM public.reclamos_d6 WHERE id = p_reclamo_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Reclamo no encontrado'; END IF;
  v_marca := public.d6_beneficiario_es_mio(v_r.beneficiario_id);
  IF NOT (public.d6_transiciones_reclamo() -> v_r.estado::text) ? p_estado::text THEN
    RAISE EXCEPTION 'No se puede pasar de % a %', v_r.estado, p_estado;
  END IF;
  -- La marca solo presenta su aviso o desiste. Todo lo demas es de Fidelis.
  IF NOT v_personal AND NOT (v_marca AND (
       (v_r.estado = 'AVISO' AND p_estado = 'PRESENTADO')
    OR (p_estado = 'DESISTIDO' AND v_r.estado IN ('AVISO', 'PRESENTADO', 'EN_ANALISIS', 'REQUERIMIENTO')))) THEN
    RAISE EXCEPTION 'No tiene permiso para este cambio';
  END IF;
  IF p_estado IN ('IMPROCEDENTE', 'REQUERIMIENTO', 'DESISTIDO', 'CERRADO')
     AND NULLIF(btrim(COALESCE(p_comentario, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Explique el motivo';
  END IF;
  IF p_estado = 'PROCEDENTE_PARCIAL' AND (p_monto IS NULL OR p_monto <= 0 OR p_monto >= v_r.monto_reclamado) THEN
    RAISE EXCEPTION 'Una procedencia parcial requiere un monto menor al reclamado';
  END IF;
  IF p_estado = 'PAGADO' AND (p_monto IS NULL OR p_monto <= 0) THEN
    RAISE EXCEPTION 'Indique el monto pagado a la marca';
  END IF;
  IF p_estado = 'PAGADO' AND p_monto > COALESCE(v_r.monto_aprobado, v_r.monto_reclamado) THEN
    RAISE EXCEPTION 'El pago no puede superar el monto aprobado';
  END IF;
  IF p_estado = 'RECUPERADO' AND (p_monto IS NULL OR p_monto <= 0) THEN
    RAISE EXCEPTION 'Indique el monto recuperado del afianzado';
  END IF;

  UPDATE public.reclamos_d6 SET
    estado = p_estado,
    monto_aprobado = CASE
      WHEN p_estado = 'PROCEDENTE' THEN monto_reclamado
      WHEN p_estado = 'PROCEDENTE_PARCIAL' THEN round(p_monto, 2)
      WHEN p_estado = 'IMPROCEDENTE' THEN 0
      ELSE monto_aprobado END,
    monto_pagado = CASE WHEN p_estado = 'PAGADO' THEN round(p_monto, 2) ELSE monto_pagado END,
    fecha_pago = CASE WHEN p_estado = 'PAGADO' THEN CURRENT_DATE ELSE fecha_pago END,
    monto_recuperado = CASE WHEN p_estado = 'RECUPERADO' THEN monto_recuperado + round(p_monto, 2) ELSE monto_recuperado END,
    resolucion = CASE WHEN p_estado IN ('PROCEDENTE', 'PROCEDENTE_PARCIAL', 'IMPROCEDENTE') THEN p_comentario ELSE resolucion END,
    responsable_id = CASE WHEN v_personal THEN auth.uid() ELSE responsable_id END
  WHERE id = p_reclamo_id;

  INSERT INTO public.reclamo_movimientos_d6 (reclamo_id, estado_anterior, estado_nuevo, comentario, monto, interno, creado_por)
  VALUES (p_reclamo_id, v_r.estado, p_estado, NULLIF(btrim(COALESCE(p_comentario, '')), ''), p_monto,
          v_personal AND COALESCE(p_interno, false), auth.uid());

  -- Aviso a la marca de cada cambio que no es interno, y a Suscripcion de lo que hace la marca.
  IF NOT COALESCE(p_interno, false) THEN
    INSERT INTO public.notificaciones (user_id, titulo, mensaje, link)
    SELECT DISTINCT u.user_id, 'Reclamo ' || v_r.numero, 'Estado: ' || replace(initcap(p_estado::text), '_', ' '), '/reclamos/' || v_r.id
    FROM (
      SELECT ug.user_id FROM public.user_grupos ug
      JOIN public.grupo_beneficiario_rel r ON r.grupo_id = ug.grupo_id WHERE r.beneficiario_id = v_r.beneficiario_id
      UNION
      SELECT ura.user_id FROM public.user_role_assignments ura WHERE ura.role = 'suscripcion' AND v_marca AND NOT v_personal
    ) u WHERE u.user_id IS DISTINCT FROM auth.uid();
  END IF;
END;
$$;

-- Nota interna o mensaje a la marca sin cambiar de estado.
CREATE OR REPLACE FUNCTION public.d6_comentar_reclamo(p_reclamo_id UUID, p_comentario TEXT, p_interno BOOLEAN DEFAULT false)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_personal BOOLEAN := public.has_d6_role(ARRAY['admin', 'suscripcion', 'comercial']::public.d6_role[]);
BEGIN
  IF NOT v_personal AND NOT public.d6_reclamo_es_mio(p_reclamo_id) THEN RAISE EXCEPTION 'No tiene acceso a este reclamo'; END IF;
  IF NULLIF(btrim(COALESCE(p_comentario, '')), '') IS NULL THEN RAISE EXCEPTION 'Escriba el comentario'; END IF;
  INSERT INTO public.reclamo_movimientos_d6 (reclamo_id, comentario, interno, creado_por)
  VALUES (p_reclamo_id, btrim(p_comentario), v_personal AND COALESCE(p_interno, false), auth.uid());
END;
$$;

REVOKE EXECUTE ON FUNCTION public.d6_reportar_incumplimiento(UUID, public.d6_reclamo_tipo, DATE, NUMERIC, TEXT, INTEGER, BOOLEAN) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.d6_avanzar_reclamo(UUID, public.d6_reclamo_estado, TEXT, NUMERIC, BOOLEAN) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.d6_comentar_reclamo(UUID, TEXT, BOOLEAN) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.d6_reportar_incumplimiento(UUID, public.d6_reclamo_tipo, DATE, NUMERIC, TEXT, INTEGER, BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION public.d6_avanzar_reclamo(UUID, public.d6_reclamo_estado, TEXT, NUMERIC, BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION public.d6_comentar_reclamo(UUID, TEXT, BOOLEAN) TO authenticated;

CREATE OR REPLACE VIEW public.v_reclamos
WITH (security_invoker = true)
AS
SELECT r.*, f.fianza, f.vigencia_desde, f.vigencia_hasta,
       CASE WHEN COALESCE(f.monto_afianzado, 0) = 0 THEN f.contrato_valor ELSE f.monto_afianzado END AS monto_afianzado,
       c.nombre AS afianzado_nombre, c.codigo_contacto AS afianzado_codigo,
       b.nombre AS beneficiario_nombre,
       (SELECT max(m.created_at) FROM public.reclamo_movimientos_d6 m WHERE m.reclamo_id = r.id) AS ultimo_movimiento
FROM public.reclamos_d6 r
JOIN public.fianzas f ON f.id = r.fianza_id
JOIN public.clientes c ON c.id = r.cliente_id
JOIN public.beneficiarios b ON b.id = r.beneficiario_id;
GRANT SELECT ON public.v_reclamos TO authenticated;
REVOKE ALL ON public.v_reclamos FROM anon;

-- ============================================================================
-- 3. Perfil del afianzado (solo personal de Fidelis)
-- ============================================================================
-- Reglas del nivel de riesgo, a la vista y sin puntajes ocultos:
--   ALTO  : reclamo (Oracle o app, no improcedente ni desistido) o mora de mas de 90 dias.
--   MEDIO : IVE vencido o sin fecha, exposicion sobre Q300,000 sin contragarantia,
--           o cualquier saldo atrasado.
--   BAJO  : nada de lo anterior.
CREATE OR REPLACE VIEW public.v_perfil_afianzados
WITH (security_invoker = true)
AS
WITH pol AS (
  SELECT v.cliente_id,
         min(v.fecha_emision) AS desde,
         count(*) AS polizas_historicas,
         count(*) FILTER (WHERE v.estado IN ('VIGENTE', 'POR_RENOVAR', 'EN_BAJA')) AS polizas_activas,
         count(*) FILTER (WHERE v.estado = 'CANCELADA') AS canceladas,
         count(DISTINCT v.marca_id) FILTER (WHERE v.estado IN ('VIGENTE', 'POR_RENOVAR', 'EN_BAJA')) AS marcas_activas,
         string_agg(DISTINCT v.marca_nombre, ', ') FILTER (WHERE v.estado IN ('VIGENTE', 'POR_RENOVAR', 'EN_BAJA')) AS marcas,
         COALESCE(sum(v.monto_afianzado) FILTER (WHERE v.estado IN ('VIGENTE', 'POR_RENOVAR', 'EN_BAJA')), 0) AS exposicion,
         max(v.monto_original) AS monto_maximo,
         min(v.vigencia_hasta) FILTER (WHERE v.estado IN ('VIGENTE', 'POR_RENOVAR')) AS proximo_vencimiento
  FROM public.v_fianzas v
  GROUP BY v.cliente_id
),
rec AS (
  SELECT cliente_id,
         count(*) FILTER (WHERE estado NOT IN ('IMPROCEDENTE', 'DESISTIDO', 'CERRADO', 'RECUPERADO')) AS reclamos_abiertos,
         count(*) FILTER (WHERE estado NOT IN ('IMPROCEDENTE', 'DESISTIDO')) AS reclamos_app,
         COALESCE(sum(monto_pagado), 0) - COALESCE(sum(monto_recuperado), 0) AS por_recuperar
  FROM public.reclamos_d6 GROUP BY cliente_id
)
SELECT
  c.id AS cliente_id, c.codigo_contacto AS codigo, c.nombre, c.nit, c.tipo_persona,
  pol.desde, pol.polizas_historicas, pol.polizas_activas, pol.canceladas, pol.marcas_activas, pol.marcas,
  pol.exposicion, pol.monto_maximo, pol.proximo_vencimiento,
  o.ive_fecha_renovacion, o.ive_completo, o.ive_verificado,
  COALESCE(o.contragarantia_monto, 0) AS contragarantia_monto, o.contragarantia_tipos,
  o.cumulo, COALESCE(o.saldo, 0) AS saldo, COALESCE(o.saldo_atrasado, 0) AS saldo_atrasado,
  COALESCE(o.saldo_atrasado_90, 0) AS saldo_atrasado_90, COALESCE(o.max_dias_atraso, 0) AS max_dias_atraso,
  COALESCE(o.reclamos, 0) AS reclamos_oracle, COALESCE(o.avisos, 0) AS avisos_oracle,
  COALESCE(rec.reclamos_app, 0) AS reclamos_app, COALESCE(rec.reclamos_abiertos, 0) AS reclamos_abiertos,
  COALESCE(rec.por_recuperar, 0) AS por_recuperar,
  COALESCE(o.otras_fianzas_vigentes, 0) AS otras_fianzas_vigentes, COALESCE(o.otras_fianzas_monto, 0) AS otras_fianzas_monto,
  o.actualizado_at AS perfil_actualizado,
  (o.cliente_codigo IS NOT NULL AND (o.ive_fecha_renovacion IS NULL OR o.ive_fecha_renovacion < CURRENT_DATE)) AS alerta_ive,
  (pol.exposicion > 300000 AND COALESCE(o.contragarantia_monto, 0) = 0) AS alerta_accesorio,
  (COALESCE(o.saldo_atrasado, 0) > 0) AS alerta_atraso,
  (COALESCE(o.saldo_atrasado_90, 0) > 0) AS alerta_atraso_90,
  (COALESCE(o.reclamos, 0) + COALESCE(rec.reclamos_app, 0) > 0) AS alerta_reclamo,
  CASE
    WHEN COALESCE(o.reclamos, 0) + COALESCE(rec.reclamos_app, 0) > 0 OR COALESCE(o.saldo_atrasado_90, 0) > 0 THEN 'ALTO'
    WHEN (o.cliente_codigo IS NOT NULL AND (o.ive_fecha_renovacion IS NULL OR o.ive_fecha_renovacion < CURRENT_DATE))
      OR (pol.exposicion > 300000 AND COALESCE(o.contragarantia_monto, 0) = 0)
      OR COALESCE(o.saldo_atrasado, 0) > 0 THEN 'MEDIO'
    ELSE 'BAJO'
  END AS nivel_riesgo
FROM public.clientes c
JOIN pol ON pol.cliente_id = c.id
LEFT JOIN public.perfil_afianzado_oracle o ON o.cliente_codigo = c.codigo_contacto
LEFT JOIN rec ON rec.cliente_id = c.id
WHERE public.d6_es_personal_aseguradora();
GRANT SELECT ON public.v_perfil_afianzados TO authenticated;
REVOKE ALL ON public.v_perfil_afianzados FROM anon;

-- Resumen de riesgo de la cartera activa para el tablero interno.
CREATE OR REPLACE FUNCTION public.d6_resumen_riesgo()
RETURNS TABLE(
  afianzados_activos BIGINT, exposicion NUMERIC, nivel_alto BIGINT, nivel_medio BIGINT, nivel_bajo BIGINT,
  ive_vencido BIGINT, sin_accesorio BIGINT, exposicion_sin_accesorio NUMERIC, con_atraso BIGINT,
  con_atraso_90 BIGINT, saldo_atrasado NUMERIC, con_reclamo BIGINT, reclamos_abiertos BIGINT,
  por_recuperar NUMERIC, perfil_actualizado TIMESTAMPTZ
)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public
AS $$
  SELECT count(*), COALESCE(sum(exposicion), 0),
         count(*) FILTER (WHERE nivel_riesgo = 'ALTO'), count(*) FILTER (WHERE nivel_riesgo = 'MEDIO'),
         count(*) FILTER (WHERE nivel_riesgo = 'BAJO'),
         count(*) FILTER (WHERE alerta_ive), count(*) FILTER (WHERE alerta_accesorio),
         COALESCE(sum(exposicion) FILTER (WHERE alerta_accesorio), 0),
         count(*) FILTER (WHERE alerta_atraso), count(*) FILTER (WHERE alerta_atraso_90),
         COALESCE(sum(saldo_atrasado), 0), count(*) FILTER (WHERE alerta_reclamo),
         COALESCE(sum(reclamos_abiertos), 0), COALESCE(sum(por_recuperar), 0), max(perfil_actualizado)
  FROM public.v_perfil_afianzados
  WHERE polizas_activas > 0;
$$;
REVOKE EXECUTE ON FUNCTION public.d6_resumen_riesgo() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.d6_resumen_riesgo() TO authenticated;
