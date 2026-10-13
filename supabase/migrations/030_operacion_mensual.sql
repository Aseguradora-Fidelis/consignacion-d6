-- 030: lo que pidio la reunion del 2026-10-06.
-- Condiciones por marca, bajas con fecha de cancelacion futura, lista de anulaciones para Cobros,
-- control de entrega con documento accesorio, incrementos, posibles vinculados, referencia para
-- decidir, cuadre con FISO y bitacora de comunicaciones por afianzado.

-- ============================================================================
-- Utilidades

CREATE OR REPLACE FUNCTION public.d6_normalizar(p TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT NULLIF(regexp_replace(
    translate(upper(COALESCE(p, '')), 'ÁÉÍÓÚÜÑ', 'AEIOUUN'), '[^A-Z0-9]', '', 'g'), '')
$$;

CREATE OR REPLACE FUNCTION public.d6_telefono(p TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN length(regexp_replace(COALESCE(p, ''), '\D', '', 'g')) >= 8
    THEN right(regexp_replace(p, '\D', '', 'g'), 8) END
$$;

CREATE OR REPLACE FUNCTION public.d6_fin_de_mes(p DATE)
RETURNS DATE LANGUAGE sql IMMUTABLE AS $$
  SELECT (date_trunc('month', p) + INTERVAL '1 month - 1 day')::date
$$;

-- ============================================================================
-- Condiciones por marca: el anexo del procedimiento, editable sin codigo.

CREATE TABLE IF NOT EXISTS public.condiciones_marca_d6 (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  grupo_id UUID NOT NULL UNIQUE REFERENCES public.grupos_beneficiarios(id) ON DELETE CASCADE,
  plazo_contrato_anios INTEGER NOT NULL DEFAULT 5 CHECK (plazo_contrato_anios BETWEEN 1 AND 10),
  vigencia_fianza_meses INTEGER NOT NULL DEFAULT 12 CHECK (vigencia_fianza_meses BETWEEN 1 AND 60),
  forma_pago TEXT NOT NULL DEFAULT 'MES_SIGUIENTE'
    CHECK (forma_pago IN ('MES_SIGUIENTE', 'ANTICIPADO')),
  cuotas INTEGER NOT NULL DEFAULT 1 CHECK (cuotas BETWEEN 1 AND 24),
  medio_pago TEXT,
  entrega_condicionada_pago BOOLEAN NOT NULL DEFAULT false,
  incremento TEXT NOT NULL DEFAULT 'NUEVA_POLIZA' CHECK (incremento IN ('NUEVA_POLIZA', 'MODIFICACION')),
  monto_sugerido NUMERIC(15,2),
  verificar_contrato_autorizado BOOLEAN NOT NULL DEFAULT true,
  notas TEXT, -- la marca tambien la ve
  actualizado_por UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.condiciones_marca_d6 ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "condiciones: personal y la propia marca ven" ON public.condiciones_marca_d6;
CREATE POLICY "condiciones: personal y la propia marca ven" ON public.condiciones_marca_d6 FOR SELECT
  USING (public.d6_es_personal_aseguradora()
         OR grupo_id IN (SELECT ug.grupo_id FROM public.user_grupos ug WHERE ug.user_id = auth.uid()));
DROP POLICY IF EXISTS "condiciones: suscripcion edita" ON public.condiciones_marca_d6;
CREATE POLICY "condiciones: suscripcion edita" ON public.condiciones_marca_d6 FOR ALL
  USING (public.has_d6_role(ARRAY['admin', 'suscripcion']::public.d6_role[]))
  WITH CHECK (public.has_d6_role(ARRAY['admin', 'suscripcion']::public.d6_role[]));
DROP TRIGGER IF EXISTS trg_condiciones_marca_updated_at ON public.condiciones_marca_d6;
CREATE TRIGGER trg_condiciones_marca_updated_at BEFORE UPDATE ON public.condiciones_marca_d6
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
DROP TRIGGER IF EXISTS trg_condiciones_marca_audit ON public.condiciones_marca_d6;
CREATE TRIGGER trg_condiciones_marca_audit AFTER INSERT OR UPDATE OR DELETE ON public.condiciones_marca_d6
  FOR EACH ROW EXECUTE FUNCTION public.log_audit_changes();

INSERT INTO public.condiciones_marca_d6 (grupo_id, plazo_contrato_anios, vigencia_fianza_meses, forma_pago, cuotas,
  medio_pago, entrega_condicionada_pago, incremento, notas)
SELECT g.id, 5, 12,
  CASE WHEN g.codigo = 'GRP-UNIDADES-MOVILES' THEN 'ANTICIPADO' ELSE 'MES_SIGUIENTE' END,
  CASE WHEN g.codigo = 'GRP-UNIDADES-MOVILES' THEN 10 ELSE 1 END,
  CASE WHEN g.codigo = 'GRP-UNIDADES-MOVILES' THEN 'Tarjeta de crédito' END,
  g.codigo = 'GRP-UNIDADES-MOVILES',
  'NUEVA_POLIZA',
  CASE g.codigo
    WHEN 'GRP-CENTRAL-MOTOPREMIUM' THEN 'Contrato a 5 años con fianza que se renueva cada año. La cuota vence el último día del mes siguiente.'
    WHEN 'GRP-UNIDADES-MOVILES' THEN 'Pago anticipado por toda la vigencia, hasta 10 cuotas con tarjeta. La fianza se entrega pagada.'
  END
FROM public.grupos_beneficiarios g
WHERE g.codigo <> 'GRP-GENERAL'
ON CONFLICT (grupo_id) DO NOTHING;

-- ============================================================================
-- Incrementos y renovaciones: la solicitud apunta a la fianza que cambia.

ALTER TABLE public.solicitudes_alta
  ADD COLUMN IF NOT EXISTS tipo_solicitud TEXT NOT NULL DEFAULT 'NUEVA',
  ADD COLUMN IF NOT EXISTS fianza_anterior_id UUID REFERENCES public.fianzas(id) ON DELETE SET NULL;
ALTER TABLE public.solicitudes_alta DROP CONSTRAINT IF EXISTS solicitudes_alta_tipo_solicitud_check;
ALTER TABLE public.solicitudes_alta ADD CONSTRAINT solicitudes_alta_tipo_solicitud_check
  CHECK (tipo_solicitud IN ('NUEVA', 'INCREMENTO', 'RENOVACION'));

CREATE OR REPLACE FUNCTION public.d6_vincular_fianza_anterior(p_solicitud_id UUID, p_fianza_id UUID, p_tipo TEXT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_sol public.solicitudes_alta%ROWTYPE;
  v_f public.fianzas%ROWTYPE;
BEGIN
  IF p_tipo NOT IN ('INCREMENTO', 'RENOVACION') THEN RAISE EXCEPTION 'Tipo de solicitud no valido'; END IF;
  SELECT * INTO v_sol FROM public.solicitudes_alta WHERE id = p_solicitud_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Solicitud no encontrada'; END IF;
  SELECT * INTO v_f FROM public.fianzas WHERE id = p_fianza_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Fianza no encontrada'; END IF;
  IF NOT public.has_d6_role(ARRAY['admin', 'comercial', 'suscripcion']::public.d6_role[])
     AND NOT (public.d6_beneficiario_es_mio(v_f.beneficiario_id) AND v_sol.creado_por = auth.uid()) THEN
    RAISE EXCEPTION 'No puede vincular esta fianza';
  END IF;
  IF v_sol.estado_operativo IN ('EMITIDA', 'NO_ELEGIBLE', 'CANCELADA') THEN
    RAISE EXCEPTION 'La solicitud ya esta cerrada';
  END IF;
  UPDATE public.solicitudes_alta SET
    tipo_solicitud = p_tipo, fianza_anterior_id = p_fianza_id, cliente_id = v_f.cliente_id
  WHERE id = p_solicitud_id;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.d6_vincular_fianza_anterior(UUID, UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.d6_vincular_fianza_anterior(UUID, UUID, TEXT) TO authenticated;

-- ============================================================================
-- Entrega de la fianza y documento accesorio.
-- Lo cargado desde FISO ya se entrego. Lo que emite la app queda pendiente de entrega y,
-- si pasa de Q300,000 sumando marcas, no se entrega sin el accesorio firmado de vuelta
-- o sin una autorizacion escrita de Suscripcion.

ALTER TABLE public.fianzas
  ADD COLUMN IF NOT EXISTS requiere_accesorio BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS accesorio_estado TEXT NOT NULL DEFAULT 'NO_APLICA',
  ADD COLUMN IF NOT EXISTS accesorio_nota TEXT,
  ADD COLUMN IF NOT EXISTS accesorio_por UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS accesorio_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS entrega_estado TEXT NOT NULL DEFAULT 'ENTREGADA',
  ADD COLUMN IF NOT EXISTS entregada_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS entregada_por UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS entregada_a TEXT,
  ADD COLUMN IF NOT EXISTS entrega_nota TEXT;
ALTER TABLE public.fianzas DROP CONSTRAINT IF EXISTS fianzas_accesorio_estado_check;
ALTER TABLE public.fianzas ADD CONSTRAINT fianzas_accesorio_estado_check
  CHECK (accesorio_estado IN ('NO_APLICA', 'PENDIENTE', 'ENVIADO', 'RECIBIDO', 'DISPENSADO'));
ALTER TABLE public.fianzas DROP CONSTRAINT IF EXISTS fianzas_entrega_estado_check;
ALTER TABLE public.fianzas ADD CONSTRAINT fianzas_entrega_estado_check
  CHECK (entrega_estado IN ('PENDIENTE', 'ENTREGADA'));

CREATE OR REPLACE FUNCTION public.d6_registrar_accesorio(p_fianza_id UUID, p_estado TEXT, p_nota TEXT DEFAULT NULL)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_f public.fianzas%ROWTYPE;
BEGIN
  IF p_estado NOT IN ('PENDIENTE', 'ENVIADO', 'RECIBIDO', 'DISPENSADO') THEN
    RAISE EXCEPTION 'Estado de accesorio no valido';
  END IF;
  IF p_estado = 'DISPENSADO' THEN
    IF NOT public.has_d6_role(ARRAY['admin', 'suscripcion']::public.d6_role[]) THEN
      RAISE EXCEPTION 'Solo Suscripcion autoriza entregar sin documento accesorio';
    END IF;
    IF NULLIF(btrim(COALESCE(p_nota, '')), '') IS NULL THEN
      RAISE EXCEPTION 'Explique por que se autoriza la entrega sin documento accesorio';
    END IF;
  ELSIF NOT public.has_d6_role(ARRAY['admin', 'suscripcion', 'comercial']::public.d6_role[]) THEN
    RAISE EXCEPTION 'No tiene permiso para registrar el documento accesorio';
  END IF;
  SELECT * INTO v_f FROM public.fianzas WHERE id = p_fianza_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Fianza no encontrada'; END IF;
  UPDATE public.fianzas SET
    requiere_accesorio = true, accesorio_estado = p_estado,
    accesorio_nota = NULLIF(btrim(COALESCE(p_nota, '')), ''), accesorio_por = auth.uid(), accesorio_at = now()
  WHERE id = p_fianza_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.d6_registrar_entrega(p_fianza_id UUID, p_entregada_a TEXT, p_nota TEXT DEFAULT NULL)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_f public.v_fianzas%ROWTYPE;
  v_req BOOLEAN;
  v_acc TEXT;
BEGIN
  IF NOT public.has_d6_role(ARRAY['admin', 'suscripcion', 'comercial']::public.d6_role[]) THEN
    RAISE EXCEPTION 'No tiene permiso para registrar la entrega';
  END IF;
  SELECT requiere_accesorio, accesorio_estado INTO v_req, v_acc FROM public.fianzas WHERE id = p_fianza_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Fianza no encontrada'; END IF;
  SELECT * INTO v_f FROM public.v_fianzas WHERE id = p_fianza_id;
  IF v_req AND v_acc NOT IN ('RECIBIDO', 'DISPENSADO') THEN
    RAISE EXCEPTION 'Esta fianza exige documento accesorio. Registre el accesorio firmado o pida a Suscripcion que autorice la entrega sin el.';
  END IF;
  IF v_f.entrega_pendiente_pago THEN
    RAISE EXCEPTION 'La marca entrega esta fianza solo pagada. Registre el pago antes de entregarla.';
  END IF;
  IF NULLIF(btrim(COALESCE(p_entregada_a, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Indique a quien se entrego la fianza';
  END IF;
  UPDATE public.fianzas SET
    entrega_estado = 'ENTREGADA', entregada_at = now(), entregada_por = auth.uid(),
    entregada_a = btrim(p_entregada_a), entrega_nota = NULLIF(btrim(COALESCE(p_nota, '')), '')
  WHERE id = p_fianza_id;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.d6_registrar_accesorio(UUID, TEXT, TEXT) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.d6_registrar_entrega(UUID, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.d6_registrar_accesorio(UUID, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.d6_registrar_entrega(UUID, TEXT, TEXT) TO authenticated;

-- Emision: deja la fianza pendiente de entrega, marca el accesorio y aplica el incremento
-- segun la condicion de la marca (fianza nueva que reemplaza a la anterior, o modificacion
-- de la misma fianza como endoso).
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
  v_ant public.fianzas%ROWTYPE;
  v_contrato_id UUID;
  v_fianza_id UUID;
  v_monto NUMERIC(15,2);
  v_agente UUID;
  v_endoso INTEGER := 0;
  v_modo TEXT := 'NUEVA_POLIZA';
  v_exposicion NUMERIC := 0;
  v_req BOOLEAN;
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
  IF COALESCE(p_prima, 0) <= 0 THEN RAISE EXCEPTION 'La prima debe ser mayor que cero'; END IF;

  v_monto := COALESCE(v_sol.monto_aprobado, v_sol.monto_solicitado);
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

  -- Exposicion de las demas fianzas activas del afianzado, sin contar la que se reemplaza.
  SELECT COALESCE(sum(monto_afianzado), 0) INTO v_exposicion FROM public.fianzas
  WHERE cliente_id = v_sol.cliente_id
    AND operational_status IN ('VIGENTE', 'POR_RENOVAR')
    AND vigencia_hasta >= CURRENT_DATE
    AND (v_ant.id IS NULL OR fianza <> v_ant.fianza);
  v_req := v_monto > 300000 OR v_monto + v_exposicion > 300000 OR v_sol.requiere_documento_accesorio;

  INSERT INTO public.fianzas (
    fianza, endoso, cliente_id, beneficiario_id, agente_id, fecha_emision, vigencia_desde, vigencia_hasta,
    cod_estado_poliza, status_raw, status, operational_status,
    monto_afianzado, prima, derechos, iva, prima_anual, contrato_id, contrato_numero, contrato_fecha,
    contrato_valor, tema_de_fianza, lote_fiso, reemplaza_fianza_id,
    requiere_accesorio, accesorio_estado, entrega_estado
  ) VALUES (
    p_numero_fianza, v_endoso, v_sol.cliente_id, v_sol.beneficiario_id, COALESCE(v_sol.agente_id, v_agente),
    CURRENT_DATE, p_vigencia_desde, p_vigencia_hasta, 'EN', 'V', 'VIGENTE', 'VIGENTE',
    v_monto, round(p_prima, 2), round(COALESCE(p_derechos, 0), 2), round(COALESCE(p_iva, 0), 2), round(p_prima, 2),
    v_contrato_id, btrim(p_contrato_numero), p_contrato_fecha, v_monto, v_sol.tema_de_fianza,
    NULLIF(btrim(COALESCE(p_lote_fiso, '')), ''), v_ant.id,
    v_req, CASE WHEN v_req THEN 'PENDIENTE' ELSE 'NO_APLICA' END, 'PENDIENTE'
  ) RETURNING id INTO v_fianza_id;

  IF v_ant.id IS NOT NULL THEN
    IF v_endoso > 0 THEN
      UPDATE public.fianzas SET operational_status = 'REEMPLAZADA_POR_ENDOSO'
      WHERE fianza = v_ant.fianza AND id <> v_fianza_id;
    ELSIF v_ant.operational_status IN ('VIGENTE', 'POR_RENOVAR') THEN
      -- La fianza anterior se anula al cierre del mes, cuando la nueva ya esta cobrada.
      UPDATE public.fianzas SET operational_status = 'PENDIENTE_ANULACION',
        fecha_cancelacion = public.d6_fin_de_mes(CURRENT_DATE)
      WHERE id = v_ant.id;
    END IF;
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

-- ============================================================================
-- Bajas con fecha de cancelacion futura y lista de anulaciones para Cobros.

ALTER TABLE public.solicitudes_baja
  ADD COLUMN IF NOT EXISTS fecha_efectiva DATE,
  ADD COLUMN IF NOT EXISTS enviada_cobros_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS enviada_cobros_por UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL;
UPDATE public.solicitudes_baja SET fecha_efectiva = public.d6_fin_de_mes(created_at::date) WHERE fecha_efectiva IS NULL;

DROP FUNCTION IF EXISTS public.d6_solicitar_baja(UUID, public.tipo_baja, TEXT);
CREATE OR REPLACE FUNCTION public.d6_solicitar_baja(
  p_fianza_id UUID, p_tipo public.tipo_baja, p_motivo TEXT, p_fecha_efectiva DATE DEFAULT NULL
) RETURNS TABLE(baja_id UUID, numero_solicitud TEXT, fecha_efectiva DATE)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_f public.fianzas%ROWTYPE;
  v_id UUID;
  v_numero TEXT;
  v_fecha DATE;
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
  IF EXISTS (SELECT 1 FROM public.solicitudes_baja sb WHERE sb.fianza_id = p_fianza_id AND sb.estado = 'PENDIENTE_REVISION') THEN
    RAISE EXCEPTION 'Ya hay una solicitud de baja pendiente para esta poliza';
  END IF;
  IF NULLIF(btrim(COALESCE(p_motivo, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Describa el motivo de la baja';
  END IF;
  -- La baja surte efecto al cierre del mes elegido; nunca antes del cierre del mes en curso.
  v_fecha := public.d6_fin_de_mes(GREATEST(COALESCE(p_fecha_efectiva, CURRENT_DATE), CURRENT_DATE));
  IF v_fecha > CURRENT_DATE + 400 THEN RAISE EXCEPTION 'La fecha de cancelacion no puede pasar de un ano'; END IF;
  v_numero := 'BAJ-' || to_char(now(), 'YYYY') || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
  INSERT INTO public.solicitudes_baja (numero_solicitud, fianza_id, tipo_baja, motivo, estado, solicitado_por, fecha_efectiva)
  VALUES (v_numero, p_fianza_id, COALESCE(p_tipo, 'OTRO'), btrim(p_motivo), 'PENDIENTE_REVISION', auth.uid(), v_fecha)
  RETURNING id INTO v_id;
  RETURN QUERY SELECT v_id, v_numero, v_fecha;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.d6_solicitar_baja(UUID, public.tipo_baja, TEXT, DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.d6_solicitar_baja(UUID, public.tipo_baja, TEXT, DATE) TO authenticated;

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

  v_efectiva := COALESCE(v_b.fecha_efectiva, public.d6_fin_de_mes(v_b.created_at::date));
  UPDATE public.solicitudes_baja SET estado = 'APROBADA', observaciones = p_comentario, procesado_por = auth.uid(),
    fecha_efectiva = v_efectiva
  WHERE id = p_baja_id;
  UPDATE public.fianzas SET operational_status = 'PENDIENTE_ANULACION', fecha_cancelacion = v_efectiva
  WHERE id = v_b.fianza_id;
  RETURN v_efectiva;
END;
$$;

-- Lista de anulaciones de un mes: lo que se le manda a Cobros al cierre.
CREATE OR REPLACE FUNCTION public.d6_anulaciones_mes(p_periodo DATE)
RETURNS TABLE(
  baja_id UUID, numero_solicitud TEXT, fianza_id UUID, fianza BIGINT, endoso INTEGER,
  afianzado TEXT, marca TEXT, monto_afianzado NUMERIC, prima NUMERIC, fecha_efectiva DATE,
  motivo TEXT, tipo_baja public.tipo_baja, estado_poliza TEXT, enviada_cobros_at TIMESTAMPTZ
)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public
AS $$
  SELECT b.id, b.numero_solicitud, f.id, f.fianza, f.endoso, f.cliente_nombre, f.marca_nombre,
         f.monto_original, f.prima, b.fecha_efectiva, b.motivo, b.tipo_baja, f.estado, b.enviada_cobros_at
  FROM public.solicitudes_baja b
  JOIN public.v_fianzas f ON f.id = b.fianza_id
  WHERE b.estado = 'APROBADA'
    AND b.fecha_efectiva BETWEEN date_trunc('month', p_periodo)::date AND public.d6_fin_de_mes(p_periodo)
  ORDER BY f.marca_nombre, f.fianza
$$;
REVOKE EXECUTE ON FUNCTION public.d6_anulaciones_mes(DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.d6_anulaciones_mes(DATE) TO authenticated;

CREATE OR REPLACE FUNCTION public.d6_marcar_anulaciones_enviadas(p_periodo DATE)
RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_n INTEGER;
BEGIN
  IF NOT public.has_d6_role(ARRAY['admin', 'suscripcion']::public.d6_role[]) THEN
    RAISE EXCEPTION 'Solo Suscripcion envia la lista de anulaciones';
  END IF;
  UPDATE public.solicitudes_baja SET enviada_cobros_at = now(), enviada_cobros_por = auth.uid()
  WHERE estado = 'APROBADA' AND enviada_cobros_at IS NULL
    AND fecha_efectiva BETWEEN date_trunc('month', p_periodo)::date AND public.d6_fin_de_mes(p_periodo);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.d6_marcar_anulaciones_enviadas(DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.d6_marcar_anulaciones_enviadas(DATE) TO authenticated;

-- ============================================================================
-- Cartera: movimiento del mes con los colores que ya usa el equipo, entrega y accesorio.
-- Verde: nueva este mes o el anterior. Amarillo: se cancela en una fecha futura. Rojo: cancelada
-- en los ultimos dos meses.

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
  f.pago_confirmado_at,
  (COALESCE(rc.entrega_condicionada_pago, false) AND f.pago_confirmado_at IS NULL
     AND f.operational_status = 'VIGENTE') AS entrega_pendiente_pago,
  f.created_at, f.updated_at,
  CASE
    WHEN f.operational_status = 'PENDIENTE_ANULACION' THEN 'CANCELA'
    WHEN (f.operational_status IN ('CANCELADA', 'ANULADA') OR f.status_raw = 'C')
         AND COALESCE(f.fecha_cancelacion, f.fecha_anulacion) >= (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date
      THEN 'CANCELADA'
    WHEN f.fecha_emision >= (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date
         AND f.operational_status IN ('VIGENTE', 'POR_RENOVAR') THEN 'NUEVA'
  END AS movimiento,
  f.requiere_accesorio, f.accesorio_estado, f.accesorio_nota, f.accesorio_at,
  f.entrega_estado, f.entregada_at, f.entregada_a, f.entrega_nota,
  f.reemplaza_fianza_id
FROM public.fianzas f
JOIN public.clientes c ON c.id = f.cliente_id
JOIN public.beneficiarios b ON b.id = f.beneficiario_id
LEFT JOIN LATERAL (
  SELECT gb.id, gb.nombre, gb.codigo_regla_cobro FROM public.grupo_beneficiario_rel r
  JOIN public.grupos_beneficiarios gb ON gb.id = r.grupo_id
  WHERE r.beneficiario_id = b.id AND gb.codigo <> 'GRP-GENERAL'
  ORDER BY gb.codigo LIMIT 1
) g ON true
LEFT JOIN public.reglas_cobro_d6 rc ON rc.codigo_marca = g.codigo_regla_cobro
WHERE f.operational_status <> 'REEMPLAZADA_POR_ENDOSO';
GRANT SELECT ON public.v_fianzas TO authenticated;
REVOKE ALL ON public.v_fianzas FROM anon;

-- Lo que esta por entregarse o tiene el accesorio afuera.
CREATE OR REPLACE VIEW public.v_control_entregas
WITH (security_invoker = true)
AS
SELECT f.id, f.fianza, f.endoso, f.cliente_id, f.cliente_nombre, f.marca_nombre, f.monto_original,
       f.fecha_emision, f.requiere_accesorio, f.accesorio_estado, f.accesorio_at, f.accesorio_nota,
       f.entrega_estado, f.entrega_pendiente_pago,
       CASE
         WHEN f.requiere_accesorio AND f.accesorio_estado IN ('PENDIENTE', 'ENVIADO') THEN 'BLOQUEADA_ACCESORIO'
         WHEN f.entrega_pendiente_pago THEN 'BLOQUEADA_PAGO'
         WHEN f.entrega_estado = 'PENDIENTE' THEN 'LISTA'
       END AS situacion,
       (CURRENT_DATE - COALESCE(f.fecha_emision, f.created_at::date)) AS dias
FROM public.v_fianzas f
WHERE f.estado NOT IN ('CANCELADA', 'ANULADA')
  AND (f.entrega_estado = 'PENDIENTE'
       OR (f.requiere_accesorio AND f.accesorio_estado IN ('PENDIENTE', 'ENVIADO')));
GRANT SELECT ON public.v_control_entregas TO authenticated;
REVOKE ALL ON public.v_control_entregas FROM anon;

-- Distribuidores de una marca: un renglon por afianzado y marca.
CREATE OR REPLACE VIEW public.v_distribuidores
WITH (security_invoker = true)
AS
SELECT f.cliente_id, f.cliente_nombre, f.cliente_codigo, f.marca_id, f.marca_nombre,
       count(*) FILTER (WHERE f.estado IN ('VIGENTE', 'POR_RENOVAR', 'EN_BAJA')) AS fianzas_activas,
       COALESCE(sum(f.monto_original) FILTER (WHERE f.estado IN ('VIGENTE', 'POR_RENOVAR', 'EN_BAJA')), 0) AS monto_activo,
       min(f.vigencia_hasta) FILTER (WHERE f.estado IN ('VIGENTE', 'POR_RENOVAR')) AS proximo_vencimiento,
       count(*) FILTER (WHERE f.estado = 'POR_RENOVAR') AS por_renovar,
       count(*) FILTER (WHERE f.estado = 'EN_BAJA') AS en_baja,
       count(*) AS fianzas_historicas,
       min(f.fecha_emision) AS cliente_desde,
       max(f.fecha_emision) AS ultima_emision
FROM public.v_fianzas f
GROUP BY f.cliente_id, f.cliente_nombre, f.cliente_codigo, f.marca_id, f.marca_nombre;
GRANT SELECT ON public.v_distribuidores TO authenticated;
REVOKE ALL ON public.v_distribuidores FROM anon;

-- ============================================================================
-- Senas de cada afianzado para detectar vinculados (misma direccion, telefono o patente,
-- o los mismos dos apellidos en el mismo municipio). Se cargan desde Oracle.

ALTER TABLE public.perfil_afianzado_oracle
  ADD COLUMN IF NOT EXISTS direccion TEXT,
  ADD COLUMN IF NOT EXISTS municipio TEXT,
  ADD COLUMN IF NOT EXISTS telefonos TEXT[] NOT NULL DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS patente TEXT,
  ADD COLUMN IF NOT EXISTS apellidos TEXT;

CREATE OR REPLACE FUNCTION public.d6_senas_cliente(p_cliente_id UUID)
RETURNS TABLE(direccion TEXT, telefonos TEXT[], patente TEXT, apellidos TEXT, municipio TEXT)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT public.d6_normalizar(COALESCE(p.direccion, c.direccion)),
         ARRAY(SELECT DISTINCT t FROM unnest(p.telefonos || ARRAY[public.d6_telefono(c.telefono)]) t WHERE t IS NOT NULL),
         public.d6_normalizar(p.patente), public.d6_normalizar(p.apellidos), p.municipio
  FROM public.clientes c
  LEFT JOIN public.perfil_afianzado_oracle p ON p.cliente_codigo = c.codigo_contacto
  WHERE c.id = p_cliente_id
$$;
REVOKE EXECUTE ON FUNCTION public.d6_senas_cliente(UUID) FROM PUBLIC, anon, authenticated;

-- Telefonos que comparten mas de 4 afianzados son de la marca o de una agencia: no vinculan.
CREATE OR REPLACE FUNCTION public.d6_buscar_vinculados(
  p_excluir UUID, p_direccion TEXT, p_telefonos TEXT[], p_patente TEXT, p_apellidos TEXT, p_municipio TEXT
) RETURNS TABLE(cliente_id UUID, nombre TEXT, motivo TEXT, exposicion NUMERIC, marcas TEXT)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  WITH senas AS (
    SELECT c.id, c.nombre,
           public.d6_normalizar(COALESCE(p.direccion, c.direccion)) AS dir,
           ARRAY(SELECT DISTINCT t FROM unnest(COALESCE(p.telefonos, '{}') || ARRAY[public.d6_telefono(c.telefono)]) t WHERE t IS NOT NULL) AS tels,
           public.d6_normalizar(p.patente) AS pat, public.d6_normalizar(p.apellidos) AS ape, p.municipio AS muni
    FROM public.clientes c
    LEFT JOIN public.perfil_afianzado_oracle p ON p.cliente_codigo = c.codigo_contacto
    WHERE c.id IS DISTINCT FROM p_excluir
  ),
  comunes AS (
    SELECT t FROM senas, unnest(senas.tels) t GROUP BY t HAVING count(*) > 4
  ),
  m AS (
    SELECT s.id, s.nombre, array_remove(ARRAY[
      CASE WHEN p_direccion IS NOT NULL AND length(p_direccion) > 12 AND s.dir = p_direccion THEN 'Misma dirección' END,
      CASE WHEN s.tels && COALESCE(p_telefonos, '{}')
                AND EXISTS (SELECT 1 FROM unnest(s.tels) t WHERE t = ANY(p_telefonos) AND t NOT IN (SELECT t FROM comunes))
           THEN 'Mismo teléfono' END,
      CASE WHEN p_patente IS NOT NULL AND length(p_patente) > 3 AND s.pat = p_patente THEN 'Misma patente' END,
      CASE WHEN p_apellidos IS NOT NULL AND length(p_apellidos) > 6 AND s.ape = p_apellidos
                AND p_municipio IS NOT NULL AND s.muni = p_municipio THEN 'Mismos apellidos en el mismo municipio' END
    ], NULL) AS motivos
    FROM senas s
  )
  SELECT m.id, m.nombre, array_to_string(m.motivos, ', '),
         COALESCE((SELECT sum(f.monto_afianzado) FROM public.fianzas f
                   WHERE f.cliente_id = m.id AND f.operational_status IN ('VIGENTE', 'POR_RENOVAR', 'PENDIENTE_ANULACION')
                     AND f.vigencia_hasta >= CURRENT_DATE), 0),
         (SELECT string_agg(DISTINCT vf.marca_nombre, ', ') FROM public.v_fianzas vf
           WHERE vf.cliente_id = m.id AND vf.estado IN ('VIGENTE', 'POR_RENOVAR', 'EN_BAJA'))
  FROM m
  WHERE cardinality(m.motivos) > 0
  ORDER BY 4 DESC
  LIMIT 20
$$;
REVOKE EXECUTE ON FUNCTION public.d6_buscar_vinculados(UUID, TEXT, TEXT[], TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.d6_vinculados_cliente(p_cliente_id UUID)
RETURNS TABLE(cliente_id UUID, nombre TEXT, motivo TEXT, exposicion NUMERIC, marcas TEXT)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  s RECORD;
BEGIN
  IF NOT public.d6_es_personal_aseguradora() THEN RAISE EXCEPTION 'Solo el personal de Fidelis'; END IF;
  SELECT * INTO s FROM public.d6_senas_cliente(p_cliente_id);
  RETURN QUERY SELECT * FROM public.d6_buscar_vinculados(p_cliente_id, s.direccion, s.telefonos, s.patente, s.apellidos, s.municipio);
END;
$$;

-- En una solicitud nueva las senas salen del formulario IVE que lleno el afianzado.
CREATE OR REPLACE FUNCTION public.d6_vinculados_solicitud(p_solicitud_id UUID)
RETURNS TABLE(cliente_id UUID, nombre TEXT, motivo TEXT, exposicion NUMERIC, marcas TEXT)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_sol public.solicitudes_alta%ROWTYPE;
  v_d JSONB;
  s RECORD;
  v_dir TEXT;
  v_tels TEXT[];
  v_pat TEXT;
  v_ape TEXT;
BEGIN
  IF NOT public.d6_es_personal_aseguradora() THEN RAISE EXCEPTION 'Solo el personal de Fidelis'; END IF;
  SELECT * INTO v_sol FROM public.solicitudes_alta WHERE id = p_solicitud_id;
  IF NOT FOUND THEN RETURN; END IF;
  v_d := COALESCE(v_sol.ive_data, v_sol.ive_borrador, '{}'::jsonb);
  IF v_sol.cliente_id IS NOT NULL THEN
    SELECT * INTO s FROM public.d6_senas_cliente(v_sol.cliente_id);
  END IF;
  v_dir := COALESCE(public.d6_normalizar(COALESCE(v_d->>'direccion', v_d->>'direccionSede')), s.direccion);
  v_tels := ARRAY(SELECT DISTINCT t FROM unnest(ARRAY[
              public.d6_telefono(v_d->>'telefono'), public.d6_telefono(v_d->>'celular'),
              public.d6_telefono(v_d->>'telefonoEmpresa'), public.d6_telefono(v_sol.cliente_telefono_tmp)]
              || COALESCE(s.telefonos, '{}')) t WHERE t IS NOT NULL);
  v_pat := COALESCE(public.d6_normalizar(v_d->>'patenteEmpresa'), s.patente);
  v_ape := COALESCE(public.d6_normalizar(concat_ws(' ', v_d->>'primerApellido', v_d->>'segundoApellido')), s.apellidos);
  RETURN QUERY SELECT * FROM public.d6_buscar_vinculados(v_sol.cliente_id, v_dir, v_tels, v_pat, v_ape,
    COALESCE(v_d->>'municipio', s.municipio));
END;
$$;
REVOKE EXECUTE ON FUNCTION public.d6_vinculados_cliente(UUID) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.d6_vinculados_solicitud(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.d6_vinculados_cliente(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.d6_vinculados_solicitud(UUID) TO authenticated;

-- ============================================================================
-- Referencia para decidir: lo que pide contra lo que ya maneja, contra la marca y su historial.
-- Las reglas de lectura viven en src/domain/referenciaDecision.js.

CREATE OR REPLACE FUNCTION public.d6_referencia_alta(p_solicitud_id UUID)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_sol public.solicitudes_alta%ROWTYPE;
  v_grupo UUID;
  v_res JSONB;
BEGIN
  IF NOT public.d6_es_personal_aseguradora() THEN RAISE EXCEPTION 'Solo el personal de Fidelis'; END IF;
  SELECT * INTO v_sol FROM public.solicitudes_alta WHERE id = p_solicitud_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Solicitud no encontrada'; END IF;
  SELECT r.grupo_id INTO v_grupo FROM public.grupo_beneficiario_rel r
  JOIN public.grupos_beneficiarios g ON g.id = r.grupo_id
  WHERE r.beneficiario_id = v_sol.beneficiario_id AND g.codigo <> 'GRP-GENERAL' LIMIT 1;

  SELECT jsonb_build_object(
    'monto_solicitado', v_sol.monto_solicitado,
    'tipo_solicitud', v_sol.tipo_solicitud,
    'monto_anterior', (SELECT monto_afianzado FROM public.fianzas WHERE id = v_sol.fianza_anterior_id),
    'exposicion_total', COALESCE((SELECT sum(f.monto_afianzado) FROM public.fianzas f
        WHERE f.cliente_id = v_sol.cliente_id AND f.operational_status IN ('VIGENTE', 'POR_RENOVAR', 'PENDIENTE_ANULACION')
          AND f.vigencia_hasta >= CURRENT_DATE), 0),
    'exposicion_marca', COALESCE((SELECT sum(vf.monto_original) FROM public.v_fianzas vf
        WHERE vf.cliente_id = v_sol.cliente_id AND vf.marca_id = v_grupo AND vf.estado IN ('VIGENTE', 'POR_RENOVAR', 'EN_BAJA')), 0),
    'maximo_historico', (SELECT max(vf.monto_original) FROM public.v_fianzas vf WHERE vf.cliente_id = v_sol.cliente_id),
    'fianzas_historicas', (SELECT count(DISTINCT f.fianza) FROM public.fianzas f WHERE f.cliente_id = v_sol.cliente_id),
    'cliente_desde', (SELECT min(f.fecha_emision) FROM public.fianzas f WHERE f.cliente_id = v_sol.cliente_id),
    'marca', (SELECT jsonb_build_object(
        'nombre', max(vf.marca_nombre),
        'distribuidores', count(DISTINCT vf.cliente_id),
        'mediana', percentile_cont(0.5) WITHIN GROUP (ORDER BY vf.monto_original),
        'p90', percentile_cont(0.9) WITHIN GROUP (ORDER BY vf.monto_original),
        'maximo', max(vf.monto_original))
      FROM public.v_fianzas vf
      WHERE vf.marca_id = v_grupo AND vf.estado IN ('VIGENTE', 'POR_RENOVAR', 'EN_BAJA') AND vf.monto_original > 0),
    'historial_d6', (SELECT jsonb_build_object(
        'afianzados', count(*), 'con_reclamo', count(*) FILTER (WHERE p.reclamos > 0))
      FROM public.perfil_afianzado_oracle p),
    'perfil', (SELECT to_jsonb(pa) - 'cliente_id' FROM (
        SELECT p.reclamos, p.avisos, p.max_dias_atraso, p.saldo_atrasado, p.contragarantia_monto,
               p.ive_fecha_renovacion, (p.ive_fecha_renovacion < CURRENT_DATE) AS ive_vencido,
               p.otras_fianzas_vigentes, p.otras_fianzas_monto, NULL::uuid AS cliente_id
        FROM public.clientes c JOIN public.perfil_afianzado_oracle p ON p.cliente_codigo = c.codigo_contacto
        WHERE c.id = v_sol.cliente_id) pa),
    'vinculados', COALESCE((SELECT jsonb_agg(to_jsonb(v)) FROM public.d6_vinculados_solicitud(p_solicitud_id) v), '[]'::jsonb),
    'resolucion_marca_monto', v_sol.resolucion_marca_monto
  ) INTO v_res;
  RETURN v_res;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.d6_referencia_alta(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.d6_referencia_alta(UUID) TO authenticated;

-- ============================================================================
-- Cuadre con FISO: diferencias entre la cartera de la app y la ultima carga de Oracle.

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
  -- 5. La misma fianza cobrada en dos estados de cuenta del mismo periodo.
  SELECT 'COBRO_DUPLICADO', fz.fianza, fz.id, fz.cliente_id, c.nombre, NULL::text,
         'Aparece ' || count(*) || ' veces en estados de cuenta de ' || to_char(ec.periodo, 'MM/YYYY')
  FROM public.estado_cuenta_items_d6 i
  JOIN public.estados_cuenta_d6 ec ON ec.id = i.estado_cuenta_id
  JOIN public.fianzas fz ON fz.id = i.fianza_id
  JOIN public.clientes c ON c.id = fz.cliente_id
  GROUP BY fz.fianza, fz.id, fz.cliente_id, c.nombre, ec.periodo
  HAVING count(DISTINCT i.estado_cuenta_id) > 1;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.d6_cuadre_fiso() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.d6_cuadre_fiso() TO authenticated;

-- ============================================================================
-- Bitacora de comunicaciones: correos, llamadas y mensajes en un solo lugar por afianzado.

CREATE TABLE IF NOT EXISTS public.comunicaciones_d6 (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  cliente_id UUID REFERENCES public.clientes(id) ON DELETE CASCADE,
  grupo_id UUID REFERENCES public.grupos_beneficiarios(id) ON DELETE SET NULL,
  fianza_id UUID REFERENCES public.fianzas(id) ON DELETE SET NULL,
  solicitud_alta_id UUID REFERENCES public.solicitudes_alta(id) ON DELETE SET NULL,
  canal TEXT NOT NULL CHECK (canal IN ('CORREO', 'LLAMADA', 'WHATSAPP', 'REUNION', 'NOTA')),
  sentido TEXT NOT NULL DEFAULT 'INTERNA' CHECK (sentido IN ('RECIBIDA', 'ENVIADA', 'INTERNA')),
  con_quien TEXT,
  asunto TEXT NOT NULL,
  detalle TEXT,
  visible_marca BOOLEAN NOT NULL DEFAULT false,
  ocurrida_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  registrada_por UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL DEFAULT auth.uid(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (cliente_id IS NOT NULL OR grupo_id IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS idx_comunicaciones_cliente ON public.comunicaciones_d6 (cliente_id, ocurrida_at DESC);
CREATE INDEX IF NOT EXISTS idx_comunicaciones_grupo ON public.comunicaciones_d6 (grupo_id, ocurrida_at DESC);

ALTER TABLE public.comunicaciones_d6 ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "comunicaciones: personal ve" ON public.comunicaciones_d6;
CREATE POLICY "comunicaciones: personal ve" ON public.comunicaciones_d6 FOR SELECT
  USING (public.d6_es_personal_aseguradora()
         OR (visible_marca AND grupo_id IN (SELECT ug.grupo_id FROM public.user_grupos ug WHERE ug.user_id = auth.uid())));
DROP POLICY IF EXISTS "comunicaciones: personal registra" ON public.comunicaciones_d6;
CREATE POLICY "comunicaciones: personal registra" ON public.comunicaciones_d6 FOR INSERT
  WITH CHECK (public.has_d6_role(ARRAY['admin', 'suscripcion', 'comercial', 'coordinacion_comercial', 'cobros', 'contabilidad']::public.d6_role[])
              AND registrada_por = auth.uid());
DROP POLICY IF EXISTS "comunicaciones: admin borra" ON public.comunicaciones_d6;
CREATE POLICY "comunicaciones: admin borra" ON public.comunicaciones_d6 FOR DELETE
  USING (public.has_d6_role(ARRAY['admin']::public.d6_role[]));
DROP TRIGGER IF EXISTS trg_comunicaciones_audit ON public.comunicaciones_d6;
CREATE TRIGGER trg_comunicaciones_audit AFTER INSERT OR UPDATE OR DELETE ON public.comunicaciones_d6
  FOR EACH ROW EXECUTE FUNCTION public.log_audit_changes();

-- Historial del afianzado: lo que se hablo y lo que paso, en orden.
CREATE OR REPLACE FUNCTION public.d6_historial_afianzado(p_cliente_id UUID)
RETURNS TABLE(ocurrido_at TIMESTAMPTZ, tipo TEXT, titulo TEXT, detalle TEXT, enlace TEXT, autor TEXT)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NOT public.d6_es_personal_aseguradora() THEN RAISE EXCEPTION 'Solo el personal de Fidelis'; END IF;
  RETURN QUERY
  SELECT * FROM (
    SELECT c.ocurrida_at, 'COMUNICACION:' || c.canal,
           c.asunto || CASE WHEN c.con_quien IS NOT NULL THEN ' · ' || c.con_quien ELSE '' END,
           c.detalle, NULL::text, u.full_name
    FROM public.comunicaciones_d6 c LEFT JOIN public.user_profiles u ON u.id = c.registrada_por
    WHERE c.cliente_id = p_cliente_id
    UNION ALL
    SELECT r.created_at, 'ALTA', 'Expediente ' || sa.numero_solicitud || ': ' || replace(r.estado_nuevo::text, '_', ' '),
           r.comentario, '/altas/' || sa.id, u.full_name
    FROM public.solicitud_revisiones r
    JOIN public.solicitudes_alta sa ON sa.id = r.solicitud_alta_id
    LEFT JOIN public.user_profiles u ON u.id = r.creado_por
    WHERE sa.cliente_id = p_cliente_id
    UNION ALL
    SELECT b.created_at, 'BAJA', 'Baja de la fianza ' || f.fianza || ' (' || lower(b.estado::text) || ')',
           b.motivo || COALESCE('. Efecto al ' || to_char(b.fecha_efectiva, 'DD/MM/YYYY'), ''), '/cartera/' || f.id, u.full_name
    FROM public.solicitudes_baja b
    JOIN public.fianzas f ON f.id = b.fianza_id
    LEFT JOIN public.user_profiles u ON u.id = b.solicitado_por
    WHERE f.cliente_id = p_cliente_id
    UNION ALL
    SELECT m.created_at, 'RECLAMO', 'Reclamo ' || rc.numero || ': ' || lower(replace(m.estado_nuevo::text, '_', ' ')),
           m.comentario, '/reclamos/' || rc.id, u.full_name
    FROM public.reclamo_movimientos_d6 m
    JOIN public.reclamos_d6 rc ON rc.id = m.reclamo_id
    LEFT JOIN public.user_profiles u ON u.id = m.creado_por
    WHERE rc.cliente_id = p_cliente_id
    UNION ALL
    SELECT f.fecha_emision::timestamp AT TIME ZONE 'America/Guatemala', 'EMISION', 'Fianza ' || f.fianza || CASE WHEN f.endoso > 0 THEN ' endoso ' || f.endoso ELSE '' END,
           'Monto Q' || to_char(f.monto_afianzado, 'FM999,999,990.00'), '/cartera/' || f.id, NULL::text
    FROM public.fianzas f
    WHERE f.cliente_id = p_cliente_id AND f.fecha_emision IS NOT NULL
  ) h
  ORDER BY 1 DESC
  LIMIT 200;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.d6_historial_afianzado(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.d6_historial_afianzado(UUID) TO authenticated;

-- ============================================================================
-- Portal: si el afianzado ya lleno el formulario en una solicitud anterior, se le precarga.

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
  IF v_sol.estado_operativo NOT IN ('IVE_PENDIENTE', 'INFORMACION_COMPLEMENTARIA') THEN
    RETURN jsonb_build_object('valido', false, 'motivo', 'CERRADO');
  END IF;
  IF v_sol.ive_borrador IS NULL AND v_sol.ive_data IS NULL AND v_sol.cliente_id IS NOT NULL THEN
    SELECT sa.ive_data INTO v_previo FROM public.solicitudes_alta sa
    WHERE sa.cliente_id = v_sol.cliente_id AND sa.id <> v_sol.id AND sa.ive_data IS NOT NULL
      AND sa.tipo_persona = v_sol.tipo_persona
    ORDER BY sa.ive_completed_at DESC NULLS LAST LIMIT 1;
  END IF;

  RETURN jsonb_build_object(
    'valido', true,
    'numero_solicitud', v_sol.numero_solicitud,
    'estado', v_sol.estado_operativo,
    'marca', (SELECT nombre FROM public.beneficiarios WHERE id = v_sol.beneficiario_id),
    'afianzado', v_sol.cliente_nombre_tmp,
    'tipo_persona', v_sol.tipo_persona,
    'tipo_solicitud', v_sol.tipo_solicitud,
    'monto_solicitado', v_sol.monto_solicitado,
    'expira', v_inv.expires_at,
    'comentario', CASE WHEN v_sol.estado_operativo = 'INFORMACION_COMPLEMENTARIA' THEN v_sol.resolucion_comentario END,
    'faltantes', v_sol.faltantes,
    'borrador', COALESCE(v_sol.ive_borrador, v_sol.ive_data, v_previo),
    'precargado', v_previo IS NOT NULL,
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

-- Los documentos de identidad son del afianzado, no de la marca.
UPDATE public.ive_requisitos_d6 SET nombre = 'DPI vigente del afianzado, ambos lados',
  ayuda = 'El de la persona que recibe las motos en consignación, no el de la marca.'
WHERE tipo_persona = 'INDIVIDUAL' AND categoria = 'DPI';
UPDATE public.ive_requisitos_d6 SET nombre = 'RTU actualizado del afianzado',
  ayuda = 'Constancia de inscripción en la SAT a nombre de quien recibe las motos.'
WHERE tipo_persona = 'INDIVIDUAL' AND categoria = 'RTU';
UPDATE public.ive_requisitos_d6 SET nombre = 'RTU actualizado de la empresa afianzada'
WHERE tipo_persona = 'JURIDICA' AND categoria = 'RTU';
UPDATE public.ive_requisitos_d6 SET nombre = 'Formulario IVE-IR-01 (persona individual)'
WHERE categoria = 'IVE_ASS_01';
UPDATE public.ive_requisitos_d6 SET nombre = 'Formulario IVE-IR-02 (persona jurídica)'
WHERE categoria = 'IVE_ASS_02';
