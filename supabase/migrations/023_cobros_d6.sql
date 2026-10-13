-- Migracion 023: cuenta por cobrar D-6.
--
-- Procedimiento v01, seccion Cobro de prima: en los primeros 10 dias de cada mes la
-- Coordinadora de Comercializacion filtra en FISO las polizas y endosos emitidos el mes
-- anterior y arma el estado de cuenta por marca. Cobros recibe la boleta, concilia,
-- genera lote y DTE. Contabilidad valida contra el estado bancario.
--
--   * Estado de cuenta por marca (grupo) y mes de emision.
--   * Partida = prima + derechos + IVA + otros de cada poliza o endoso emitido.
--   * Vencimiento segun reglas_cobro_d6: ADMOSA ultimo dia del mes siguiente, UMA contado.
--   * Pagos ligados al estado de cuenta (pago en bloque), conciliacion atomica.

-- ============================================================================
-- 1. Modelo
-- ============================================================================
ALTER TABLE public.estados_cuenta_d6
  ADD COLUMN IF NOT EXISTS grupo_id UUID REFERENCES public.grupos_beneficiarios(id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS numero TEXT,
  ADD COLUMN IF NOT EXISTS lote_fiso TEXT,
  ADD COLUMN IF NOT EXISTS dte_numeros TEXT,
  ADD COLUMN IF NOT EXISTS generado_por UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS enviado_por UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL;
ALTER TABLE public.estados_cuenta_d6 ALTER COLUMN beneficiario_id DROP NOT NULL;
ALTER TABLE public.estados_cuenta_d6 DROP CONSTRAINT IF EXISTS estados_cuenta_d6_beneficiario_id_periodo_key;
CREATE UNIQUE INDEX IF NOT EXISTS uq_estado_cuenta_grupo_periodo ON public.estados_cuenta_d6 (grupo_id, periodo);

ALTER TABLE public.estado_cuenta_items_d6
  ADD COLUMN IF NOT EXISTS prima NUMERIC(15,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS derechos NUMERIC(15,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS iva NUMERIC(15,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS otros NUMERIC(15,2) NOT NULL DEFAULT 0;

ALTER TABLE public.pagos
  ADD COLUMN IF NOT EXISTS estado_cuenta_id UUID REFERENCES public.estados_cuenta_d6(id) ON DELETE RESTRICT;
ALTER TABLE public.pagos ALTER COLUMN fianza_id DROP NOT NULL;
ALTER TABLE public.pagos DROP CONSTRAINT IF EXISTS pagos_destino_chk;
ALTER TABLE public.pagos ADD CONSTRAINT pagos_destino_chk CHECK (fianza_id IS NOT NULL OR estado_cuenta_id IS NOT NULL);

ALTER TABLE public.conciliaciones ALTER COLUMN fianza_id DROP NOT NULL;
ALTER TABLE public.conciliaciones ADD COLUMN IF NOT EXISTS estado_cuenta_id UUID REFERENCES public.estados_cuenta_d6(id) ON DELETE SET NULL;

ALTER TABLE public.conciliacion_propuestas_d6
  ADD COLUMN IF NOT EXISTS banco TEXT,
  ADD COLUMN IF NOT EXISTS descripcion TEXT;

-- Dias de credito por regla. CONTADO vence el mismo dia de emision del estado.
ALTER TABLE public.reglas_cobro_d6 ADD COLUMN IF NOT EXISTS nombre TEXT;
UPDATE public.reglas_cobro_d6 SET nombre = 'Cuotas, vence el ultimo dia del mes siguiente' WHERE codigo_marca = 'ADMOSA';
UPDATE public.reglas_cobro_d6 SET nombre = 'Contado, la poliza se entrega pagada' WHERE codigo_marca = 'GRUPO_UMA';
INSERT INTO public.reglas_cobro_d6 (codigo_marca, modalidad, entrega_condicionada_pago, vencimiento, nombre)
VALUES ('GENERAL', 'CUOTAS', false, 'ULTIMO_DIA_MES_SIGUIENTE', 'General, vence el ultimo dia del mes siguiente')
ON CONFLICT (codigo_marca) DO NOTHING;

-- ============================================================================
-- 2. Generar el estado de cuenta de una marca para un mes
-- ============================================================================
CREATE OR REPLACE FUNCTION public.d6_generar_estado_cuenta(p_grupo_id UUID, p_periodo DATE)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_periodo DATE := date_trunc('month', p_periodo)::date;
  v_grupo public.grupos_beneficiarios%ROWTYPE;
  v_regla public.reglas_cobro_d6%ROWTYPE;
  v_id UUID;
  v_estado TEXT;
  v_vence DATE;
  v_total NUMERIC(15,2);
BEGIN
  IF NOT public.has_d6_role(ARRAY['admin', 'coordinacion_comercial', 'cobros']::public.d6_role[]) THEN
    RAISE EXCEPTION 'Solo Comercializacion o Cobros generan estados de cuenta';
  END IF;
  SELECT * INTO v_grupo FROM public.grupos_beneficiarios WHERE id = p_grupo_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Marca no encontrada'; END IF;
  IF v_periodo >= date_trunc('month', CURRENT_DATE)::date THEN
    RAISE EXCEPTION 'Solo se generan meses cerrados. El mes en curso se cobra el mes siguiente.';
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
    RAISE EXCEPTION 'El estado de cuenta de ese mes ya fue enviado y no se puede regenerar';
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

  INSERT INTO public.estado_cuenta_items_d6 (estado_cuenta_id, fianza_id, concepto, prima, derechos, iva, otros, monto)
  SELECT v_id, f.id,
         CASE WHEN f.endoso = 0 THEN 'Emision' ELSE 'Endoso ' || f.endoso END,
         f.prima, f.derechos, COALESCE(f.iva, 0), COALESCE(f.otros, 0),
         f.prima + f.derechos + COALESCE(f.iva, 0) + COALESCE(f.otros, 0)
  FROM public.fianzas f
  JOIN public.grupo_beneficiario_rel r ON r.beneficiario_id = f.beneficiario_id AND r.grupo_id = p_grupo_id
  WHERE f.fecha_emision >= v_periodo AND f.fecha_emision < (v_periodo + INTERVAL '1 month')
    AND COALESCE(f.operational_status::text, '') <> 'ANULADA'
    AND f.prima + f.derechos + COALESCE(f.iva, 0) + COALESCE(f.otros, 0) > 0;

  SELECT COALESCE(SUM(monto), 0) INTO v_total FROM public.estado_cuenta_items_d6 WHERE estado_cuenta_id = v_id;
  UPDATE public.estados_cuenta_d6 SET total = v_total WHERE id = v_id;
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.d6_enviar_estado_cuenta(p_estado_cuenta_id UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_ec public.estados_cuenta_d6%ROWTYPE;
BEGIN
  IF NOT public.has_d6_role(ARRAY['admin', 'coordinacion_comercial', 'cobros']::public.d6_role[]) THEN
    RAISE EXCEPTION 'Solo Comercializacion o Cobros envian estados de cuenta';
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
-- 3. Pagos y conciliacion
-- ============================================================================
-- Recalcula el estado de un estado de cuenta segun lo conciliado.
CREATE OR REPLACE FUNCTION public.d6_actualizar_saldo_estado_cuenta(p_estado_cuenta_id UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_ec public.estados_cuenta_d6%ROWTYPE;
  v_pagado NUMERIC(15,2);
BEGIN
  SELECT * INTO v_ec FROM public.estados_cuenta_d6 WHERE id = p_estado_cuenta_id FOR UPDATE;
  IF NOT FOUND OR v_ec.estado = 'BORRADOR' THEN RETURN; END IF;
  SELECT COALESCE(SUM(monto), 0) INTO v_pagado FROM public.pagos
  WHERE estado_cuenta_id = p_estado_cuenta_id AND estado = 'CONCILIADO';
  UPDATE public.estados_cuenta_d6 SET estado = CASE
      WHEN v_pagado >= v_ec.total THEN 'PAGADO'
      WHEN v_pagado > 0 THEN 'PARCIAL'
      ELSE 'ENVIADO' END
  WHERE id = p_estado_cuenta_id;

  -- Contado (UMA): la poliza se entrega cuando su estado de cuenta queda pagado.
  IF v_pagado >= v_ec.total THEN
    UPDATE public.fianzas f SET pago_confirmado_at = COALESCE(f.pago_confirmado_at, now()), lote_fiso = COALESCE(f.lote_fiso, v_ec.lote_fiso)
    FROM public.estado_cuenta_items_d6 i
    WHERE i.estado_cuenta_id = p_estado_cuenta_id AND i.fianza_id = f.id;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.d6_registrar_pago(
  p_estado_cuenta_id UUID, p_monto NUMERIC, p_fecha_pago DATE, p_banco TEXT,
  p_referencia TEXT, p_metodo TEXT DEFAULT 'DEPOSITO', p_comprobante_path TEXT DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_ec public.estados_cuenta_d6%ROWTYPE;
  v_id UUID;
BEGIN
  IF NOT public.has_d6_role(ARRAY['admin', 'cobros', 'contabilidad']::public.d6_role[]) THEN
    RAISE EXCEPTION 'Solo Cobros registra pagos';
  END IF;
  SELECT * INTO v_ec FROM public.estados_cuenta_d6 WHERE id = p_estado_cuenta_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Estado de cuenta no encontrado'; END IF;
  IF v_ec.estado = 'BORRADOR' THEN RAISE EXCEPTION 'Envie el estado de cuenta antes de registrar pagos'; END IF;
  IF COALESCE(p_monto, 0) <= 0 THEN RAISE EXCEPTION 'El monto debe ser mayor que cero'; END IF;
  IF NULLIF(btrim(COALESCE(p_referencia, '')), '') IS NULL THEN RAISE EXCEPTION 'Indique el numero de boleta o referencia'; END IF;
  IF EXISTS (SELECT 1 FROM public.pagos WHERE upper(btrim(referencia_bancaria)) = upper(btrim(p_referencia))
             AND COALESCE(banco, '') = COALESCE(p_banco, '') AND estado <> 'RECHAZADO') THEN
    RAISE EXCEPTION 'Esa boleta ya fue registrada';
  END IF;
  INSERT INTO public.pagos (estado_cuenta_id, monto, fecha_pago, banco, referencia_bancaria, metodo_pago,
                            comprobante_path, estado, registrado_por)
  VALUES (p_estado_cuenta_id, round(p_monto, 2), COALESCE(p_fecha_pago, CURRENT_DATE), NULLIF(btrim(p_banco), ''),
          btrim(p_referencia), COALESCE(p_metodo, 'DEPOSITO'), p_comprobante_path, 'PENDIENTE', auth.uid())
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

-- Confirma (o rechaza) un pago contra el banco. Atomico: pago, conciliacion y saldo.
CREATE OR REPLACE FUNCTION public.d6_conciliar_pago(
  p_pago_id UUID, p_confirmar BOOLEAN, p_monto_recibido NUMERIC DEFAULT NULL,
  p_notas TEXT DEFAULT NULL, p_propuesta_id UUID DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_p public.pagos%ROWTYPE;
  v_recibido NUMERIC(15,2);
  v_resultado public.resultado_conciliacion;
BEGIN
  IF NOT public.has_d6_role(ARRAY['admin', 'cobros', 'contabilidad']::public.d6_role[]) THEN
    RAISE EXCEPTION 'Solo Cobros o Contabilidad concilian pagos';
  END IF;
  SELECT * INTO v_p FROM public.pagos WHERE id = p_pago_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pago no encontrado'; END IF;
  IF v_p.estado <> 'PENDIENTE' THEN RAISE EXCEPTION 'El pago ya fue conciliado o rechazado'; END IF;

  v_recibido := COALESCE(p_monto_recibido, v_p.monto);
  v_resultado := CASE
    WHEN NOT p_confirmar THEN 'NO_ENCONTRADO'
    WHEN v_recibido = v_p.monto THEN 'CONCILIADO_EXACTO'
    ELSE 'DISCREPANCIA_MONTO' END;

  IF NOT p_confirmar AND NULLIF(btrim(COALESCE(p_notas, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Explique por que se rechaza el pago';
  END IF;

  INSERT INTO public.conciliaciones (pago_id, fianza_id, estado_cuenta_id, monto_esperado, monto_recibido, resultado, notas, conciliado_por)
  VALUES (v_p.id, v_p.fianza_id, v_p.estado_cuenta_id, v_p.monto, v_recibido, v_resultado, p_notas, auth.uid());

  -- Una discrepancia confirmada cuenta por lo que efectivamente llego al banco.
  UPDATE public.pagos SET
    estado = CASE WHEN p_confirmar THEN 'CONCILIADO' ELSE 'RECHAZADO' END::public.estado_pago_registro,
    monto = CASE WHEN p_confirmar THEN v_recibido ELSE monto END
  WHERE id = v_p.id;

  IF p_propuesta_id IS NOT NULL THEN
    UPDATE public.conciliacion_propuestas_d6 SET resultado = v_resultado, pago_id = v_p.id,
      resuelto_at = now(), resuelto_por = auth.uid()
    WHERE id = p_propuesta_id;
  END IF;

  IF v_p.estado_cuenta_id IS NOT NULL THEN
    PERFORM public.d6_actualizar_saldo_estado_cuenta(v_p.estado_cuenta_id);
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.d6_registrar_lote_fiso(p_estado_cuenta_id UUID, p_lote TEXT, p_dte TEXT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NOT public.has_d6_role(ARRAY['admin', 'cobros']::public.d6_role[]) THEN
    RAISE EXCEPTION 'Solo Cobros registra lotes y DTE';
  END IF;
  UPDATE public.estados_cuenta_d6 SET lote_fiso = NULLIF(btrim(p_lote), ''), dte_numeros = NULLIF(btrim(p_dte), '')
  WHERE id = p_estado_cuenta_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Estado de cuenta no encontrado'; END IF;
END;
$$;

-- ============================================================================
-- 4. Vistas
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
  END AS antiguedad
FROM public.estados_cuenta_d6 ec
JOIN public.grupos_beneficiarios g ON g.id = ec.grupo_id
LEFT JOIN LATERAL (
  SELECT SUM(monto) FILTER (WHERE estado = 'CONCILIADO') AS conciliado,
         SUM(monto) FILTER (WHERE estado = 'PENDIENTE') AS en_verificacion
  FROM public.pagos WHERE estado_cuenta_id = ec.id
) p ON true;
GRANT SELECT ON public.v_estados_cuenta TO authenticated;
REVOKE ALL ON public.v_estados_cuenta FROM anon;

-- Las marcas ven sus estados de cuenta por grupo, no solo por beneficiario.
DROP POLICY IF EXISTS "estados_cuenta: personal o la propia marca ven" ON public.estados_cuenta_d6;
CREATE POLICY "estados_cuenta: personal o la propia marca ven" ON public.estados_cuenta_d6 FOR SELECT
  USING (public.d6_es_personal_aseguradora()
         OR grupo_id IN (SELECT grupo_id FROM public.user_grupos WHERE user_id = auth.uid())
         OR public.d6_beneficiario_es_mio(beneficiario_id));
DROP POLICY IF EXISTS "partidas: personal o la propia marca ven" ON public.estado_cuenta_items_d6;
CREATE POLICY "partidas: personal o la propia marca ven" ON public.estado_cuenta_items_d6 FOR SELECT
  USING (EXISTS (SELECT 1 FROM public.estados_cuenta_d6 ec WHERE ec.id = estado_cuenta_items_d6.estado_cuenta_id));
DROP POLICY IF EXISTS "pagos: personal o la propia marca ven" ON public.pagos;
CREATE POLICY "pagos: personal o la propia marca ven" ON public.pagos FOR SELECT
  USING (public.d6_es_personal_aseguradora()
    OR EXISTS (SELECT 1 FROM public.estados_cuenta_d6 ec WHERE ec.id = pagos.estado_cuenta_id)
    OR EXISTS (SELECT 1 FROM public.fianzas f WHERE f.id = pagos.fianza_id AND public.d6_beneficiario_es_mio(f.beneficiario_id)));

-- Entrega condicionada al pago (regla de contado).
DROP VIEW IF EXISTS public.v_fianzas;
CREATE VIEW public.v_fianzas
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
  f.pago_confirmado_at,
  (COALESCE(rc.entrega_condicionada_pago, false) AND f.pago_confirmado_at IS NULL
     AND f.operational_status = 'VIGENTE') AS entrega_pendiente_pago,
  f.created_at, f.updated_at
FROM public.fianzas f
JOIN public.clientes c ON c.id = f.cliente_id
JOIN public.beneficiarios b ON b.id = f.beneficiario_id
LEFT JOIN LATERAL (
  SELECT gb.id, gb.nombre, gb.codigo_regla_cobro FROM public.grupo_beneficiario_rel r
  JOIN public.grupos_beneficiarios gb ON gb.id = r.grupo_id
  WHERE r.beneficiario_id = b.id AND gb.codigo <> 'GRP-GENERAL'
  ORDER BY gb.codigo LIMIT 1
) g ON true
LEFT JOIN public.reglas_cobro_d6 rc ON rc.codigo_marca = g.codigo_regla_cobro;
GRANT SELECT ON public.v_fianzas TO authenticated;
REVOKE ALL ON public.v_fianzas FROM anon;

REVOKE EXECUTE ON FUNCTION public.d6_generar_estado_cuenta(UUID, DATE) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.d6_enviar_estado_cuenta(UUID) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.d6_actualizar_saldo_estado_cuenta(UUID) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.d6_registrar_pago(UUID, NUMERIC, DATE, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.d6_conciliar_pago(UUID, BOOLEAN, NUMERIC, TEXT, UUID) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.d6_registrar_lote_fiso(UUID, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.d6_generar_estado_cuenta(UUID, DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION public.d6_enviar_estado_cuenta(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.d6_registrar_pago(UUID, NUMERIC, DATE, TEXT, TEXT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.d6_conciliar_pago(UUID, BOOLEAN, NUMERIC, TEXT, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.d6_registrar_lote_fiso(UUID, TEXT, TEXT) TO authenticated;

-- Los pagos solo entran por RPC. Cobros conserva lectura y la escritura directa se cierra.
DROP POLICY IF EXISTS "pagos: cobros administra" ON public.pagos;
DROP POLICY IF EXISTS "conciliaciones: cobros administra" ON public.conciliaciones;
