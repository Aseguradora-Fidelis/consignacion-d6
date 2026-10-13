-- Cuenta de la marca con las facturas de FISO (migracion 044): la marca ve sus meses con total,
-- pagado y saldo. Los pagos se aplican en FISO y llegan con la carga. Se revierte al final.
-- La base local tiene facturas reales de FISO: se miden diferencias, no totales absolutos.
BEGIN;

CREATE OR REPLACE FUNCTION pg_temp.como(p_user UUID)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('role', 'authenticated', true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_user::text, 'role', 'authenticated')::text, true);
END;
$$;
CREATE OR REPLACE FUNCTION pg_temp.ok(p_cond BOOLEAN, p_msg TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  IF p_cond IS NOT TRUE THEN RAISE EXCEPTION 'FALLA: %', p_msg; END IF;
  RAISE NOTICE 'ok: %', p_msg;
END;
$$;
CREATE OR REPLACE FUNCTION pg_temp.falla_con(p_sql TEXT, p_msg TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  BEGIN EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'ok: % (%)', p_msg, SQLERRM; RETURN; END;
  RAISE EXCEPTION 'FALLA: %', p_msg;
END;
$$;
CREATE TEMP TABLE ctx (clave TEXT PRIMARY KEY, valor TEXT);
GRANT ALL ON ctx TO authenticated;
-- Lo que la marca veia antes de cada carga, por mes.
CREATE TEMP TABLE antes (paso TEXT, periodo DATE, facturas BIGINT, total NUMERIC, pagado NUMERIC, saldo NUMERIC);
GRANT ALL ON antes TO authenticated;

-- Mes cerrado anterior, un mes viejo sin facturas reales y una fianza de UMA.
INSERT INTO ctx VALUES ('periodo', to_char(date_trunc('month', CURRENT_DATE) - INTERVAL '1 month', 'YYYY-MM-DD'));
INSERT INTO ctx VALUES ('viejo', '2024-03-01');
INSERT INTO ctx SELECT 'grupo', id::text FROM public.grupos_beneficiarios WHERE codigo = 'GRP-UNIDADES-MOVILES';
INSERT INTO ctx SELECT 'fianza_uma', f.id::text FROM public.fianzas f JOIN public.beneficiarios b ON b.id = f.beneficiario_id
WHERE b.codigo_contacto = 527613 ORDER BY f.fianza LIMIT 1;
UPDATE public.fianzas SET pago_confirmado_at = NULL WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'fianza_uma');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.facturas_fiso_d6
                              WHERE date_trunc('month', fecha_emision) = (SELECT valor::date FROM ctx WHERE clave = 'viejo')),
  'el mes de control no tiene facturas reales');

-- Lo que UMA ve antes de la carga.
SELECT pg_temp.como('00000000-0000-4000-a000-000000000011');
INSERT INTO antes SELECT 'inicio', periodo, facturas, total, pagado, saldo FROM public.v_cuenta_marca
WHERE marca_id = (SELECT valor::uuid FROM ctx WHERE clave = 'grupo');
RESET role;

-- Simula la carga de facturas de Oracle (service_role): dos del mes anterior, una anulada y una
-- del mes de control.
INSERT INTO public.oracle_sync_runs_d6 (id, fuente, estado) VALUES ('00000000-0000-4000-b000-000000000001', 'FACTURAS_D6', 'COMPLETO');
INSERT INTO public.oracle_d6_staging (sync_run_id, fuente, source_key, payload)
SELECT '00000000-0000-4000-b000-000000000001', 'FACTURAS_D6', 'TST-' || n,
  jsonb_build_object('CORRELATIVO_UNICO_COBRO', 990000000 + n, 'SERIE', 'TST', 'FACTURA', n, 'COD_ESTADO_DOCUMENTO', 'P', 'RAMO', 1, 'FIANZA', f.fianza, 'ENDOSO', f.endoso,
    'COD_CONTACTO_BENEFICIARIO', 527613,
    'FEC_EMISION', CASE WHEN n = 4 THEN (SELECT valor FROM ctx WHERE clave = 'viejo')::date + 5
                        ELSE (SELECT valor FROM ctx WHERE clave = 'periodo')::date + n END,
    'PRIMA', 1000, 'DERECHOS', 80, 'IVA', 129.60, 'TOTAL_FACTURA', 1209.60, 'SALDO_FACTURA', 1209.60,
    'FEC_ANULACION', CASE WHEN n = 3 THEN (SELECT valor FROM ctx WHERE clave = 'periodo') END)
FROM public.fianzas f, generate_series(1, 4) n
WHERE f.id = (SELECT valor::uuid FROM ctx WHERE clave = 'fianza_uma');
SELECT pg_temp.ok((public.d6_aplicar_facturas_fiso('00000000-0000-4000-b000-000000000001')->>'facturas_nuevas')::int = 4,
  'la carga copia las facturas de FISO');
SELECT pg_temp.ok((public.d6_aplicar_facturas_fiso('00000000-0000-4000-b000-000000000001')->>'facturas_nuevas')::int = 0,
  'cargar dos veces no duplica facturas');

-- 1. La marca ve su cuenta del mes --------------------------------------------
SELECT pg_temp.como('00000000-0000-4000-a000-000000000011');
SELECT pg_temp.ok((SELECT count(*) FROM public.facturas_fiso_d6 WHERE serie = 'TST') = 4, 'la marca ve sus facturas de FISO');
SELECT pg_temp.ok(
  (SELECT v.facturas - COALESCE(a.facturas, 0) = 2 AND v.total - COALESCE(a.total, 0) = 2419.20
          AND v.saldo - COALESCE(a.saldo, 0) = 2419.20 AND v.pagado - COALESCE(a.pagado, 0) = 0
   FROM public.v_cuenta_marca v
   LEFT JOIN antes a ON a.paso = 'inicio' AND a.periodo = v.periodo
   WHERE v.marca_id = (SELECT valor::uuid FROM ctx WHERE clave = 'grupo') AND v.periodo = (SELECT valor::date FROM ctx WHERE clave = 'periodo')),
  'el mes suma las dos facturas nuevas al total y al saldo, sin la anulada');
SELECT pg_temp.ok(
  (SELECT v.total = (SELECT sum(ff.total) FROM public.facturas_fiso_d6 ff
                     JOIN public.grupo_beneficiario_rel r ON r.beneficiario_id = ff.beneficiario_id AND r.grupo_id = v.marca_id
                     WHERE date_trunc('month', ff.fecha_emision) = v.periodo AND ff.fecha_anulacion IS NULL)
   FROM public.v_cuenta_marca v
   WHERE v.marca_id = (SELECT valor::uuid FROM ctx WHERE clave = 'grupo') AND v.periodo = (SELECT valor::date FROM ctx WHERE clave = 'periodo')),
  'el total del mes cuadra al centavo con lo facturado en FISO');
SELECT pg_temp.ok(
  (SELECT facturas = 1 AND total = 1209.60 AND pagado = 0 AND saldo = 1209.60 AND estado = 'VENCIDO' AND dias_vencido > 0
          AND NOT mes_en_curso AND vence < CURRENT_DATE
   FROM public.v_cuenta_marca
   WHERE marca_id = (SELECT valor::uuid FROM ctx WHERE clave = 'grupo') AND periodo = (SELECT valor::date FROM ctx WHERE clave = 'viejo')),
  'un mes viejo sin pagar aparece vencido con sus dias de atraso');
INSERT INTO antes SELECT 'cargado', periodo, facturas, total, pagado, saldo FROM public.v_cuenta_marca
WHERE marca_id = (SELECT valor::uuid FROM ctx WHERE clave = 'grupo');
RESET role;

-- 2. Otra marca no ve la cuenta de UMA -----------------------------------------
SELECT pg_temp.como('00000000-0000-4000-a000-000000000012');
SELECT pg_temp.ok((SELECT count(*) FROM public.facturas_fiso_d6 WHERE serie = 'TST') = 0, 'otra marca no ve esas facturas');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.v_cuenta_marca WHERE marca_id = (SELECT valor::uuid FROM ctx WHERE clave = 'grupo')),
  'otra marca no ve la cuenta de UMA');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.v_cuenta_marca v JOIN public.grupos_beneficiarios g ON g.id = v.marca_id
                              WHERE g.codigo <> 'GRP-CENTRAL-MOTOPREMIUM'),
  'ADMOSA solo ve su propia cuenta');
RESET role;

-- Fidelis consulta la cuenta de todas las marcas, sin escribir pagos.
SELECT pg_temp.como('00000000-0000-4000-a000-000000000004');
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM public.v_cuenta_marca WHERE marca_id = (SELECT valor::uuid FROM ctx WHERE clave = 'grupo')),
  'Cobros consulta la cuenta de UMA');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname IN ('d6_registrar_pago', 'd6_conciliar_pago', 'd6_generar_estado_cuenta', 'd6_enviar_estado_cuenta')),
  'los pagos y los estados de cuenta no se hacen en la app: vienen de FISO');
SELECT pg_temp.falla_con($f$UPDATE public.facturas_fiso_d6 SET saldo = 0 WHERE serie = 'TST'$f$,
  'Cobros no baja saldos con un UPDATE directo');
RESET role;

-- 3. Cobros aplica en FISO el pago de la primera factura. La carga siguiente trae su saldo.
INSERT INTO public.oracle_sync_runs_d6 (id, fuente, estado) VALUES ('00000000-0000-4000-b000-000000000002', 'FACTURAS_D6', 'COMPLETO');
INSERT INTO public.oracle_d6_staging (sync_run_id, fuente, source_key, payload)
SELECT '00000000-0000-4000-b000-000000000002', 'FACTURAS_D6', 'TST2-' || n,
  jsonb_build_object('CORRELATIVO_UNICO_COBRO', 990000000 + n, 'SERIE', 'TST', 'FACTURA', n, 'COD_ESTADO_DOCUMENTO', 'C',
    'RAMO', 1, 'FIANZA', f.fianza, 'ENDOSO', f.endoso,
    'COD_CONTACTO_BENEFICIARIO', 527613, 'FEC_EMISION', (SELECT valor FROM ctx WHERE clave = 'periodo')::date + n,
    'PRIMA', 1000, 'DERECHOS', 80, 'IVA', 129.60, 'TOTAL_FACTURA', 1209.60,
    'SALDO_FACTURA', CASE WHEN n = 1 THEN 0 ELSE 1209.60 END,
    'FEC_PAGO', CASE WHEN n = 1 THEN CURRENT_DATE END)
FROM public.fianzas f, generate_series(1, 2) n
WHERE f.id = (SELECT valor::uuid FROM ctx WHERE clave = 'fianza_uma');
SELECT public.d6_aplicar_facturas_fiso('00000000-0000-4000-b000-000000000002');
SELECT pg_temp.como('00000000-0000-4000-a000-000000000011');
SELECT pg_temp.ok(
  (SELECT v.saldo = a.saldo - 1209.60 AND v.pagado = a.pagado + 1209.60 AND v.total = a.total AND v.facturas = a.facturas
   FROM public.v_cuenta_marca v JOIN antes a ON a.paso = 'cargado' AND a.periodo = v.periodo
   WHERE v.marca_id = (SELECT valor::uuid FROM ctx WHERE clave = 'grupo') AND v.periodo = (SELECT valor::date FROM ctx WHERE clave = 'periodo')),
  'con una factura pagada en FISO el saldo baja y lo pagado sube, el total no cambia');
RESET role;
SELECT pg_temp.ok(
  (SELECT pago_confirmado_at IS NOT NULL FROM public.fianzas WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'fianza_uma')),
  'el pago aplicado en FISO libera la poliza de contado para entrega');
UPDATE public.oracle_d6_staging SET payload = payload || '{"SALDO_FACTURA": 0}'::jsonb
WHERE sync_run_id = '00000000-0000-4000-b000-000000000002';
SELECT public.d6_aplicar_facturas_fiso('00000000-0000-4000-b000-000000000002');
SELECT pg_temp.como('00000000-0000-4000-a000-000000000011');
SELECT pg_temp.ok(
  (SELECT v.saldo = a.saldo - 2419.20 AND v.pagado = a.pagado + 2419.20
   FROM public.v_cuenta_marca v JOIN antes a ON a.paso = 'cargado' AND a.periodo = v.periodo
   WHERE v.marca_id = (SELECT valor::uuid FROM ctx WHERE clave = 'grupo') AND v.periodo = (SELECT valor::date FROM ctx WHERE clave = 'periodo')),
  'pagadas las dos en FISO, el saldo baja lo de ambas');
RESET role;

-- 4. Estado del mes segun el saldo de FISO (mes de control) ---------------------
UPDATE public.facturas_fiso_d6 SET saldo = 600 WHERE correlativo_cobro = 990000004;
SELECT pg_temp.como('00000000-0000-4000-a000-000000000011');
SELECT pg_temp.ok(
  (SELECT estado = 'PARCIAL' AND pagado = 609.60 AND saldo = 600 FROM public.v_cuenta_marca
   WHERE marca_id = (SELECT valor::uuid FROM ctx WHERE clave = 'grupo') AND periodo = (SELECT valor::date FROM ctx WHERE clave = 'viejo')),
  'con un abono en FISO el mes queda parcial');
RESET role;
UPDATE public.facturas_fiso_d6 SET saldo = 0 WHERE correlativo_cobro = 990000004;
SELECT pg_temp.como('00000000-0000-4000-a000-000000000011');
SELECT pg_temp.ok(
  (SELECT estado = 'PAGADO' AND saldo = 0 AND dias_vencido = 0 FROM public.v_cuenta_marca
   WHERE marca_id = (SELECT valor::uuid FROM ctx WHERE clave = 'grupo') AND periodo = (SELECT valor::date FROM ctx WHERE clave = 'viejo')),
  'con todo pagado en FISO el mes queda pagado y sin atraso');
RESET role;
-- Si FISO anula la factura, el mes deja de cobrarla.
UPDATE public.facturas_fiso_d6 SET fecha_anulacion = CURRENT_DATE WHERE correlativo_cobro = 990000004;
SELECT pg_temp.como('00000000-0000-4000-a000-000000000011');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.v_cuenta_marca
                              WHERE marca_id = (SELECT valor::uuid FROM ctx WHERE clave = 'grupo') AND periodo = (SELECT valor::date FROM ctx WHERE clave = 'viejo')),
  'una factura anulada en FISO no cuenta en la cuenta de la marca');
RESET role;

ROLLBACK;
