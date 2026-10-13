-- Separacion estricta entre marcas competidoras y modo reunion del personal (migracion 031).
BEGIN;

CREATE OR REPLACE FUNCTION pg_temp.como(p_user UUID, p_marca TEXT DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('role', 'authenticated', true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_user::text, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', CASE WHEN p_marca IS NULL THEN '{}' ELSE json_build_object('x-d6-marca', p_marca)::text END, true);
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

CREATE TEMP TABLE ctx AS
SELECT
  (SELECT id FROM public.grupos_beneficiarios WHERE codigo = 'GRP-UNIDADES-MOVILES') AS uma,
  (SELECT id FROM public.grupos_beneficiarios WHERE codigo = 'GRP-CENTRAL-MOTOPREMIUM') AS admosa,
  (SELECT count(*) FROM public.fianzas f JOIN public.grupo_beneficiario_rel r ON r.beneficiario_id = f.beneficiario_id
     JOIN public.grupos_beneficiarios g ON g.id = r.grupo_id WHERE g.codigo = 'GRP-UNIDADES-MOVILES'
     AND f.operational_status <> 'REEMPLAZADA_POR_ENDOSO') AS fianzas_uma,
  (SELECT f.id FROM public.fianzas f JOIN public.grupo_beneficiario_rel r ON r.beneficiario_id = f.beneficiario_id
     JOIN public.grupos_beneficiarios g ON g.id = r.grupo_id WHERE g.codigo = 'GRP-CENTRAL-MOTOPREMIUM'
     AND f.operational_status = 'VIGENTE' LIMIT 1) AS fianza_admosa,
  (SELECT f.id FROM public.fianzas f JOIN public.grupo_beneficiario_rel r ON r.beneficiario_id = f.beneficiario_id
     JOIN public.grupos_beneficiarios g ON g.id = r.grupo_id WHERE g.codigo = 'GRP-UNIDADES-MOVILES'
     AND f.operational_status = 'VIGENTE' LIMIT 1) AS fianza_uma;
GRANT SELECT ON ctx TO authenticated;
UPDATE public.fianzas SET requiere_accesorio = true, accesorio_estado = 'PENDIENTE' WHERE id = (SELECT fianza_uma FROM ctx);

-- 1. La marca UMA solo ve UMA ------------------------------------------------
SELECT pg_temp.como('00000000-0000-4000-a000-000000000011');
SELECT pg_temp.ok((SELECT count(*) FROM public.v_fianzas) = (SELECT fianzas_uma FROM ctx), 'UMA ve solo su cartera');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.v_fianzas WHERE marca_id <> (SELECT uma FROM ctx)), 'UMA no ve fianzas de otra marca');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.v_distribuidores WHERE marca_id <> (SELECT uma FROM ctx)), 'UMA no ve distribuidores de otra marca');
SELECT pg_temp.ok((SELECT count(*) FROM public.grupos_beneficiarios) = 1, 'UMA solo conoce su propia marca');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.estados_cuenta_d6 WHERE grupo_id <> (SELECT uma FROM ctx)), 'UMA no ve estados de cuenta de otra marca');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.clientes c WHERE NOT EXISTS (
  SELECT 1 FROM public.v_fianzas f WHERE f.cliente_id = c.id)), 'UMA solo ve afianzados con fianza suya');
SELECT pg_temp.ok((SELECT NOT requiere_accesorio FROM public.v_fianzas WHERE id = (SELECT fianza_uma FROM ctx)),
  'la marca no ve el accesorio, que depende de lo que el distribuidor tiene con otras marcas');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.d6_cartera_por_marca() WHERE marca_id <> (SELECT uma FROM ctx)),
  'el resumen por marca de UMA solo trae UMA');

-- 2. Una marca que manda el encabezado de otra no gana nada ------------------
SELECT pg_temp.como('00000000-0000-4000-a000-000000000011', (SELECT admosa::text FROM ctx));
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.v_fianzas WHERE marca_id = (SELECT admosa FROM ctx)),
  'UMA con el encabezado de ADMOSA sigue sin ver ADMOSA');
SELECT pg_temp.ok((SELECT count(*) FROM public.v_fianzas) = (SELECT fianzas_uma FROM ctx), 'el encabezado se ignora para una marca');
SELECT pg_temp.ok((SELECT count(*) FROM public.d6_marcas_para_vista()) = 0, 'una marca no recibe la lista de marcas');
RESET role;

-- 3. El personal en modo reunion ve exactamente lo de UMA --------------------
SELECT pg_temp.como('00000000-0000-4000-a000-000000000001');
SELECT pg_temp.ok((SELECT count(*) FROM public.d6_marcas_para_vista()) >= 2, 'el personal elige entre todas las marcas');
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM public.v_fianzas WHERE marca_id = (SELECT admosa FROM ctx)), 'sin modo reunion el personal ve todas');
SELECT pg_temp.como('00000000-0000-4000-a000-000000000001', (SELECT uma::text FROM ctx));
SELECT pg_temp.ok((SELECT count(*) FROM public.v_fianzas) = (SELECT fianzas_uma FROM ctx), 'en reunion con UMA ve solo la cartera de UMA');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.v_fianzas WHERE marca_id <> (SELECT uma FROM ctx)), 'en reunion no aparece ADMOSA');
SELECT pg_temp.ok((SELECT count(*) FROM public.grupos_beneficiarios) = 1, 'en reunion solo existe la marca elegida');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.v_perfil_afianzados), 'en reunion no se ven perfiles de riesgo');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.v_bandeja_altas WHERE beneficiario_id NOT IN (
  SELECT beneficiario_id FROM public.grupo_beneficiario_rel WHERE grupo_id = (SELECT uma FROM ctx))), 'en reunion la bandeja de altas no trae otras marcas');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.v_solicitudes_alta_marca WHERE beneficiario_id NOT IN (
  SELECT beneficiario_id FROM public.grupo_beneficiario_rel WHERE grupo_id = (SELECT uma FROM ctx))), 'en reunion las altas son solo de UMA');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.estados_cuenta_d6 WHERE grupo_id <> (SELECT uma FROM ctx)), 'en reunion los estados de cuenta son solo de UMA');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.notificaciones), 'en reunion no se muestran notificaciones internas');
SELECT pg_temp.ok((SELECT NOT requiere_accesorio FROM public.v_fianzas WHERE id = (SELECT fianza_uma FROM ctx)), 'en reunion no se ve el accesorio');
SELECT pg_temp.falla_con('SELECT * FROM public.d6_cuadre_fiso()', 'en reunion no se abre el cuadre con FISO');
SELECT pg_temp.falla_con(format('SELECT * FROM public.d6_vinculados_cliente(%L)',
  (SELECT cliente_id FROM public.fianzas WHERE id = (SELECT fianza_uma FROM ctx))), 'en reunion no se ven vinculados');
SELECT pg_temp.falla_con(format('SELECT * FROM public.d6_historial_afianzado(%L)',
  (SELECT cliente_id FROM public.fianzas WHERE id = (SELECT fianza_uma FROM ctx))), 'en reunion no se ve la bitacora interna');
SELECT pg_temp.como('00000000-0000-4000-a000-000000000001', 'no-es-una-marca');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.v_fianzas), 'un encabezado invalido no muestra nada');
RESET role;

-- 4. Reglas que evitan mezclar ----------------------------------------------
SELECT pg_temp.falla_con(format($f$INSERT INTO public.user_grupos (user_id, grupo_id) VALUES ('00000000-0000-4000-a000-000000000011', %L)$f$,
  (SELECT admosa FROM ctx)), 'un usuario de UMA no puede pertenecer tambien a ADMOSA');
INSERT INTO public.solicitudes_alta (numero_solicitud, beneficiario_id, monto_solicitado, vigencia_desde, vigencia_hasta, estado_operativo, cliente_nombre_tmp)
SELECT 'ALT-PRUEBA-SEP', f.beneficiario_id, 100000, CURRENT_DATE, CURRENT_DATE + 365, 'EN_REVISION', 'Prueba'
FROM public.fianzas f WHERE f.id = (SELECT fianza_uma FROM ctx);
SELECT pg_temp.como('00000000-0000-4000-a000-000000000002');
SELECT pg_temp.falla_con(format($f$SELECT public.d6_vincular_fianza_anterior((SELECT id FROM public.solicitudes_alta WHERE numero_solicitud = 'ALT-PRUEBA-SEP'), %L, 'INCREMENTO')$f$,
  (SELECT fianza_admosa FROM ctx)), 'un alta de UMA no se vincula a una fianza de ADMOSA');
RESET role;

ROLLBACK;
