-- Operacion mensual con FISO como fuente (migracion 044): la marca pide bajas con fecha futura,
-- el cuadre muestra las que FISO no ha cancelado, condiciones por marca de solo lectura, sin
-- accesorio ni entrega, e incrementos reconocidos por la carga. Se revierte.
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

-- Una fianza vigente de UMA sin bajas.
INSERT INTO ctx SELECT 'fianza', f.id::text FROM public.fianzas f JOIN public.beneficiarios b ON b.id = f.beneficiario_id
WHERE b.codigo_contacto = 527613 AND f.operational_status = 'VIGENTE' AND f.vigencia_hasta >= CURRENT_DATE + 120
  AND NOT EXISTS (SELECT 1 FROM public.solicitudes_baja s WHERE s.fianza_id = f.id)
ORDER BY f.fianza LIMIT 1;
INSERT INTO ctx SELECT 'numero', fianza::text FROM public.fianzas WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'fianza');
INSERT INTO ctx VALUES ('fin_mes_2', public.d6_fin_de_mes((CURRENT_DATE + INTERVAL '2 months')::date)::text);

-- 1. La marca pide la baja para dentro de dos meses -------------------------
SELECT pg_temp.como('00000000-0000-4000-a000-000000000011');
INSERT INTO ctx SELECT 'baja', baja_id::text FROM public.d6_solicitar_baja(
  (SELECT valor::uuid FROM ctx WHERE clave = 'fianza'), 'DEVOLUCION_MERCADERIA', 'Cierra el punto de venta',
  (CURRENT_DATE + INTERVAL '2 months')::date);
SELECT pg_temp.ok((SELECT fecha_efectiva FROM public.solicitudes_baja WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'baja'))
  = (SELECT valor::date FROM ctx WHERE clave = 'fin_mes_2'), 'la baja queda al cierre del mes elegido');
SELECT pg_temp.ok((SELECT condiciones_marca_d6.forma_pago FROM public.condiciones_marca_d6
  JOIN public.grupos_beneficiarios g ON g.id = grupo_id WHERE g.codigo = 'GRP-UNIDADES-MOVILES') = 'ANTICIPADO',
  'la marca lee sus condiciones');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.condiciones_marca_d6 c JOIN public.grupos_beneficiarios g ON g.id = c.grupo_id
  WHERE g.codigo = 'GRP-CENTRAL-MOTOPREMIUM'), 'la marca no ve las condiciones de otra');
UPDATE public.condiciones_marca_d6 SET forma_pago = 'CREDITO'
WHERE grupo_id = (SELECT id FROM public.grupos_beneficiarios WHERE codigo = 'GRP-UNIDADES-MOVILES');
SELECT pg_temp.falla_con('SELECT * FROM public.d6_cuadre_fiso()', 'la marca no ve el cuadre con FISO');
SELECT pg_temp.falla_con(
  format($f$INSERT INTO public.comunicaciones_d6 (cliente_id, canal, asunto, registrada_por) SELECT cliente_id, 'NOTA', 'x', auth.uid() FROM public.fianzas WHERE id = %L$f$,
    (SELECT valor FROM ctx WHERE clave = 'fianza')),
  'la marca no escribe en la bitacora interna');
RESET role;
SELECT pg_temp.ok((SELECT c.forma_pago FROM public.condiciones_marca_d6 c JOIN public.grupos_beneficiarios g ON g.id = c.grupo_id
  WHERE g.codigo = 'GRP-UNIDADES-MOVILES') = 'ANTICIPADO', 'la marca no cambia sus condiciones');

-- 2. Fidelis no resuelve la baja: la consulta y la cancela en FISO ------------
SELECT pg_temp.como('00000000-0000-4000-a000-000000000002');
SELECT pg_temp.ok((SELECT estado FROM public.solicitudes_baja WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'baja')) = 'PENDIENTE_REVISION',
  'Suscripcion ve la baja pedida por la marca');
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM public.d6_historial_afianzado((SELECT cliente_id FROM public.fianzas WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'fianza')))
  WHERE tipo = 'BAJA'), 'la baja aparece en el historial del afianzado');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.d6_cuadre_fiso() WHERE tipo = 'BAJA_PENDIENTE_EN_FISO'
                              AND fianza_id = (SELECT valor::uuid FROM ctx WHERE clave = 'fianza')),
  'una baja con fecha futura todavia no aparece en el cuadre');
SELECT pg_temp.ok((SELECT estado FROM public.v_fianzas WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'fianza')) IN ('VIGENTE', 'POR_RENOVAR'),
  'la poliza sigue vigente en la app hasta que FISO la cancele');
RESET role;

-- Llega la fecha efectiva (se adelanta para la prueba) y FISO todavia no la cancela.
UPDATE public.solicitudes_baja SET fecha_efectiva = CURRENT_DATE - 1 WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'baja');
SELECT pg_temp.como('00000000-0000-4000-a000-000000000002');
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM public.d6_cuadre_fiso() WHERE tipo = 'BAJA_PENDIENTE_EN_FISO'
                          AND fianza_id = (SELECT valor::uuid FROM ctx WHERE clave = 'fianza')),
  'pasada la fecha, la baja sin cancelar en FISO aparece en el cuadre');
RESET role;

-- La carga de cartera trae la fianza cancelada en FISO (STATUS C con fecha de cancelacion).
INSERT INTO public.oracle_sync_runs_d6 (id, fuente, estado) VALUES ('00000000-0000-4000-b000-000000000031', 'CARTERA_D6', 'INICIADO');
INSERT INTO public.oracle_d6_staging (sync_run_id, fuente, source_key, payload)
SELECT '00000000-0000-4000-b000-000000000031', 'CARTERA_D6', f.fianza || '-' || f.endoso, jsonb_build_object(
  'RAMO', 'FIA', 'FIANZA', f.fianza::text, 'ENDOSO', f.endoso::text, 'CLASE', 'D-6', 'COD_CONTACTO_CLIENTE', c.codigo_contacto::text,
  'NOMBRE_CLIENTE', c.nombre, 'COD_CONTACTO_BENEFICIARIO', b.codigo_contacto::text, 'NOMBRE_BENEFICIARIO', b.nombre,
  'NUMERO_AGENTE', '0', 'INDICE_AGENTE', '0', 'NOMBRE_AGENTE', 'AGENTE DIRECTO',
  'FECHA_EMISION', f.fecha_emision::text, 'VIGENCIA_DESDE', f.vigencia_desde::text, 'VIGENCIA_HASTA', f.vigencia_hasta::text,
  'FECHA_CANCELACION', (CURRENT_DATE - 1)::text, 'STATUS', 'C', 'COD_ESTADO_POLIZA', 'EN',
  'MONTO_AFIANZADO', f.monto_afianzado::text, 'PRIMA', COALESCE(f.prima, 0)::text, 'DERECHOS', COALESCE(f.derechos, 0)::text,
  'IVA', COALESCE(f.iva, 0)::text, 'PRIMA_ANUAL', COALESCE(f.prima_anual, 0)::text, 'CONTRATO_VALOR', COALESCE(f.contrato_valor, 0)::text)
FROM public.fianzas f JOIN public.clientes c ON c.id = f.cliente_id JOIN public.beneficiarios b ON b.id = f.beneficiario_id
WHERE f.id = (SELECT valor::uuid FROM ctx WHERE clave = 'fianza')
-- Si la fila ya vino en una carga anterior, se toma esa con el estado nuevo.
ON CONFLICT (fuente, source_key) DO UPDATE SET sync_run_id = EXCLUDED.sync_run_id,
  payload = public.oracle_d6_staging.payload || jsonb_build_object('STATUS', 'C', 'FECHA_CANCELACION', (CURRENT_DATE - 1)::text);
SET LOCAL role service_role;
SELECT public.d6_aplicar_cartera_fiso('00000000-0000-4000-b000-000000000031');
RESET role;
SELECT pg_temp.como('00000000-0000-4000-a000-000000000002');
SELECT pg_temp.ok((SELECT estado FROM public.v_fianzas WHERE fianza = (SELECT valor::bigint FROM ctx WHERE clave = 'numero')) = 'CANCELADA',
  'la carga trae la poliza cancelada');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.d6_cuadre_fiso() WHERE tipo = 'BAJA_PENDIENTE_EN_FISO'
                              AND fianza = (SELECT valor::bigint FROM ctx WHERE clave = 'numero')),
  'cancelada en FISO, la baja deja de aparecer en el cuadre');
RESET role;
SELECT pg_temp.como('00000000-0000-4000-a000-000000000011');
SELECT pg_temp.ok((SELECT estado FROM public.v_fianzas WHERE fianza = (SELECT valor::bigint FROM ctx WHERE clave = 'numero')) = 'CANCELADA',
  'la marca ve su baja procesada');
RESET role;

-- 3. Sin documento accesorio ni entrega fisica en la app -------------------
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.ive_requisitos_d6 WHERE categoria = 'DOCUMENTO_ACCESORIO' AND activo),
  'el documento accesorio ya no se pide');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'public'::regnamespace
                              AND proname IN ('d6_registrar_accesorio', 'd6_registrar_entrega', 'd6_anulaciones_mes', 'd6_marcar_anulaciones_enviadas')),
  'ni accesorio, ni entrega, ni lista de anulaciones: eso vive en FISO');

-- 4. Incremento: fianza nueva o endoso que trae FISO --------------------------
INSERT INTO ctx SELECT 'base', f.id::text FROM public.fianzas f JOIN public.beneficiarios b ON b.id = f.beneficiario_id
WHERE b.codigo_contacto = 527613 AND f.operational_status = 'VIGENTE' AND f.vigencia_hasta >= CURRENT_DATE + 30
  AND f.id <> (SELECT valor::uuid FROM ctx WHERE clave = 'fianza')
  AND NOT EXISTS (SELECT 1 FROM public.solicitudes_baja s WHERE s.fianza_id = f.id)
ORDER BY f.fianza LIMIT 1;
-- El distribuidor tiene NIT en los contactos de FISO.
UPDATE public.clientes SET nit = COALESCE(nit, '8888888-8')
WHERE id = (SELECT cliente_id FROM public.fianzas WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'base'));
INSERT INTO public.solicitudes_alta (numero_solicitud, cliente_id, beneficiario_id, monto_solicitado, vigencia_desde, vigencia_hasta,
  estado_operativo, tipo_solicitud, fianza_anterior_id, cliente_nombre_tmp, cliente_nit_tmp)
SELECT 'ALT-PRUEBA-INC1', f.cliente_id, f.beneficiario_id, f.monto_afianzado + 50000, CURRENT_DATE, CURRENT_DATE + 365,
  'EXPEDIENTE_RECIBIDO', 'INCREMENTO', f.id, 'Prueba', c.nit
FROM public.fianzas f JOIN public.clientes c ON c.id = f.cliente_id WHERE f.id = (SELECT valor::uuid FROM ctx WHERE clave = 'base');
SELECT pg_temp.como('00000000-0000-4000-a000-000000000002');
SELECT pg_temp.ok((SELECT (d6_referencia_alta(id)->>'monto_anterior')::numeric > 0 FROM public.solicitudes_alta WHERE numero_solicitud = 'ALT-PRUEBA-INC1'),
  'la referencia compara contra la fianza que cambia');
RESET role;
SELECT public.d6_vincular_emisiones_fiso();
SELECT pg_temp.ok((SELECT estado_operativo = 'EXPEDIENTE_RECIBIDO' AND fianza_emitida_id IS NULL
                   FROM public.solicitudes_alta WHERE numero_solicitud = 'ALT-PRUEBA-INC1'),
  'la fianza anterior al incremento no cuenta como su emision');
-- El incremento se emite en FISO como fianza nueva y llega con la carga.
INSERT INTO public.fianzas (fianza, endoso, cliente_id, beneficiario_id, fecha_emision, vigencia_desde, vigencia_hasta,
  status, operational_status, monto_afianzado, contrato_numero, contrato_fecha)
SELECT 990000001, 0, f.cliente_id, f.beneficiario_id, CURRENT_DATE, CURRENT_DATE, CURRENT_DATE + 365, 'VIGENTE', 'VIGENTE',
  f.monto_afianzado + 50000, 'ESC-PRUEBA-1', CURRENT_DATE
FROM public.fianzas f WHERE f.id = (SELECT valor::uuid FROM ctx WHERE clave = 'base');
SELECT public.d6_vincular_emisiones_fiso();
INSERT INTO ctx SELECT 'nueva', fianza_emitida_id::text FROM public.solicitudes_alta WHERE numero_solicitud = 'ALT-PRUEBA-INC1';
SELECT pg_temp.ok((SELECT fianza = 990000001 FROM public.fianzas WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'nueva')),
  'la carga reconoce la fianza nueva del incremento');
SELECT pg_temp.ok((SELECT operational_status IN ('VIGENTE', 'POR_RENOVAR') FROM public.fianzas WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'base')),
  'reconocer el incremento no anula la anterior: eso lo hace FISO y llega con la carga');

-- Como modificacion, FISO trae un endoso de la misma fianza y la carga marca el anterior.
INSERT INTO public.solicitudes_alta (numero_solicitud, cliente_id, beneficiario_id, monto_solicitado, vigencia_desde, vigencia_hasta,
  estado_operativo, tipo_solicitud, fianza_anterior_id, cliente_nombre_tmp, cliente_nit_tmp)
SELECT 'ALT-PRUEBA-INC2', f.cliente_id, f.beneficiario_id, f.monto_afianzado + 50000, CURRENT_DATE, CURRENT_DATE + 365,
  'EXPEDIENTE_RECIBIDO', 'INCREMENTO', f.id, 'Prueba', c.nit
FROM public.fianzas f JOIN public.clientes c ON c.id = f.cliente_id WHERE f.id = (SELECT valor::uuid FROM ctx WHERE clave = 'nueva');
UPDATE public.fianzas SET operational_status = 'REEMPLAZADA_POR_ENDOSO' WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'nueva');
INSERT INTO public.fianzas (fianza, endoso, cliente_id, beneficiario_id, fecha_emision, vigencia_desde, vigencia_hasta,
  status, operational_status, monto_afianzado)
SELECT 990000001, 1, f.cliente_id, f.beneficiario_id, CURRENT_DATE, CURRENT_DATE, CURRENT_DATE + 365, 'VIGENTE', 'VIGENTE', f.monto_afianzado + 50000
FROM public.fianzas f WHERE f.id = (SELECT valor::uuid FROM ctx WHERE clave = 'nueva');
SELECT public.d6_vincular_emisiones_fiso();
SELECT pg_temp.ok((SELECT f.endoso = 1 AND sa.estado_operativo = 'EMITIDA'
                   FROM public.solicitudes_alta sa JOIN public.fianzas f ON f.id = sa.fianza_emitida_id
                   WHERE sa.numero_solicitud = 'ALT-PRUEBA-INC2'),
  'como modificacion se reconoce el ultimo endoso que trajo FISO');

ROLLBACK;
