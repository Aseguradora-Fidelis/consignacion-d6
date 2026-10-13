-- Cruce de la cartera de Oracle con el modelo. Se revierte al final.
BEGIN;
CREATE OR REPLACE FUNCTION pg_temp.ok(p_cond BOOLEAN, p_msg TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  IF p_cond IS NOT TRUE THEN RAISE EXCEPTION 'FALLA: %', p_msg; END IF;
  RAISE NOTICE 'ok: %', p_msg;
END;
$$;

INSERT INTO public.oracle_sync_runs_d6 (id, fuente, estado) VALUES ('00000000-0000-4000-b000-000000000001', 'CARTERA_D6', 'INICIADO');
INSERT INTO public.oracle_d6_staging (sync_run_id, fuente, source_key, payload) VALUES
('00000000-0000-4000-b000-000000000001', 'CARTERA_D6', '7000001-2', jsonb_build_object(
  'RAMO','FIA','FIANZA','7000001','ENDOSO','2','CLASE','D-6','COD_CONTACTO_CLIENTE','700001','NOMBRE_CLIENTE','ROSA  MARIA   PRUEBA  ORACLE',
  'COD_CONTACTO_BENEFICIARIO','527613','NOMBRE_BENEFICIARIO','UNIDADES MOVILES','NUMERO_AGENTE','0','INDICE_AGENTE','0','NOMBRE_AGENTE','AGENTE DIRECTO',
  'FECHA_EMISION','2026-08-01','VIGENCIA_DESDE','2026-08-01','VIGENCIA_HASTA','2027-07-31','STATUS','V','COD_ESTADO_POLIZA','EN',
  'MONTO_AFIANZADO','200000','PRIMA','4500','DERECHOS','360','IVA','583.20','PRIMA_ANUAL','4500','CONTRATO_VALOR','200000')),
('00000000-0000-4000-b000-000000000001', 'CARTERA_D6', '7000002-3', jsonb_build_object(
  'RAMO','FIA','FIANZA','7000002','ENDOSO','3','CLASE','D-6','COD_CONTACTO_CLIENTE','700002','NOMBRE_CLIENTE','DISTRIBUIDORA ORACLE, SOCIEDAD ANONIMA',
  'COD_CONTACTO_BENEFICIARIO','999001','NOMBRE_BENEFICIARIO','MARCA NUEVA DE PRUEBA, S.A.','NUMERO_AGENTE','0','INDICE_AGENTE','0','NOMBRE_AGENTE','AGENTE DIRECTO',
  'FECHA_EMISION','2026-03-01','VIGENCIA_DESDE','2025-03-01','VIGENCIA_HASTA','2026-02-28','FECHA_CANCELACION','2026-03-01','STATUS','C','COD_ESTADO_POLIZA','EN',
  'MONTO_AFIANZADO','0','PRIMA','0','DERECHOS','0','IVA','0','PRIMA_ANUAL','0','CONTRATO_VALOR','150000'));

-- Endoso anterior de la misma fianza que ya existia en la app.
INSERT INTO public.clientes (codigo_contacto, nombre) VALUES (700001, 'ROSA MARIA PRUEBA ORACLE');
INSERT INTO public.fianzas (fianza, endoso, cliente_id, beneficiario_id, vigencia_desde, vigencia_hasta, monto_afianzado, operational_status)
SELECT 7000001, 1, c.id, b.id, '2025-08-01', '2026-07-31', 200000, 'VIGENTE'
FROM public.clientes c, public.beneficiarios b WHERE c.codigo_contacto = 700001 AND b.codigo_contacto = 527613;

SET LOCAL role service_role;
CREATE TEMP TABLE r AS SELECT public.d6_aplicar_cartera_oracle('00000000-0000-4000-b000-000000000001') AS resumen;
RESET role;

SELECT pg_temp.ok((SELECT (resumen->>'polizas_nuevas')::int FROM r) = 2, 'entran las dos polizas del staging');
SELECT pg_temp.ok((SELECT nombre FROM public.clientes WHERE codigo_contacto = 700001) = 'ROSA MARIA PRUEBA ORACLE', 'los dobles espacios del nombre se normalizan');
SELECT pg_temp.ok((SELECT tipo_persona FROM public.clientes WHERE codigo_contacto = 700002) = 'JURIDICA', 'una sociedad se clasifica como persona juridica');
SELECT pg_temp.ok((SELECT operational_status FROM public.fianzas WHERE fianza = 7000001 AND endoso = 1) = 'REEMPLAZADA_POR_ENDOSO', 'el endoso anterior queda reemplazado');
SELECT pg_temp.ok((SELECT count(*) FROM public.v_fianzas WHERE fianza = 7000001) = 1, 'la cartera muestra solo el ultimo endoso');
SELECT pg_temp.ok((SELECT estado FROM public.v_fianzas WHERE fianza = 7000002) = 'CANCELADA', 'una poliza con STATUS C queda cancelada');
SELECT pg_temp.ok((SELECT monto_original FROM public.v_fianzas WHERE fianza = 7000002) = 150000, 'el monto de una cancelada se recupera del valor del contrato');
SELECT pg_temp.ok((SELECT resumen->'beneficiarios_sin_marca' @> '[{"codigo": 999001}]' FROM r), 'un beneficiario nuevo se reporta sin marca');

SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-000000000001","role":"authenticated"}', true);
SET LOCAL role authenticated;
DO $$
BEGIN
  BEGIN
    PERFORM public.d6_aplicar_cartera_oracle('00000000-0000-4000-b000-000000000001');
    RAISE EXCEPTION 'FALLA: un usuario aplico la cartera';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'ok: solo el job interno aplica la cartera';
  END;
END $$;
RESET role;

-- La carga completa (044): trae el NIT del contacto y reconoce sola la solicitud emitida.
INSERT INTO public.solicitudes_alta (numero_solicitud, beneficiario_id, monto_solicitado, vigencia_desde, vigencia_hasta,
  estado_operativo, tipo_solicitud, cliente_nombre_tmp, cliente_nit_tmp)
SELECT 'ALT-PRUEBA-CARGA', b.id, 90000, CURRENT_DATE, CURRENT_DATE + 365, 'EXPEDIENTE_RECIBIDO', 'NUEVA', 'Distribuidor de la carga', '6666666-6'
FROM public.beneficiarios b WHERE b.codigo_contacto = 527613;
INSERT INTO public.oracle_sync_runs_d6 (id, fuente, estado) VALUES ('00000000-0000-4000-b000-000000000002', 'CARTERA_D6', 'INICIADO');
INSERT INTO public.oracle_d6_staging (sync_run_id, fuente, source_key, payload) VALUES
('00000000-0000-4000-b000-000000000002', 'CARTERA_D6', '7000003-0', jsonb_build_object(
  'RAMO','FIA','FIANZA','7000003','ENDOSO','0','CLASE','D-6','COD_CONTACTO_CLIENTE','700003','NOMBRE_CLIENTE','DISTRIBUIDOR DE LA CARGA',
  'NIT_CLIENTE','6666666-6','COD_CONTACTO_BENEFICIARIO','527613','NOMBRE_BENEFICIARIO','UNIDADES MOVILES','NUMERO_AGENTE','0','INDICE_AGENTE','0',
  'NOMBRE_AGENTE','AGENTE DIRECTO','FECHA_EMISION',CURRENT_DATE::text,'VIGENCIA_DESDE',CURRENT_DATE::text,'VIGENCIA_HASTA',(CURRENT_DATE + 364)::text,
  'STATUS','V','COD_ESTADO_POLIZA','EN','MONTO_AFIANZADO','90000','PRIMA','2025','DERECHOS','162','IVA','262.44','PRIMA_ANUAL','2025',
  'CONTRATO_VALOR','90000'));
-- La carga deja una tabla temporal hasta el COMMIT; en la prueba todo va en una transaccion.
DROP TABLE IF EXISTS pg_temp._c;
SET LOCAL role service_role;
CREATE TEMP TABLE r2 AS SELECT public.d6_aplicar_cartera_fiso('00000000-0000-4000-b000-000000000002') AS resumen;
RESET role;
SELECT pg_temp.ok((SELECT nit FROM public.clientes WHERE codigo_contacto = 700003) = '6666666-6'
                  AND (SELECT (resumen->>'nits_actualizados')::int >= 1 FROM r2),
  'la carga trae el NIT del distribuidor desde los contactos de FISO');
SELECT pg_temp.ok((SELECT sa.estado_operativo = 'EMITIDA' AND f.fianza = 7000003 AND sa.vigencia_hasta = CURRENT_DATE + 364
                   FROM public.solicitudes_alta sa JOIN public.fianzas f ON f.id = sa.fianza_emitida_id
                   WHERE sa.numero_solicitud = 'ALT-PRUEBA-CARGA')
                  AND (SELECT (resumen->>'solicitudes_emitidas')::int >= 1 FROM r2),
  'en la misma carga la solicitud con ese NIT y esa marca queda emitida');
ROLLBACK;
