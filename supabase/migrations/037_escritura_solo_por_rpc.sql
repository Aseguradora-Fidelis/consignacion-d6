-- 037: escritura solo por RPC (auditoria del 2026-10-08).
-- Antes, Comercial, Suscripcion y Cobros podian cambiar altas, fianzas y estados de cuenta
-- con un UPDATE directo, sin reglas ni bitacora de quien. Ahora toda escritura de negocio
-- pasa por una funcion que valida y registra. Lo que queda directo es lo que no tiene reglas:
-- notificaciones propias, bitacora de comunicaciones, condiciones y administracion.

-- ============================================================================
-- 1. Politicas de escritura directa que se retiran
-- ============================================================================
DROP POLICY IF EXISTS "altas: comercial y suscripcion crean" ON public.solicitudes_alta;
DROP POLICY IF EXISTS "altas: comercial y suscripcion editan" ON public.solicitudes_alta;
DROP POLICY IF EXISTS "altas: admin borra" ON public.solicitudes_alta;

DROP POLICY IF EXISTS "fianzas: suscripcion crea" ON public.fianzas;
DROP POLICY IF EXISTS "fianzas: suscripcion edita" ON public.fianzas;
DROP POLICY IF EXISTS "fianzas: admin borra" ON public.fianzas;

DROP POLICY IF EXISTS "clientes: comercial y suscripcion crean" ON public.clientes;
DROP POLICY IF EXISTS "clientes: comercial y suscripcion editan" ON public.clientes;
DROP POLICY IF EXISTS "clientes: admin borra" ON public.clientes;

DROP POLICY IF EXISTS "documentos: personal revisa" ON public.documentos;
DROP POLICY IF EXISTS "documentos: personal borra" ON public.documentos;

DROP POLICY IF EXISTS "revisiones: suscripcion escribe" ON public.solicitud_revisiones;

DROP POLICY IF EXISTS "bajas: personal crea" ON public.solicitudes_baja;
DROP POLICY IF EXISTS "bajas: suscripcion resuelve" ON public.solicitudes_baja;
DROP POLICY IF EXISTS "bajas: admin borra" ON public.solicitudes_baja;

-- Estados de cuenta y partidas: lectura para quienes los administran, escritura solo por RPC.
DROP POLICY IF EXISTS "estados_cuenta: comercializacion y cobros administran" ON public.estados_cuenta_d6;
DROP POLICY IF EXISTS "partidas: comercializacion y cobros administran" ON public.estado_cuenta_items_d6;

-- Contratos: los crea emitir_fianza_d6.
DROP POLICY IF EXISTS "contratos: suscripcion administra" ON public.contratos_consignacion;
DROP POLICY IF EXISTS "contratos: personal ve" ON public.contratos_consignacion;
CREATE POLICY "contratos: personal ve" ON public.contratos_consignacion FOR SELECT
  USING (public.d6_es_personal_aseguradora());

-- Archivos del expediente: nadie los reemplaza ni los borra (conservacion de 5 años).
DROP POLICY IF EXISTS "expedientes: personal reemplaza archivos" ON storage.objects;
DROP POLICY IF EXISTS "expedientes: suscripcion borra archivos" ON storage.objects;

-- La conciliacion contra el banco es de Contabilidad (procedimiento v01).
DROP POLICY IF EXISTS "propuestas: cobros administra" ON public.conciliacion_propuestas_d6;
DROP POLICY IF EXISTS "propuestas: contabilidad administra" ON public.conciliacion_propuestas_d6;
CREATE POLICY "propuestas: contabilidad administra" ON public.conciliacion_propuestas_d6 FOR ALL
  USING ((SELECT public.has_d6_role(ARRAY['admin', 'contabilidad']::public.d6_role[])))
  WITH CHECK ((SELECT public.has_d6_role(ARRAY['admin', 'contabilidad']::public.d6_role[])));
DROP POLICY IF EXISTS "importaciones: cobros y comercializacion administran" ON public.importaciones_d6;
DROP POLICY IF EXISTS "importaciones: contabilidad y comercializacion administran" ON public.importaciones_d6;
CREATE POLICY "importaciones: contabilidad y comercializacion administran" ON public.importaciones_d6 FOR ALL
  USING ((SELECT public.has_d6_role(ARRAY['admin', 'contabilidad', 'coordinacion_comercial']::public.d6_role[])))
  WITH CHECK ((SELECT public.has_d6_role(ARRAY['admin', 'contabilidad', 'coordinacion_comercial']::public.d6_role[])));

-- ============================================================================
-- 2. Documentos: quien sube y quien revisa los pone el servidor
-- ============================================================================
CREATE OR REPLACE FUNCTION public.d6_documento_autor()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  -- Desde el portal anonimo no hay usuario: se respeta lo que puso la funcion del portal.
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;
  NEW.subido_por := auth.uid();
  IF NEW.estado_revision IS DISTINCT FROM 'PENDIENTE'
     AND public.has_d6_role(ARRAY['admin', 'suscripcion', 'comercial']::public.d6_role[]) THEN
    NEW.revisado_por := auth.uid();
    NEW.revisado_at := now();
  ELSE
    NEW.estado_revision := 'PENDIENTE';
    NEW.revisado_por := NULL;
    NEW.revisado_at := NULL;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_documento_autor ON public.documentos;
CREATE TRIGGER trg_documento_autor BEFORE INSERT ON public.documentos
  FOR EACH ROW EXECUTE FUNCTION public.d6_documento_autor();

CREATE OR REPLACE FUNCTION public.d6_revisar_documento(p_documento_id UUID, p_estado TEXT, p_comentario TEXT DEFAULT NULL)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_doc public.documentos;
BEGIN
  IF NOT public.has_d6_role(ARRAY['admin', 'suscripcion', 'comercial']::public.d6_role[]) THEN
    RAISE EXCEPTION 'Solo Suscripcion o Comercial revisan documentos';
  END IF;
  IF p_estado NOT IN ('APROBADO', 'RECHAZADO', 'PENDIENTE') THEN
    RAISE EXCEPTION 'Estado de revision no valido';
  END IF;
  IF p_estado = 'RECHAZADO' AND NULLIF(btrim(COALESCE(p_comentario, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Explique por que se rechaza: el motivo lo ven la marca y el distribuidor';
  END IF;
  SELECT * INTO v_doc FROM public.documentos WHERE id = p_documento_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Documento no encontrado'; END IF;
  IF v_doc.carga_pendiente THEN RAISE EXCEPTION 'El archivo todavia no termina de subir'; END IF;
  UPDATE public.documentos SET
    estado_revision = p_estado::public.d6_document_status,
    comentario_revision = NULLIF(btrim(COALESCE(p_comentario, '')), ''),
    revisado_por = CASE WHEN p_estado = 'PENDIENTE' THEN NULL ELSE auth.uid() END,
    revisado_at = CASE WHEN p_estado = 'PENDIENTE' THEN NULL ELSE now() END
  WHERE id = p_documento_id;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.d6_revisar_documento(UUID, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.d6_revisar_documento(UUID, TEXT, TEXT) TO authenticated;

-- ============================================================================
-- 3. Analisis de Suscripcion
-- ============================================================================
CREATE OR REPLACE FUNCTION public.d6_guardar_analisis(p_solicitud_id UUID, p_analisis JSONB)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NOT public.has_d6_role(ARRAY['admin', 'suscripcion']::public.d6_role[]) THEN
    RAISE EXCEPTION 'Solo Suscripcion registra el analisis';
  END IF;
  IF pg_column_size(p_analisis) > 256000 THEN RAISE EXCEPTION 'El analisis es demasiado grande'; END IF;
  UPDATE public.solicitudes_alta
  SET analisis_suscripcion = COALESCE(p_analisis, '{}'::jsonb)
                             || jsonb_build_object('guardado_por', auth.uid(), 'guardado_at', now())
  WHERE id = p_solicitud_id AND estado_operativo NOT IN ('EMITIDA', 'NO_ELEGIBLE');
  IF NOT FOUND THEN RAISE EXCEPTION 'La solicitud no existe o ya esta cerrada'; END IF;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.d6_guardar_analisis(UUID, JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.d6_guardar_analisis(UUID, JSONB) TO authenticated;

-- ============================================================================
-- 4. Emision: la prima la fija FISO
-- ============================================================================
-- La emision ocurre en FISO. La app registra el numero y guarda una prima provisional calculada
-- con la tarifa de la marca, que la carga de Oracle reemplaza con los montos reales.
ALTER TABLE public.fianzas ADD COLUMN IF NOT EXISTS montos_fuente TEXT NOT NULL DEFAULT 'FISO';
ALTER TABLE public.fianzas DROP CONSTRAINT IF EXISTS fianzas_montos_fuente_chk;
ALTER TABLE public.fianzas ADD CONSTRAINT fianzas_montos_fuente_chk CHECK (montos_fuente IN ('FISO', 'APP_PROVISIONAL'));
ALTER TABLE public.fianzas DROP CONSTRAINT IF EXISTS fianzas_vigencia_chk;
ALTER TABLE public.fianzas ADD CONSTRAINT fianzas_vigencia_chk
  CHECK (vigencia_desde IS NULL OR vigencia_hasta IS NULL OR vigencia_hasta >= vigencia_desde) NOT VALID;

CREATE OR REPLACE FUNCTION public.d6_tarifa_beneficiario(p_beneficiario_id UUID)
RETURNS NUMERIC
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT COALESCE((SELECT g.tarifa_prima FROM public.grupo_beneficiario_rel r
                   JOIN public.grupos_beneficiarios g ON g.id = r.grupo_id AND g.codigo <> 'GRP-GENERAL'
                   WHERE r.beneficiario_id = p_beneficiario_id AND g.tarifa_prima IS NOT NULL
                   LIMIT 1), 0.02);
$$;
REVOKE EXECUTE ON FUNCTION public.d6_tarifa_beneficiario(UUID) FROM PUBLIC, anon, authenticated;

-- Igual que src/domain/primas.js: un año paga la tarifa anual, otra vigencia se prorratea por dia.
CREATE OR REPLACE FUNCTION public.d6_calcular_prima(p_monto NUMERIC, p_tarifa NUMERIC, p_desde DATE, p_hasta DATE)
RETURNS TABLE(prima NUMERIC, derechos NUMERIC, iva NUMERIC)
LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
DECLARE
  v_dias INTEGER := COALESCE(p_hasta - p_desde + 1, 365);
  v_prima NUMERIC;
  v_derechos NUMERIC;
BEGIN
  v_prima := round(COALESCE(p_monto, 0) * COALESCE(p_tarifa, 0.02)
                   * CASE WHEN v_dias BETWEEN 364 AND 366 THEN 1 ELSE v_dias / 365.0 END, 2);
  v_derechos := round(v_prima * 0.08, 2);
  RETURN QUERY SELECT v_prima, v_derechos, round((v_prima + v_derechos) * 0.12, 2);
END;
$$;

DROP FUNCTION IF EXISTS public.emitir_fianza_d6(UUID, BIGINT, DATE, DATE, NUMERIC, NUMERIC, NUMERIC, TEXT, DATE, TEXT);
CREATE OR REPLACE FUNCTION public.emitir_fianza_d6(
  p_solicitud_id UUID,
  p_numero_fianza BIGINT,
  p_vigencia_desde DATE,
  p_vigencia_hasta DATE,
  p_contrato_numero TEXT,
  p_contrato_fecha DATE,
  p_lote_fiso TEXT DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_sol public.solicitudes_alta%ROWTYPE;
  v_ant public.fianzas%ROWTYPE;
  v_contrato_id UUID;
  v_fianza_id UUID;
  v_monto NUMERIC(15,2);
  v_agente UUID;
  v_endoso INTEGER := 0;
  v_modo TEXT := 'NUEVA_POLIZA';
  v_exposicion NUMERIC := 0;
  v_req BOOLEAN;
  v_calc RECORD;
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

  IF v_sol.fianza_anterior_id IS NOT NULL THEN
    SELECT * INTO v_ant FROM public.fianzas WHERE id = v_sol.fianza_anterior_id FOR UPDATE;
    SELECT c.incremento INTO v_modo FROM public.condiciones_marca_d6 c
    JOIN public.grupo_beneficiario_rel r ON r.grupo_id = c.grupo_id
    WHERE r.beneficiario_id = v_sol.beneficiario_id LIMIT 1;
    v_modo := COALESCE(v_modo, 'NUEVA_POLIZA');
  END IF;

  IF v_sol.tipo_solicitud = 'INCREMENTO' AND v_modo = 'MODIFICACION' AND v_ant.id IS NOT NULL THEN
    IF p_numero_fianza <> v_ant.fianza THEN
      RAISE EXCEPTION 'Esta marca trabaja los incrementos como modificacion: use el numero de la fianza %', v_ant.fianza;
    END IF;
    SELECT max(endoso) + 1 INTO v_endoso FROM public.fianzas WHERE fianza = v_ant.fianza;
  ELSIF EXISTS (SELECT 1 FROM public.fianzas WHERE fianza = p_numero_fianza) THEN
    RAISE EXCEPTION 'La fianza % ya existe', p_numero_fianza;
  END IF;
  IF NULLIF(btrim(COALESCE(p_contrato_numero, '')), '') IS NULL OR p_contrato_fecha IS NULL THEN
    RAISE EXCEPTION 'Indique el numero y la fecha de la escritura del contrato de consignacion';
  END IF;
  IF p_vigencia_desde IS NULL OR p_vigencia_hasta IS NULL OR p_vigencia_hasta <= p_vigencia_desde THEN
    RAISE EXCEPTION 'Revise las fechas de vigencia';
  END IF;

  v_monto := COALESCE(v_sol.monto_aprobado, v_sol.monto_solicitado);
  SELECT * INTO v_calc FROM public.d6_calcular_prima(v_monto, public.d6_tarifa_beneficiario(v_sol.beneficiario_id),
                                                     p_vigencia_desde, p_vigencia_hasta);
  SELECT id INTO v_agente FROM public.agentes WHERE numero_agente = 0 AND indice_agente = 0 LIMIT 1;

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

  SELECT COALESCE(sum(monto_afianzado), 0) INTO v_exposicion FROM public.fianzas
  WHERE cliente_id = v_sol.cliente_id
    AND operational_status IN ('VIGENTE', 'POR_RENOVAR')
    AND vigencia_hasta >= CURRENT_DATE
    AND (v_ant.id IS NULL OR fianza <> v_ant.fianza);
  v_req := v_monto > 300000 OR v_monto + v_exposicion > 300000 OR v_sol.requiere_documento_accesorio;

  INSERT INTO public.fianzas (
    fianza, endoso, cliente_id, beneficiario_id, agente_id, fecha_emision, vigencia_desde, vigencia_hasta,
    cod_estado_poliza, status_raw, status, operational_status,
    monto_afianzado, prima, derechos, iva, prima_anual, montos_fuente, contrato_id, contrato_numero, contrato_fecha,
    contrato_valor, tema_de_fianza, lote_fiso, reemplaza_fianza_id,
    requiere_accesorio, accesorio_estado, entrega_estado
  ) VALUES (
    p_numero_fianza, v_endoso, v_sol.cliente_id, v_sol.beneficiario_id, COALESCE(v_sol.agente_id, v_agente),
    CURRENT_DATE, p_vigencia_desde, p_vigencia_hasta, 'EN', 'V', 'VIGENTE', 'VIGENTE',
    v_monto, v_calc.prima, v_calc.derechos, v_calc.iva, v_calc.prima, 'APP_PROVISIONAL',
    v_contrato_id, btrim(p_contrato_numero), p_contrato_fecha, v_monto, v_sol.tema_de_fianza,
    NULLIF(btrim(COALESCE(p_lote_fiso, '')), ''), v_ant.id,
    v_req, CASE WHEN v_req THEN 'PENDIENTE' ELSE 'NO_APLICA' END, 'PENDIENTE'
  ) RETURNING id INTO v_fianza_id;

  -- Endoso de aumento como modificacion: la anterior queda reemplazada en el acto.
  -- Como poliza nueva: la anterior sigue activa hasta que se aplique el pago de la nueva
  -- (procedimiento v01). Lo hace d6_anular_reemplazada al registrar el pago.
  IF v_ant.id IS NOT NULL AND v_endoso > 0 THEN
    UPDATE public.fianzas SET operational_status = 'REEMPLAZADA_POR_ENDOSO'
    WHERE fianza = v_ant.fianza AND id <> v_fianza_id;
  END IF;

  UPDATE public.solicitudes_alta SET
    estado_operativo = 'EMITIDA', estado = 'APROBADA', contrato_id = v_contrato_id,
    contrato_numero = btrim(p_contrato_numero), contrato_fecha = p_contrato_fecha, contrato_valor = v_monto,
    vigencia_desde = p_vigencia_desde, vigencia_hasta = p_vigencia_hasta,
    emitida_en = now(), revisado_por = auth.uid(), requiere_documento_accesorio = v_req
  WHERE id = p_solicitud_id;
  INSERT INTO public.solicitud_revisiones (solicitud_alta_id, estado_anterior, estado_nuevo, comentario, monto_aprobado, creado_por)
  VALUES (p_solicitud_id, v_sol.estado_operativo, 'EMITIDA',
    'Fianza ' || p_numero_fianza || CASE WHEN v_endoso > 0 THEN ' modificada (endoso ' || v_endoso || ')' ELSE ' emitida' END,
    v_monto, auth.uid());
  RETURN v_fianza_id;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.emitir_fianza_d6(UUID, BIGINT, DATE, DATE, TEXT, DATE, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.emitir_fianza_d6(UUID, BIGINT, DATE, DATE, TEXT, DATE, TEXT) TO authenticated;

-- Endoso de aumento como poliza nueva: cuando se aplica el pago de la nueva, la anterior
-- pasa a anularse al cierre del mes.
CREATE OR REPLACE FUNCTION public.d6_anular_reemplazada()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NEW.reemplaza_fianza_id IS NOT NULL AND OLD.pago_confirmado_at IS NULL AND NEW.pago_confirmado_at IS NOT NULL THEN
    UPDATE public.fianzas SET operational_status = 'PENDIENTE_ANULACION',
      fecha_cancelacion = public.d6_fin_de_mes(CURRENT_DATE)
    WHERE id = NEW.reemplaza_fianza_id AND operational_status IN ('VIGENTE', 'POR_RENOVAR');
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_anular_reemplazada ON public.fianzas;
CREATE TRIGGER trg_anular_reemplazada AFTER UPDATE OF pago_confirmado_at ON public.fianzas
  FOR EACH ROW EXECUTE FUNCTION public.d6_anular_reemplazada();

-- ============================================================================
-- 5. Dinero: cada paso en su area (procedimiento v01)
--    Comercializacion genera y envia el estado de cuenta (039). Cobros registra el pago y el lote.
--    Contabilidad concilia contra el banco.
-- ============================================================================
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
  IF NOT public.has_d6_role(ARRAY['admin', 'cobros']::public.d6_role[]) THEN
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
  IF NOT public.has_d6_role(ARRAY['admin', 'contabilidad']::public.d6_role[]) THEN
    RAISE EXCEPTION 'Solo Contabilidad concilia pagos contra el banco';
  END IF;
  SELECT * INTO v_p FROM public.pagos WHERE id = p_pago_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pago no encontrado'; END IF;
  IF v_p.estado <> 'PENDIENTE' THEN RAISE EXCEPTION 'El pago ya fue conciliado o rechazado'; END IF;
  -- Quien registra el pago no lo concilia.
  IF v_p.registrado_por = auth.uid() AND NOT public.has_d6_role(ARRAY['admin']::public.d6_role[]) THEN
    RAISE EXCEPTION 'Usted registro este pago: lo concilia otra persona';
  END IF;
  IF p_monto_recibido IS NOT NULL AND p_monto_recibido < 0 THEN
    RAISE EXCEPTION 'El monto recibido no puede ser negativo';
  END IF;

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
