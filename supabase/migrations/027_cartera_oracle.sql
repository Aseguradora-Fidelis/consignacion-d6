-- Migracion 027: la cartera D-6 entra desde Oracle (o su export) al modelo de la app.
--
-- El staging (oracle_d6_staging) recibe filas con las columnas de d6-consignacion.csv,
-- fuente CARTERA_D6. d6_aplicar_cartera_oracle las pasa a clientes, beneficiarios,
-- agentes y fianzas. Reglas (AI MEMORY/db, trampas verificadas):
--   * Clave de poliza: (fianza, endoso). El export trae el ultimo endoso de cada fianza:
--     los endosos anteriores que existan en la app quedan REEMPLAZADA_POR_ENDOSO.
--   * Nombres con dobles espacios se normalizan. Codigos se comparan como texto limpio.
--   * Una cancelacion deja monto en 0: el monto original queda en contrato_valor.
--   * Lo que la app decide (lote FISO, pago confirmado, contrato) no se pisa.
-- Solo la llave de servicio puede ejecutarla: corre desde el job interno.

ALTER TABLE public.oracle_sync_runs_d6 DROP CONSTRAINT IF EXISTS oracle_sync_runs_d6_fuente_check;
ALTER TABLE public.oracle_sync_runs_d6 ADD CONSTRAINT oracle_sync_runs_d6_fuente_check
  CHECK (fuente IN ('CIE_TRASLADO_MES', 'VW_SALDO_FACTURA', 'MG_CONTACTOS_IVE', 'CARTERA_D6'));
ALTER TABLE public.oracle_sync_runs_d6 ADD COLUMN IF NOT EXISTS resumen JSONB;

CREATE OR REPLACE FUNCTION public.d6_texto_limpio(p TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE
AS $$ SELECT NULLIF(regexp_replace(btrim(COALESCE(p, '')), '\s+', ' ', 'g'), ''); $$;

CREATE OR REPLACE FUNCTION public.d6_numero(p TEXT)
RETURNS NUMERIC LANGUAGE sql IMMUTABLE
AS $$ SELECT COALESCE(NULLIF(regexp_replace(COALESCE(p, ''), '[^0-9.\-]', '', 'g'), '')::numeric, 0); $$;

CREATE OR REPLACE FUNCTION public.d6_aplicar_cartera_oracle(p_run_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_clientes_nuevos INT;
  v_beneficiarios_nuevos JSONB;
  v_insertadas INT;
  v_actualizadas INT;
  v_reemplazadas INT;
  v_sin_oracle JSONB;
  v_resumen JSONB;
BEGIN
  CREATE TEMP TABLE _c ON COMMIT DROP AS
  SELECT
    (s.payload->>'FIANZA')::bigint AS fianza,
    COALESCE(NULLIF(s.payload->>'ENDOSO', '')::int, 0) AS endoso,
    COALESCE(public.d6_texto_limpio(s.payload->>'RAMO'), 'FIA') AS ramo,
    COALESCE(public.d6_texto_limpio(s.payload->>'CLASE'), 'D-6') AS clase,
    (s.payload->>'COD_CONTACTO_CLIENTE')::int AS cliente_codigo,
    public.d6_texto_limpio(s.payload->>'NOMBRE_CLIENTE') AS cliente_nombre,
    (s.payload->>'COD_CONTACTO_BENEFICIARIO')::int AS beneficiario_codigo,
    public.d6_texto_limpio(s.payload->>'NOMBRE_BENEFICIARIO') AS beneficiario_nombre,
    COALESCE(NULLIF(s.payload->>'NUMERO_AGENTE', '')::int, 0) AS agente_numero,
    COALESCE(NULLIF(s.payload->>'INDICE_AGENTE', '')::int, 0) AS agente_indice,
    COALESCE(public.d6_texto_limpio(s.payload->>'NOMBRE_AGENTE'), 'AGENTE DIRECTO') AS agente_nombre,
    NULLIF(s.payload->>'FECHA_EMISION', '')::date AS fecha_emision,
    NULLIF(s.payload->>'VIGENCIA_DESDE', '')::date AS vigencia_desde,
    NULLIF(s.payload->>'VIGENCIA_HASTA', '')::date AS vigencia_hasta,
    NULLIF(s.payload->>'FECHA_CANCELACION', '')::date AS fecha_cancelacion,
    NULLIF(s.payload->>'FECHA_ANULACION', '')::date AS fecha_anulacion,
    public.d6_texto_limpio(s.payload->>'COD_ESTADO_POLIZA') AS cod_estado,
    public.d6_texto_limpio(s.payload->>'STATUS') AS status_raw,
    public.d6_numero(s.payload->>'MONTO_AFIANZADO') AS monto,
    public.d6_numero(s.payload->>'PRIMA') AS prima,
    public.d6_numero(s.payload->>'DERECHOS') AS derechos,
    public.d6_numero(s.payload->>'OTROS') AS otros,
    public.d6_numero(s.payload->>'GASTOS_ENVIO') AS gastos_envio,
    public.d6_numero(s.payload->>'IVA') AS iva,
    public.d6_numero(s.payload->>'PRIMA_ANUAL') AS prima_anual,
    public.d6_texto_limpio(s.payload->>'CONTRATO_NUMERO') AS contrato_numero,
    NULLIF(s.payload->>'CONTRATO_FECHA', '')::date AS contrato_fecha,
    public.d6_numero(s.payload->>'CONTRATO_VALOR') AS contrato_valor,
    public.d6_texto_limpio(s.payload->>'TEMA_DE_FIANZA') AS tema
  FROM public.oracle_d6_staging s
  WHERE s.fuente = 'CARTERA_D6' AND s.sync_run_id = p_run_id
    AND NULLIF(s.payload->>'FIANZA', '') IS NOT NULL;

  IF NOT EXISTS (SELECT 1 FROM _c) THEN
    RAISE EXCEPTION 'La corrida % no tiene filas de cartera', p_run_id;
  END IF;

  -- Beneficiarios: un codigo nuevo entra sin marca. Administracion debe asignarlo.
  WITH nuevos AS (
    INSERT INTO public.beneficiarios (codigo_contacto, nombre, tipo_persona)
    SELECT DISTINCT ON (beneficiario_codigo) beneficiario_codigo, beneficiario_nombre, 'JURIDICA'
    FROM _c WHERE beneficiario_codigo IS NOT NULL
    ON CONFLICT (codigo_contacto) DO NOTHING
    RETURNING codigo_contacto, nombre
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object('codigo', codigo_contacto, 'nombre', nombre)), '[]'::jsonb)
  INTO v_beneficiarios_nuevos FROM nuevos;

  WITH nuevos AS (
    INSERT INTO public.clientes (codigo_contacto, nombre, tipo_persona)
    SELECT DISTINCT ON (cliente_codigo) cliente_codigo, cliente_nombre,
      CASE WHEN cliente_nombre ~* '(SOCIEDAD|S\.\s*A\.?$|LIMITADA|COPROPIEDAD|, S\.A)' THEN 'JURIDICA' ELSE 'INDIVIDUAL' END::public.tipo_persona
    FROM _c WHERE cliente_codigo IS NOT NULL
    ORDER BY cliente_codigo, fecha_emision DESC NULLS LAST
    ON CONFLICT (codigo_contacto) DO UPDATE SET nombre = EXCLUDED.nombre
    RETURNING (xmax = 0) AS insertado
  )
  SELECT count(*) FILTER (WHERE insertado) INTO v_clientes_nuevos FROM nuevos;

  INSERT INTO public.agentes (numero_agente, indice_agente, nombre)
  SELECT DISTINCT agente_numero, agente_indice, agente_nombre FROM _c
  ON CONFLICT (numero_agente, indice_agente, nombre) DO NOTHING;

  WITH aplicadas AS (
    INSERT INTO public.fianzas (
      ramo, fianza, endoso, clase, cliente_id, beneficiario_id, agente_id, fecha_emision, vigencia_desde, vigencia_hasta,
      fecha_cancelacion, fecha_anulacion, cod_estado_poliza, status_raw, status, operational_status,
      monto_afianzado, prima, derechos, otros, gastos_envio, iva, prima_anual,
      contrato_numero, contrato_fecha, contrato_valor, tema_de_fianza
    )
    SELECT
      c.ramo, c.fianza, c.endoso, c.clase, cl.id, b.id, a.id, c.fecha_emision,
      COALESCE(c.vigencia_desde, c.fecha_emision), COALESCE(c.vigencia_hasta, c.vigencia_desde, c.fecha_emision),
      c.fecha_cancelacion, c.fecha_anulacion, c.cod_estado, c.status_raw,
      (CASE WHEN c.status_raw = 'C' AND c.cod_estado = 'A' THEN 'ANULADA'
            WHEN c.status_raw = 'C' THEN 'CANCELADA'
            WHEN c.status_raw = 'NV' THEN 'EN_TRAMITE'
            ELSE 'VIGENTE' END)::public.fianza_status,
      (CASE WHEN c.status_raw = 'C' AND c.cod_estado = 'A' THEN 'ANULADA'
            WHEN c.status_raw = 'C' THEN 'CANCELADA'
            ELSE 'VIGENTE' END)::public.d6_poliza_status,
      c.monto, c.prima, c.derechos, c.otros, c.gastos_envio, c.iva, c.prima_anual,
      c.contrato_numero, c.contrato_fecha, c.contrato_valor, c.tema
    FROM _c c
    JOIN public.clientes cl ON cl.codigo_contacto = c.cliente_codigo
    JOIN public.beneficiarios b ON b.codigo_contacto = c.beneficiario_codigo
    LEFT JOIN public.agentes a ON a.numero_agente = c.agente_numero AND a.indice_agente = c.agente_indice AND a.nombre = c.agente_nombre
    ON CONFLICT (fianza, endoso) DO UPDATE SET
      cliente_id = EXCLUDED.cliente_id, beneficiario_id = EXCLUDED.beneficiario_id, agente_id = EXCLUDED.agente_id,
      fecha_emision = EXCLUDED.fecha_emision, vigencia_desde = EXCLUDED.vigencia_desde, vigencia_hasta = EXCLUDED.vigencia_hasta,
      fecha_cancelacion = COALESCE(EXCLUDED.fecha_cancelacion, public.fianzas.fecha_cancelacion),
      fecha_anulacion = EXCLUDED.fecha_anulacion, cod_estado_poliza = EXCLUDED.cod_estado_poliza,
      status_raw = EXCLUDED.status_raw, status = EXCLUDED.status,
      -- Una baja en proceso en la app se respeta hasta que Oracle la cancele.
      operational_status = CASE
        WHEN EXCLUDED.operational_status IN ('CANCELADA', 'ANULADA') THEN EXCLUDED.operational_status
        WHEN public.fianzas.operational_status = 'PENDIENTE_ANULACION' THEN public.fianzas.operational_status
        ELSE EXCLUDED.operational_status END,
      monto_afianzado = EXCLUDED.monto_afianzado, prima = EXCLUDED.prima, derechos = EXCLUDED.derechos,
      otros = EXCLUDED.otros, gastos_envio = EXCLUDED.gastos_envio, iva = EXCLUDED.iva, prima_anual = EXCLUDED.prima_anual,
      contrato_numero = COALESCE(EXCLUDED.contrato_numero, public.fianzas.contrato_numero),
      contrato_fecha = COALESCE(EXCLUDED.contrato_fecha, public.fianzas.contrato_fecha),
      contrato_valor = CASE WHEN EXCLUDED.contrato_valor > 0 THEN EXCLUDED.contrato_valor ELSE public.fianzas.contrato_valor END,
      tema_de_fianza = COALESCE(EXCLUDED.tema_de_fianza, public.fianzas.tema_de_fianza)
    RETURNING (xmax = 0) AS insertado
  )
  SELECT count(*) FILTER (WHERE insertado), count(*) FILTER (WHERE NOT insertado)
  INTO v_insertadas, v_actualizadas FROM aplicadas;

  -- Endosos anteriores al ultimo que trae Oracle.
  WITH ultimo AS (SELECT fianza, max(endoso) AS endoso FROM _c GROUP BY fianza),
  marcadas AS (
    UPDATE public.fianzas f SET operational_status = 'REEMPLAZADA_POR_ENDOSO'
    FROM ultimo u
    WHERE f.fianza = u.fianza AND f.endoso < u.endoso
      AND f.operational_status NOT IN ('REEMPLAZADA_POR_ENDOSO', 'CANCELADA', 'ANULADA')
    RETURNING 1
  )
  SELECT count(*) INTO v_reemplazadas FROM marcadas;

  -- Emitidas en la app en los ultimos 90 dias que el export todavia no trae.
  SELECT COALESCE(jsonb_agg(f.fianza ORDER BY f.fianza), '[]'::jsonb) INTO v_sin_oracle
  FROM public.fianzas f
  WHERE f.created_at >= now() - INTERVAL '90 days'
    AND EXISTS (SELECT 1 FROM public.solicitudes_alta sa WHERE sa.contrato_id = f.contrato_id AND sa.estado_operativo = 'EMITIDA')
    AND NOT EXISTS (SELECT 1 FROM _c WHERE _c.fianza = f.fianza);

  v_resumen := jsonb_build_object(
    'filas', (SELECT count(*) FROM _c),
    'clientes_nuevos', v_clientes_nuevos,
    'beneficiarios_sin_marca', v_beneficiarios_nuevos,
    'polizas_nuevas', v_insertadas,
    'polizas_actualizadas', v_actualizadas,
    'endosos_reemplazados', v_reemplazadas,
    'emitidas_en_app_sin_oracle', v_sin_oracle
  );
  UPDATE public.oracle_sync_runs_d6 SET resumen = v_resumen, filas_aplicadas = v_insertadas + v_actualizadas
  WHERE id = p_run_id;
  RETURN v_resumen;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.d6_aplicar_cartera_oracle(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.d6_aplicar_cartera_oracle(UUID) TO service_role;

-- La cartera oculta los endosos reemplazados: el vigente es el ultimo.
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
LEFT JOIN public.reglas_cobro_d6 rc ON rc.codigo_marca = g.codigo_regla_cobro
WHERE f.operational_status <> 'REEMPLAZADA_POR_ENDOSO';
GRANT SELECT ON public.v_fianzas TO authenticated;
REVOKE ALL ON public.v_fianzas FROM anon;
