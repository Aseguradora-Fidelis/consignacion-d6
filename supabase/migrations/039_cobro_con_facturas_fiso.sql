-- 039: el estado de cuenta cobra las facturas que FISO emitio (decision del 2026-10-08).
--
-- Cruce en vivo con Oracle main_fusa el 2026-10-08 a las 18:47:
--   * FISO factura D-6 en cuotas mensuales a todas las marcas menos UMA, que va de contado.
--   * Los endosos de aplicacion de primas (6), cancelacion (9) y habilitacion (7) no se facturan.
--   * Un endoso a 60 meses se factura como una prima anual.
-- La regla anterior (lo emitido el mes anterior por prima, derechos e IVA) cobraba la prima
-- completa el primer mes y cobraba endosos que FISO no factura. En septiembre 2026 habria
-- cobrado Q68,947 a un beneficiario de ADMOSA al que FISO le facturo Q40,265.
-- Ahora la app no calcula lo que se cobra: copia las facturas de FISO, una partida por factura.
--
-- Tambien:
--   * Un estado de cuenta enviado ya no cambia (trigger).
--   * Generar y enviar estados de cuenta es de Comercializacion (procedimiento v01).
--   * Las fechas de negocio se toman en hora de Guatemala.

-- ============================================================================
-- 1. Fechas en hora de Guatemala
-- ============================================================================
-- CURRENT_DATE y date_trunc usan la zona de la sesion. Con la base en UTC, lo emitido despues
-- de las 18:00 quedaba con fecha del dia siguiente y el cierre de mes se corria.
DO $$
BEGIN
  EXECUTE format('ALTER DATABASE %I SET timezone TO %L', current_database(), 'America/Guatemala');
END $$;
SET timezone TO 'America/Guatemala';

-- ============================================================================
-- 2. Facturas D-6 de FISO
-- ============================================================================
ALTER TABLE public.oracle_sync_runs_d6 DROP CONSTRAINT IF EXISTS oracle_sync_runs_d6_fuente_check;
ALTER TABLE public.oracle_sync_runs_d6 ADD CONSTRAINT oracle_sync_runs_d6_fuente_check
  CHECK (fuente IN ('CIE_TRASLADO_MES', 'VW_SALDO_FACTURA', 'MG_CONTACTOS_IVE', 'CARTERA_D6', 'FACTURAS_D6'));

-- La llave es el correlativo unico de cobro: las notas de cobro pendientes (serie FN) no tienen
-- numero de factura todavia, y una factura anulada se reemite con el mismo numero.
CREATE TABLE IF NOT EXISTS public.facturas_fiso_d6 (
  correlativo_cobro BIGINT PRIMARY KEY,
  serie TEXT,
  factura BIGINT,
  estado_documento TEXT,
  ramo TEXT,
  fianza BIGINT NOT NULL,
  endoso INTEGER NOT NULL DEFAULT 0,
  fianza_id UUID REFERENCES public.fianzas(id) ON DELETE RESTRICT,
  beneficiario_id UUID REFERENCES public.beneficiarios(id) ON DELETE RESTRICT,
  fecha_emision DATE NOT NULL,
  prima NUMERIC(15,2) NOT NULL DEFAULT 0,
  derechos NUMERIC(15,2) NOT NULL DEFAULT 0,
  otros NUMERIC(15,2) NOT NULL DEFAULT 0,
  iva NUMERIC(15,2) NOT NULL DEFAULT 0,
  total NUMERIC(15,2) NOT NULL,
  saldo NUMERIC(15,2) NOT NULL DEFAULT 0,
  fecha_pago DATE,
  fecha_anulacion DATE,
  meses_plazo INTEGER,
  sync_run_id UUID REFERENCES public.oracle_sync_runs_d6(id) ON DELETE SET NULL,
  actualizada_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.facturas_fiso_d6 IS 'Copia de main_fusa.FAC_FACTURA clase D-6. Solo la escribe la carga de Oracle.';
CREATE INDEX IF NOT EXISTS idx_facturas_fiso_emision ON public.facturas_fiso_d6 (fecha_emision);
CREATE INDEX IF NOT EXISTS idx_facturas_fiso_fianza ON public.facturas_fiso_d6 (fianza, endoso);
CREATE INDEX IF NOT EXISTS idx_facturas_fiso_beneficiario ON public.facturas_fiso_d6 (beneficiario_id);

ALTER TABLE public.facturas_fiso_d6 ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "facturas_fiso: personal o la propia marca ven" ON public.facturas_fiso_d6;
CREATE POLICY "facturas_fiso: personal o la propia marca ven" ON public.facturas_fiso_d6 FOR SELECT
  USING ((SELECT public.d6_es_personal_aseguradora()) OR public.d6_beneficiario_es_mio(beneficiario_id));
REVOKE ALL ON public.facturas_fiso_d6 FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.facturas_fiso_d6 FROM authenticated;
GRANT SELECT ON public.facturas_fiso_d6 TO authenticated;

-- Aplica la ultima carga de facturas (fuente FACTURAS_D6 en el staging). Solo service_role.
CREATE OR REPLACE FUNCTION public.d6_aplicar_facturas_fiso(p_run_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_filas INTEGER;
  v_nuevas INTEGER;
  v_pagadas INTEGER;
BEGIN
  SELECT count(*) INTO v_filas FROM public.oracle_d6_staging WHERE sync_run_id = p_run_id AND fuente = 'FACTURAS_D6';

  WITH src AS (
    SELECT s.payload p FROM public.oracle_d6_staging s WHERE s.sync_run_id = p_run_id AND s.fuente = 'FACTURAS_D6'
  ), up AS (
    INSERT INTO public.facturas_fiso_d6 AS t (
      correlativo_cobro, serie, factura, estado_documento, ramo, fianza, endoso, fianza_id, beneficiario_id, fecha_emision, prima, derechos, otros, iva,
      total, saldo, fecha_pago, fecha_anulacion, meses_plazo, sync_run_id, actualizada_at)
    SELECT (p->>'CORRELATIVO_UNICO_COBRO')::bigint, NULLIF(p->>'SERIE', ''), NULLIF(p->>'FACTURA', '')::bigint,
           NULLIF(p->>'COD_ESTADO_DOCUMENTO', ''), NULLIF(p->>'RAMO', ''), (p->>'FIANZA')::bigint,
           COALESCE(NULLIF(p->>'ENDOSO', '')::int, 0),
           (SELECT f.id FROM public.fianzas f WHERE f.fianza = (p->>'FIANZA')::bigint
              AND f.endoso = COALESCE(NULLIF(p->>'ENDOSO', '')::int, 0) LIMIT 1),
           (SELECT b.id FROM public.beneficiarios b WHERE b.codigo_contacto = NULLIF(p->>'COD_CONTACTO_BENEFICIARIO', '')::int),
           (p->>'FEC_EMISION')::date,
           COALESCE(NULLIF(p->>'PRIMA', '')::numeric, 0), COALESCE(NULLIF(p->>'DERECHOS', '')::numeric, 0),
           COALESCE(NULLIF(p->>'OTROS', '')::numeric, 0), COALESCE(NULLIF(p->>'IVA', '')::numeric, 0),
           (p->>'TOTAL_FACTURA')::numeric, COALESCE(NULLIF(p->>'SALDO_FACTURA', '')::numeric, 0),
           NULLIF(p->>'FEC_PAGO', '')::date,
           -- Anulada si FISO le puso fecha de anulacion o la marco con estado A.
           COALESCE(NULLIF(p->>'FEC_ANULACION', '')::date,
                    CASE WHEN p->>'COD_ESTADO_DOCUMENTO' = 'A' THEN (p->>'FEC_EMISION')::date END),
           NULLIF(p->>'MESES_PLAZO', '')::int, p_run_id, now()
    FROM src
    ON CONFLICT (correlativo_cobro) DO UPDATE SET
      serie = EXCLUDED.serie, factura = EXCLUDED.factura, estado_documento = EXCLUDED.estado_documento,
      fianza_id = COALESCE(EXCLUDED.fianza_id, t.fianza_id),
      beneficiario_id = COALESCE(EXCLUDED.beneficiario_id, t.beneficiario_id),
      prima = EXCLUDED.prima, derechos = EXCLUDED.derechos, otros = EXCLUDED.otros, iva = EXCLUDED.iva,
      total = EXCLUDED.total, saldo = EXCLUDED.saldo, fecha_pago = EXCLUDED.fecha_pago,
      fecha_anulacion = EXCLUDED.fecha_anulacion, sync_run_id = EXCLUDED.sync_run_id, actualizada_at = now()
    WHERE (t.serie, t.factura, t.estado_documento, t.saldo, t.fecha_pago, t.fecha_anulacion, t.total, t.fianza_id, t.beneficiario_id)
          IS DISTINCT FROM (EXCLUDED.serie, EXCLUDED.factura, EXCLUDED.estado_documento, EXCLUDED.saldo,
                            EXCLUDED.fecha_pago, EXCLUDED.fecha_anulacion, EXCLUDED.total,
                            COALESCE(EXCLUDED.fianza_id, t.fianza_id), COALESCE(EXCLUDED.beneficiario_id, t.beneficiario_id))
    RETURNING (xmax = 0) AS nueva
  )
  SELECT count(*) FILTER (WHERE nueva) INTO v_nuevas FROM up;

  -- Una fianza de contado queda liberada para entrega cuando FISO registra el pago de su factura.
  WITH pagadas AS (
    UPDATE public.fianzas f SET pago_confirmado_at = COALESCE(f.pago_confirmado_at, ff.fecha_pago::timestamptz)
    FROM public.facturas_fiso_d6 ff
    WHERE ff.fianza_id = f.id AND ff.fecha_pago IS NOT NULL AND ff.fecha_anulacion IS NULL
      AND f.pago_confirmado_at IS NULL
    RETURNING f.id
  )
  SELECT count(*) INTO v_pagadas FROM pagadas;

  -- Los montos provisionales de una fianza emitida en la app se reemplazan con lo que FISO facturo
  -- en la factura de emision. La carga de cartera hace lo mismo con la poliza.
  RETURN jsonb_build_object('filas', v_filas, 'facturas_nuevas', v_nuevas, 'pagos_confirmados', v_pagadas,
    'sin_beneficiario', (SELECT count(*) FROM public.facturas_fiso_d6 WHERE beneficiario_id IS NULL),
    'sin_marca', (SELECT count(*) FROM public.facturas_fiso_d6 ff WHERE NOT EXISTS (
        SELECT 1 FROM public.grupo_beneficiario_rel r JOIN public.grupos_beneficiarios g ON g.id = r.grupo_id AND g.codigo <> 'GRP-GENERAL'
        WHERE r.beneficiario_id = ff.beneficiario_id)));
END;
$$;
REVOKE EXECUTE ON FUNCTION public.d6_aplicar_facturas_fiso(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.d6_aplicar_facturas_fiso(UUID) TO service_role;

-- ============================================================================
-- 3. Partidas: una por factura de FISO, y ninguna factura en dos estados de cuenta
-- ============================================================================
ALTER TABLE public.estado_cuenta_items_d6
  ADD COLUMN IF NOT EXISTS factura_correlativo BIGINT,
  ADD COLUMN IF NOT EXISTS factura_serie TEXT,
  ADD COLUMN IF NOT EXISTS factura_numero BIGINT,
  ADD COLUMN IF NOT EXISTS fianza BIGINT,
  ADD COLUMN IF NOT EXISTS endoso INTEGER,
  ADD COLUMN IF NOT EXISTS fecha_factura DATE;
ALTER TABLE public.estado_cuenta_items_d6 ALTER COLUMN fianza_id DROP NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_partida_factura ON public.estado_cuenta_items_d6 (factura_correlativo)
  WHERE factura_correlativo IS NOT NULL;

CREATE OR REPLACE FUNCTION public.d6_generar_estado_cuenta(p_grupo_id UUID, p_periodo DATE)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_periodo DATE := date_trunc('month', p_periodo)::date;
  v_id UUID;
  v_estado TEXT;
  v_regla public.reglas_cobro_d6%ROWTYPE;
  v_grupo public.grupos_beneficiarios%ROWTYPE;
  v_vence DATE;
  v_total NUMERIC(15,2);
BEGIN
  IF NOT public.has_d6_role(ARRAY['admin', 'coordinacion_comercial']::public.d6_role[]) THEN
    RAISE EXCEPTION 'Solo Comercializacion genera estados de cuenta';
  END IF;
  IF v_periodo >= date_trunc('month', CURRENT_DATE)::date THEN
    RAISE EXCEPTION 'Solo se genera el estado de cuenta de un mes cerrado';
  END IF;
  SELECT * INTO v_grupo FROM public.grupos_beneficiarios WHERE id = p_grupo_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Marca no encontrada'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.oracle_sync_runs_d6 WHERE fuente = 'FACTURAS_D6' AND estado = 'COMPLETO') THEN
    RAISE EXCEPTION 'No hay una carga de facturas de FISO. Corra la carga de Oracle antes de generar.';
  END IF;

  SELECT * INTO v_regla FROM public.reglas_cobro_d6
  WHERE codigo_marca = COALESCE(v_grupo.codigo_regla_cobro, 'GENERAL') AND activa;
  IF NOT FOUND THEN
    SELECT * INTO v_regla FROM public.reglas_cobro_d6 WHERE codigo_marca = 'GENERAL';
  END IF;
  v_vence := CASE v_regla.vencimiento
    WHEN 'ANTES_DE_ENTREGA' THEN CURRENT_DATE
    ELSE (v_periodo + INTERVAL '2 months - 1 day')::date
  END;

  SELECT id, estado INTO v_id, v_estado FROM public.estados_cuenta_d6 WHERE grupo_id = p_grupo_id AND periodo = v_periodo;
  IF v_id IS NOT NULL AND v_estado <> 'BORRADOR' THEN
    RAISE EXCEPTION 'El estado de cuenta de ese mes ya fue enviado y no se regenera';
  END IF;

  IF v_id IS NULL THEN
    INSERT INTO public.estados_cuenta_d6 (grupo_id, periodo, fecha_vencimiento, total, estado, numero, generado_por)
    VALUES (p_grupo_id, v_periodo, v_vence, 0, 'BORRADOR',
            'EC-' || to_char(v_periodo, 'YYYYMM') || '-' || upper(substr(replace(v_grupo.codigo, 'GRP-', ''), 1, 12)), auth.uid())
    RETURNING id INTO v_id;
  ELSE
    DELETE FROM public.estado_cuenta_items_d6 WHERE estado_cuenta_id = v_id;
    UPDATE public.estados_cuenta_d6 SET fecha_vencimiento = v_vence, generado_por = auth.uid() WHERE id = v_id;
  END IF;

  INSERT INTO public.estado_cuenta_items_d6 (estado_cuenta_id, fianza_id, fianza, endoso, factura_correlativo, factura_serie,
                                             factura_numero, fecha_factura, concepto, prima, derechos, iva, otros, monto)
  SELECT v_id, ff.fianza_id, ff.fianza, ff.endoso, ff.correlativo_cobro, ff.serie, ff.factura, ff.fecha_emision,
         CASE WHEN ff.factura IS NULL THEN 'Nota de cobro ' || ff.correlativo_cobro
              ELSE 'Factura ' || COALESCE(ff.serie || '-', '') || ff.factura END
           || CASE WHEN ff.endoso = 0 THEN '' ELSE ', endoso ' || ff.endoso END,
         ff.prima, ff.derechos, ff.iva, ff.otros, ff.total
  FROM public.facturas_fiso_d6 ff
  JOIN public.grupo_beneficiario_rel r ON r.beneficiario_id = ff.beneficiario_id AND r.grupo_id = p_grupo_id
  WHERE ff.fecha_emision >= v_periodo AND ff.fecha_emision < (v_periodo + INTERVAL '1 month')::date
    AND ff.fecha_anulacion IS NULL
    AND NOT EXISTS (SELECT 1 FROM public.estado_cuenta_items_d6 i WHERE i.factura_correlativo = ff.correlativo_cobro);

  SELECT COALESCE(SUM(monto), 0) INTO v_total FROM public.estado_cuenta_items_d6 WHERE estado_cuenta_id = v_id;
  IF v_total = 0 THEN
    DELETE FROM public.estados_cuenta_d6 WHERE id = v_id;
    RETURN NULL;
  END IF;
  UPDATE public.estados_cuenta_d6 SET total = v_total WHERE id = v_id;
  RETURN v_id;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.d6_generar_estado_cuenta(UUID, DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.d6_generar_estado_cuenta(UUID, DATE) TO authenticated;

CREATE OR REPLACE FUNCTION public.d6_enviar_estado_cuenta(p_estado_cuenta_id UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_ec public.estados_cuenta_d6%ROWTYPE;
BEGIN
  IF NOT public.has_d6_role(ARRAY['admin', 'coordinacion_comercial']::public.d6_role[]) THEN
    RAISE EXCEPTION 'Solo Comercializacion envia estados de cuenta';
  END IF;
  SELECT * INTO v_ec FROM public.estados_cuenta_d6 WHERE id = p_estado_cuenta_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Estado de cuenta no encontrado'; END IF;
  IF v_ec.estado <> 'BORRADOR' THEN RAISE EXCEPTION 'El estado de cuenta ya fue enviado'; END IF;
  IF v_ec.total <= 0 THEN RAISE EXCEPTION 'El estado de cuenta no tiene partidas'; END IF;
  UPDATE public.estados_cuenta_d6 SET estado = 'ENVIADO', enviado_at = now(), enviado_por = auth.uid()
  WHERE id = p_estado_cuenta_id;

  INSERT INTO public.notificaciones (user_id, titulo, mensaje, link)
  SELECT DISTINCT ug.user_id, 'Estado de cuenta ' || to_char(v_ec.periodo, 'MM/YYYY'),
         'Total Q' || to_char(v_ec.total, 'FM999,999,990.00') || ', vence el ' || to_char(v_ec.fecha_vencimiento, 'DD/MM/YYYY'),
         '/cuenta-por-cobrar'
  FROM public.user_grupos ug WHERE ug.grupo_id = v_ec.grupo_id;
END;
$$;

-- ============================================================================
-- 4. Un estado de cuenta enviado no cambia
-- ============================================================================
CREATE OR REPLACE FUNCTION public.d6_estado_cuenta_inmutable()
RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.estado <> 'BORRADOR' THEN RAISE EXCEPTION 'Un estado de cuenta enviado no se borra'; END IF;
    RETURN OLD;
  END IF;
  IF OLD.estado <> 'BORRADOR' AND (
       NEW.total IS DISTINCT FROM OLD.total OR NEW.periodo IS DISTINCT FROM OLD.periodo
    OR NEW.grupo_id IS DISTINCT FROM OLD.grupo_id OR NEW.fecha_vencimiento IS DISTINCT FROM OLD.fecha_vencimiento
    OR NEW.numero IS DISTINCT FROM OLD.numero OR NEW.enviado_at IS DISTINCT FROM OLD.enviado_at
    OR NEW.estado = 'BORRADOR') THEN
    RAISE EXCEPTION 'Un estado de cuenta enviado no se modifica. Solo cambian su estado de pago, el lote y los DTE.';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_estado_cuenta_inmutable ON public.estados_cuenta_d6;
CREATE TRIGGER trg_estado_cuenta_inmutable BEFORE UPDATE OR DELETE ON public.estados_cuenta_d6
  FOR EACH ROW EXECUTE FUNCTION public.d6_estado_cuenta_inmutable();

CREATE OR REPLACE FUNCTION public.d6_partida_inmutable()
RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public
AS $$
DECLARE
  v_estado TEXT;
BEGIN
  SELECT estado INTO v_estado FROM public.estados_cuenta_d6
  WHERE id = CASE WHEN TG_OP = 'INSERT' THEN NEW.estado_cuenta_id ELSE OLD.estado_cuenta_id END;
  -- Si el estado de cuenta ya no existe es un borrado en cascada de un borrador.
  IF v_estado IS NOT NULL AND v_estado <> 'BORRADOR' THEN
    RAISE EXCEPTION 'Las partidas de un estado de cuenta enviado no se modifican';
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;
DROP TRIGGER IF EXISTS trg_partida_inmutable ON public.estado_cuenta_items_d6;
CREATE TRIGGER trg_partida_inmutable BEFORE INSERT OR UPDATE OR DELETE ON public.estado_cuenta_items_d6
  FOR EACH ROW EXECUTE FUNCTION public.d6_partida_inmutable();

-- ============================================================================
-- 5. Cuadre con FISO
-- ============================================================================
CREATE OR REPLACE FUNCTION public.d6_cuadre_fiso()
RETURNS TABLE(tipo TEXT, fianza BIGINT, fianza_id UUID, cliente_id UUID, afianzado TEXT, marca TEXT, detalle TEXT)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NOT public.has_d6_role(ARRAY['admin', 'suscripcion', 'cobros', 'coordinacion_comercial', 'contabilidad']::public.d6_role[]) THEN
    RAISE EXCEPTION 'No tiene permiso para ver el cuadre';
  END IF;
  RETURN QUERY
  WITH fiso AS (
    SELECT DISTINCT ON ((s.payload->>'FIANZA')::bigint)
      (s.payload->>'FIANZA')::bigint AS fianza, (s.payload->>'ENDOSO')::int AS endoso,
      s.payload->>'STATUS' AS status, NULLIF(s.payload->>'FECHA_CANCELACION', '')::date AS cancelacion,
      NULLIF(s.payload->>'FECHA_ANULACION', '')::date AS anulacion,
      NULLIF(s.payload->>'VIGENCIA_HASTA', '')::date AS hasta
    FROM public.oracle_d6_staging s
    WHERE s.fuente = 'CARTERA_D6'
      AND s.sync_run_id = (SELECT r.id FROM public.oracle_sync_runs_d6 r
                           WHERE r.fuente = 'CARTERA_D6' AND r.estado = 'COMPLETO' ORDER BY r.ejecutado_en DESC LIMIT 1)
    ORDER BY (s.payload->>'FIANZA')::bigint, (s.payload->>'ENDOSO')::int DESC
  ),
  app AS (
    SELECT DISTINCT ON (vf.fianza) vf.* FROM public.v_fianzas vf ORDER BY vf.fianza, vf.endoso DESC
  )
  -- 1. La marca pidio la baja y la app la aprobo, pero en FISO sigue vigente.
  SELECT 'POR_ANULAR_EN_FISO'::text, a.fianza, a.id, a.cliente_id, a.cliente_nombre, a.marca_nombre,
         'Baja aprobada con efecto al ' || to_char(a.fecha_cancelacion, 'DD/MM/YYYY') || '. En FISO sigue vigente.'
  FROM app a JOIN fiso f ON f.fianza = a.fianza
  WHERE a.estado IN ('EN_BAJA', 'CANCELADA') AND a.fecha_cancelacion <= CURRENT_DATE
    AND COALESCE(f.status, '') <> 'C' AND f.cancelacion IS NULL AND f.anulacion IS NULL
  UNION ALL
  -- 2. FISO la cancelo y nadie pidio la baja en la app.
  SELECT 'CANCELADA_SIN_SOLICITUD', a.fianza, a.id, a.cliente_id, a.cliente_nombre, a.marca_nombre,
         'Cancelada en FISO el ' || to_char(COALESCE(f.cancelacion, f.anulacion), 'DD/MM/YYYY') || ' sin solicitud de baja registrada.'
  FROM app a JOIN fiso f ON f.fianza = a.fianza
  WHERE (f.status = 'C' OR f.cancelacion IS NOT NULL OR f.anulacion IS NOT NULL)
    AND COALESCE(f.cancelacion, f.anulacion) >= CURRENT_DATE - 365
    AND NOT EXISTS (SELECT 1 FROM public.solicitudes_baja b
                    JOIN public.fianzas fz ON fz.id = b.fianza_id WHERE fz.fianza = a.fianza)
  UNION ALL
  -- 3. Emitida en la app y todavia no aparece en FISO.
  SELECT 'EMITIDA_SIN_FISO', a.fianza, a.id, a.cliente_id, a.cliente_nombre, a.marca_nombre,
         'Emitida en la app el ' || to_char(a.fecha_emision, 'DD/MM/YYYY') || '. No aparece en la ultima carga de FISO.'
  FROM app a
  WHERE a.estado NOT IN ('CANCELADA', 'ANULADA') AND a.fecha_emision >= CURRENT_DATE - 90
    AND NOT EXISTS (SELECT 1 FROM fiso f WHERE f.fianza = a.fianza)
    AND EXISTS (SELECT 1 FROM fiso)
  UNION ALL
  -- 4. El mismo afianzado con dos codigos de contacto (cambio de codigo o duplicado).
  SELECT 'CODIGO_DUPLICADO', NULL::bigint, NULL::uuid, c.id, c.nombre, NULL::text,
         'Mismo nombre que el codigo ' || string_agg(DISTINCT c2.codigo_contacto::text, ', ') || '. Codigo de este: ' || c.codigo_contacto
  FROM public.clientes c
  JOIN public.clientes c2 ON c2.id <> c.id AND public.d6_normalizar(c2.nombre) = public.d6_normalizar(c.nombre)
  WHERE EXISTS (SELECT 1 FROM public.fianzas f WHERE f.cliente_id = c.id)
    AND EXISTS (SELECT 1 FROM public.fianzas f WHERE f.cliente_id = c2.id)
  GROUP BY c.id, c.nombre, c.codigo_contacto
  UNION ALL
  -- 5. Estado de cuenta cuyo total no coincide con las facturas de FISO del mes.
  SELECT 'ESTADO_CUENTA_DESCUADRADO', NULL::bigint, NULL::uuid, NULL::uuid, NULL::text, g.nombre,
         'Estado de cuenta ' || ec.numero || ': Q' || to_char(ec.total, 'FM999,999,990.00') || ' contra Q'
           || to_char(COALESCE(x.total, 0), 'FM999,999,990.00') || ' facturados en FISO.'
  FROM public.estados_cuenta_d6 ec
  JOIN public.grupos_beneficiarios g ON g.id = ec.grupo_id
  LEFT JOIN LATERAL (
    SELECT sum(ff.total) AS total FROM public.facturas_fiso_d6 ff
    JOIN public.grupo_beneficiario_rel r ON r.beneficiario_id = ff.beneficiario_id AND r.grupo_id = ec.grupo_id
    WHERE ff.fecha_emision >= ec.periodo AND ff.fecha_emision < (ec.periodo + INTERVAL '1 month')::date
      AND ff.fecha_anulacion IS NULL) x ON true
  WHERE ec.total IS DISTINCT FROM COALESCE(x.total, 0)
  UNION ALL
  -- 6. Factura de FISO de un beneficiario que no esta asignado a ninguna marca: nadie la cobra.
  SELECT 'FACTURA_SIN_MARCA', ff.fianza, ff.fianza_id, NULL::uuid, NULL::text, NULL::text,
         'Cobro ' || ff.correlativo_cobro || ' del ' || to_char(ff.fecha_emision, 'DD/MM/YYYY')
           || ' por Q' || to_char(ff.total, 'FM999,999,990.00') || '. Asigne el beneficiario a una marca.'
  FROM public.facturas_fiso_d6 ff
  WHERE ff.fecha_anulacion IS NULL AND ff.fecha_emision >= CURRENT_DATE - 365
    AND NOT EXISTS (SELECT 1 FROM public.grupo_beneficiario_rel r
                    JOIN public.grupos_beneficiarios g ON g.id = r.grupo_id AND g.codigo <> 'GRP-GENERAL'
                    WHERE r.beneficiario_id = ff.beneficiario_id);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.d6_cuadre_fiso() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.d6_cuadre_fiso() TO authenticated;

-- ============================================================================
-- 6. Saldo a favor visible: un pago de mas ya no se esconde en GREATEST(..., 0)
-- ============================================================================
CREATE OR REPLACE VIEW public.v_estados_cuenta
WITH (security_invoker = true)
AS
SELECT
  ec.id, ec.numero, ec.grupo_id, g.nombre AS marca_nombre, ec.periodo, ec.fecha_vencimiento,
  ec.total, ec.estado, ec.enviado_at, ec.lote_fiso, ec.dte_numeros, ec.created_at,
  (SELECT count(*) FROM public.estado_cuenta_items_d6 i WHERE i.estado_cuenta_id = ec.id) AS partidas,
  COALESCE(p.conciliado, 0) AS pagado,
  COALESCE(p.en_verificacion, 0) AS en_verificacion,
  GREATEST(ec.total - COALESCE(p.conciliado, 0), 0) AS saldo,
  CASE WHEN ec.estado IN ('ENVIADO', 'PARCIAL') AND ec.fecha_vencimiento < CURRENT_DATE
       THEN CURRENT_DATE - ec.fecha_vencimiento ELSE 0 END AS dias_vencido,
  CASE
    WHEN ec.estado = 'BORRADOR' THEN 'BORRADOR'
    WHEN ec.estado = 'PAGADO' THEN 'PAGADO'
    WHEN ec.fecha_vencimiento >= CURRENT_DATE THEN 'AL_DIA'
    WHEN CURRENT_DATE - ec.fecha_vencimiento <= 30 THEN '1_30'
    WHEN CURRENT_DATE - ec.fecha_vencimiento <= 60 THEN '31_60'
    WHEN CURRENT_DATE - ec.fecha_vencimiento <= 90 THEN '61_90'
    ELSE '90_MAS'
  END AS antiguedad,
  GREATEST(COALESCE(p.conciliado, 0) - ec.total, 0) AS saldo_a_favor
FROM public.estados_cuenta_d6 ec
JOIN public.grupos_beneficiarios g ON g.id = ec.grupo_id
LEFT JOIN LATERAL (
  SELECT SUM(monto) FILTER (WHERE estado = 'CONCILIADO') AS conciliado,
         SUM(monto) FILTER (WHERE estado = 'PENDIENTE') AS en_verificacion
  FROM public.pagos WHERE estado_cuenta_id = ec.id
) p ON true;
