-- Pruebas de la migracion 020 sobre los datos de supabase/seed.sql.
-- Todo corre dentro de una transaccion que se revierte: no deja datos.
-- Uso: npm run test:db  (requiere supabase start y supabase db reset)

BEGIN;

CREATE OR REPLACE FUNCTION pg_temp.como(p_user UUID)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('role', 'authenticated', true);
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', p_user::text, 'role', 'authenticated')::text, true);
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.ok(p_cond BOOLEAN, p_msg TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  IF p_cond IS NOT TRUE THEN
    RAISE EXCEPTION 'FALLA: %', p_msg;
  END IF;
  RAISE NOTICE 'ok: %', p_msg;
END;
$$;

-- IDs del seed
-- admin 01, suscripcion 02, comercial 03, cobros 04, consulta 05
-- marca UMA 11, marca ADMOSA 12, marca Honda 13

-- 1. Una marca solo ve su cartera ------------------------------------------
SELECT pg_temp.como('00000000-0000-4000-a000-000000000011');
SELECT pg_temp.ok(
  (SELECT count(*) FROM public.fianzas) > 0
  AND NOT EXISTS (
    SELECT 1 FROM public.fianzas f JOIN public.beneficiarios b ON b.id = f.beneficiario_id
    WHERE b.codigo_contacto <> 527613
  ),
  'la marca UMA ve solo polizas de UMA');
SELECT pg_temp.ok(
  NOT EXISTS (SELECT 1 FROM public.beneficiarios WHERE codigo_contacto <> 527613),
  'la marca UMA no ve otros beneficiarios');
SELECT pg_temp.ok(
  (SELECT count(*) FROM public.get_user_beneficiario_ids('00000000-0000-4000-a000-000000000012')) = 0,
  'una marca no puede consultar las marcas de otro usuario');
RESET role;

-- 2. Honda y Suzuki ya no comparten grupo -----------------------------------
SELECT pg_temp.como('00000000-0000-4000-a000-000000000013');
SELECT pg_temp.ok(
  NOT EXISTS (SELECT 1 FROM public.beneficiarios WHERE nombre ILIKE '%SUZUKI%'),
  'la marca Honda no ve beneficiarios de Suzuki');
RESET role;

-- 3. Una marca no aprueba sus propias bajas ---------------------------------
SELECT pg_temp.como('00000000-0000-4000-a000-000000000011');
CREATE TEMP TABLE baja_uma ON COMMIT DROP AS
SELECT * FROM public.d6_solicitar_baja(
  (SELECT id FROM public.fianzas WHERE operational_status = 'VIGENTE' LIMIT 1), 'DEVOLUCION_MERCADERIA', 'Prueba');
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM public.solicitudes_baja WHERE id = (SELECT baja_id FROM baja_uma)),
  'la marca pide una baja de su cartera');
UPDATE public.solicitudes_baja SET estado = 'APROBADA' WHERE id = (SELECT baja_id FROM baja_uma);
SELECT pg_temp.ok(
  (SELECT estado FROM public.solicitudes_baja WHERE id = (SELECT baja_id FROM baja_uma)) = 'PENDIENTE_REVISION',
  'la marca no puede aprobar su propia baja');
DO $$
BEGIN
  BEGIN
    INSERT INTO public.solicitudes_baja (numero_solicitud, fianza_id, tipo_baja, motivo, estado, solicitado_por)
    SELECT 'BAJ-PRUEBA-2', f.id, 'OTRO', 'Prueba', 'PENDIENTE_REVISION', auth.uid() FROM public.fianzas f LIMIT 1;
    RAISE EXCEPTION 'FALLA: la marca inserto una baja sin pasar por la RPC';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'ok: la marca solo pide bajas por la RPC';
  END;
END $$;
DO $$
BEGIN
  DELETE FROM public.solicitudes_baja WHERE id = (SELECT baja_id FROM baja_uma);
  IF NOT EXISTS (SELECT 1 FROM public.solicitudes_baja WHERE id = (SELECT baja_id FROM baja_uma)) THEN
    RAISE EXCEPTION 'FALLA: la marca borro su baja';
  END IF;
  RAISE NOTICE 'ok: la marca no borra su baja: la procesa FISO';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'ok: la marca no borra su baja: la procesa FISO';
END $$;
RESET role;

SELECT pg_temp.como('00000000-0000-4000-a000-000000000012');
DO $$
DECLARE v_fianza UUID;
BEGIN
  SELECT f.id INTO v_fianza FROM public.fianzas f JOIN public.beneficiarios b ON b.id = f.beneficiario_id
  WHERE b.codigo_contacto = 527613 LIMIT 1;
  IF v_fianza IS NOT NULL THEN
    RAISE EXCEPTION 'FALLA: ADMOSA ve polizas de UMA';
  END IF;
  RAISE NOTICE 'ok: una marca no ve polizas de otra marca para pedir su baja';
END $$;
RESET role;

-- 4. La marca pide un alta y no lee el IVE ----------------------------------
SELECT pg_temp.como('00000000-0000-4000-a000-000000000011');
CREATE TEMP TABLE alta_uma ON COMMIT DROP AS
SELECT * FROM public.d6_solicitar_alta(
  527613, 'AFIANZADO NUEVO DE PRUEBA', 'nuevo@ejemplo.test', 150000, 'INDIVIDUAL', '9999999-1', '55550002');
SELECT pg_temp.ok((SELECT count(*) FROM alta_uma) = 1, 'la marca crea su solicitud de alta');
SELECT pg_temp.ok((SELECT count(*) FROM public.solicitudes_alta) = 0,
  'la marca no lee la tabla solicitudes_alta (contiene ive_data)');
SELECT pg_temp.ok(
  EXISTS (SELECT 1 FROM public.v_solicitudes_alta_marca v JOIN alta_uma a ON a.solicitud_id = v.id),
  'la marca ve su alta en la vista sin datos IVE');
DO $$
BEGIN
  BEGIN
    PERFORM * FROM public.d6_solicitar_alta(397637, 'OTRO', 'otro@ejemplo.test', 100000, 'INDIVIDUAL', NULL, '55550003');
    RAISE EXCEPTION 'FALLA: UMA pidio un alta para Motopremium';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'FALLA%' THEN RAISE; END IF;
    RAISE NOTICE 'ok: una marca no pide altas para otra marca';
  END;
END $$;
RESET role;

-- Reutilizar un afianzado de otra marca por NIT no le da acceso a sus datos.
DO $$
DECLARE v_nit TEXT;
BEGIN
  -- Un afianzado que solo tiene polizas con UMA.
  SELECT c.nit INTO v_nit FROM public.clientes c
  WHERE EXISTS (SELECT 1 FROM public.fianzas f JOIN public.beneficiarios b ON b.id = f.beneficiario_id
                WHERE f.cliente_id = c.id AND b.codigo_contacto = 527613)
    AND NOT EXISTS (SELECT 1 FROM public.fianzas f JOIN public.beneficiarios b ON b.id = f.beneficiario_id
                WHERE f.cliente_id = c.id AND b.codigo_contacto = 16818)
  LIMIT 1;
  PERFORM set_config('test.nit_uma', v_nit, true);
END $$;
SELECT pg_temp.como('00000000-0000-4000-a000-000000000013');
SELECT count(*) FROM public.d6_solicitar_alta(
  16818, 'NOMBRE QUE ESCRIBIO HONDA', 'x@ejemplo.test', 100000, 'INDIVIDUAL', current_setting('test.nit_uma'), '55550004');
SELECT pg_temp.ok(
  NOT EXISTS (SELECT 1 FROM public.clientes WHERE nit = current_setting('test.nit_uma')),
  'reutilizar por NIT un afianzado de UMA no expone sus datos a Honda');
SELECT pg_temp.ok(
  EXISTS (SELECT 1 FROM public.v_solicitudes_alta_marca WHERE afianzado_nombre = 'NOMBRE QUE ESCRIBIO HONDA'),
  'Honda ve el nombre que ella misma escribio');
RESET role;

-- 5. Portal IVE: un expediente ya emitido en FISO no se reabre --------------
UPDATE public.solicitudes_alta SET estado_operativo = 'EMITIDA'
WHERE id = (SELECT solicitud_id FROM alta_uma);
SELECT pg_temp.como('00000000-0000-4000-a000-000000000011');
DO $$
BEGIN
  BEGIN
    PERFORM * FROM public.crear_invitacion_ive((SELECT solicitud_id FROM alta_uma), 'nuevo@ejemplo.test');
    RAISE EXCEPTION 'FALLA: se emitio un enlace IVE con el expediente emitido';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'FALLA%' THEN RAISE; END IF;
    RAISE NOTICE 'ok: no se emite enlace IVE con el expediente emitido';
  END;
END $$;
RESET role;
SELECT set_config('test.token', (SELECT ive_token FROM alta_uma), true);
SELECT set_config('request.jwt.claims', '{"role":"anon"}', true);
SET LOCAL role anon;
DO $$
BEGIN
  BEGIN
    PERFORM public.completar_ive_invitacion(current_setting('test.token'), '{"tipoIve":"IVE-ASS-01"}'::jsonb);
    RAISE EXCEPTION 'FALLA: el afianzado sobrescribio un expediente emitido';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'FALLA%' THEN RAISE; END IF;
    RAISE NOTICE 'ok: el token no reabre un expediente emitido (%)', SQLERRM;
  END;
END $$;
RESET role;

-- 6. Nadie se da a si mismo mas permisos -----------------------------------
SELECT pg_temp.como('00000000-0000-4000-a000-000000000002');
DO $$
BEGIN
  BEGIN
    UPDATE public.user_profiles SET role = 'admin' WHERE id = auth.uid();
    RAISE EXCEPTION 'FALLA: suscripcion se promovio a admin';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'FALLA%' THEN RAISE; END IF;
    RAISE NOTICE 'ok: un usuario no cambia su propio rol';
  END;
END $$;
DO $$
BEGIN
  BEGIN
    INSERT INTO public.user_role_assignments (user_id, role) VALUES (auth.uid(), 'admin');
    RAISE EXCEPTION 'FALLA: suscripcion se asigno el rol admin';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'ok: un usuario no se asigna roles';
  END;
END $$;
RESET role;

-- Un alta de usuario que pide role=admin en la metadata nace sin permisos.
INSERT INTO auth.users (instance_id, id, aud, role, email, raw_user_meta_data, created_at, updated_at)
VALUES ('00000000-0000-0000-0000-000000000000', '00000000-0000-4000-a000-0000000000ff',
        'authenticated', 'authenticated', 'intruso@ejemplo.test',
        '{"role":"admin","full_name":"Intruso"}'::jsonb, now(), now());
SELECT pg_temp.ok(
  (SELECT role FROM public.user_profiles WHERE id = '00000000-0000-4000-a000-0000000000ff') = 'beneficiario',
  'el rol de la metadata del registro se ignora');
SELECT pg_temp.como('00000000-0000-4000-a000-0000000000ff');
SELECT pg_temp.ok((SELECT count(*) FROM public.fianzas) = 0, 'un usuario sin marcas no ve polizas');
SELECT pg_temp.ok(NOT public.d6_es_personal_aseguradora(), 'un usuario nuevo no es personal');
RESET role;

-- 7. El rol consulta lee pero no escribe ------------------------------------
CREATE TEMP TABLE total_fianzas AS SELECT count(*) AS n FROM public.fianzas;
GRANT SELECT ON total_fianzas TO authenticated;
SELECT pg_temp.como('00000000-0000-4000-a000-000000000005');
SELECT pg_temp.ok((SELECT count(*) FROM public.fianzas) = (SELECT n FROM total_fianzas), 'consulta ve toda la cartera');
UPDATE public.fianzas SET monto_afianzado = 1 WHERE true;
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.fianzas WHERE monto_afianzado = 1),
  'consulta no modifica polizas');
RESET role;

-- 8. Anonimo no ve nada ------------------------------------------------------
SELECT set_config('request.jwt.claims', '{"role":"anon"}', true);
SET LOCAL role anon;
-- Desde la 042 el enlace del IVE no tiene permiso sobre ninguna tabla: la consulta falla.
DO $$
BEGIN
  BEGIN
    PERFORM 1 FROM public.fianzas;
    RAISE EXCEPTION 'FALLA: anonimo consulta polizas';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'ok: anonimo no ve polizas';
  END;
  BEGIN
    PERFORM 1 FROM public.clientes;
    RAISE EXCEPTION 'FALLA: anonimo consulta afianzados';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'ok: anonimo no ve afianzados';
  END;
END $$;
DO $$
BEGIN
  BEGIN
    PERFORM 1 FROM public.v_solicitudes_alta_marca;
    RAISE EXCEPTION 'FALLA: anonimo consulta la vista de altas';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'ok: anonimo no consulta la vista de altas';
  END;
END $$;
RESET role;

-- 9. El personal de Fidelis consulta, no trabaja en la app (044) ------------
-- Las funciones con que el equipo decidia, revisaba, vinculaba o cobraba ya no existen.
DO $$
DECLARE v_quedan TEXT;
BEGIN
  SELECT string_agg(proname, ', ') INTO v_quedan FROM pg_proc
  WHERE pronamespace = 'public'::regnamespace AND proname IN (
    'transicionar_solicitud_alta', 'd6_revisar_documento', 'd6_guardar_analisis', 'd6_vincular_emision_fiso',
    'd6_candidatos_emision', 'd6_registrar_accesorio', 'd6_registrar_entrega', 'd6_resolver_baja', 'd6_cerrar_baja',
    'd6_anulaciones_mes', 'd6_marcar_anulaciones_enviadas', 'd6_avanzar_reclamo', 'd6_generar_estado_cuenta',
    'd6_enviar_estado_cuenta', 'd6_transiciones_alta');
  IF v_quedan IS NOT NULL THEN RAISE EXCEPTION 'FALLA: siguen las funciones del equipo: %', v_quedan; END IF;
  RAISE NOTICE 'ok: no quedan funciones para decidir, revisar, vincular, entregar, resolver bajas, avanzar reclamos ni generar cobros';
END $$;
-- Y el vinculo automatico con FISO solo lo corre la carga.
SELECT pg_temp.ok(NOT has_function_privilege('authenticated', 'public.d6_vincular_emisiones_fiso()', 'EXECUTE')
                  AND NOT has_function_privilege('authenticated', 'public.d6_aplicar_cartera_fiso(uuid)', 'EXECUTE'),
  'ningun usuario ejecuta el vinculo con FISO: solo la carga');

CREATE TEMP TABLE totales AS
SELECT (SELECT count(*) FROM public.solicitudes_alta) AS solicitudes,
       (SELECT count(*) FROM public.documentos) AS documentos,
       (SELECT count(*) FROM public.v_cuenta_marca) AS cuenta,
       (SELECT count(*) FROM public.condiciones_marca_d6) AS condiciones,
       (SELECT md5(string_agg(c::text, '' ORDER BY c.grupo_id)) FROM public.condiciones_marca_d6 c) AS condiciones_huella,
       (SELECT count(*) FROM public.comunicaciones_d6) AS comunicaciones;
GRANT SELECT ON totales TO authenticated;
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public'
                              AND tablename IN ('condiciones_marca_d6', 'comunicaciones_d6') AND cmd <> 'SELECT'),
  'condiciones y bitacora de llamadas quedan solo de lectura');

SELECT pg_temp.como('00000000-0000-4000-a000-000000000002');
SELECT pg_temp.ok((SELECT count(*) FROM public.solicitudes_alta) = (SELECT solicitudes FROM totales)
                  AND (SELECT solicitudes FROM totales) > 0,
  'Suscripcion lee todas las solicitudes');
SELECT pg_temp.ok((SELECT count(*) FROM public.documentos) = (SELECT documentos FROM totales),
  'Suscripcion lee todos los documentos');
-- En una base recien creada no hay facturas de FISO: la cuenta puede estar vacia.
SELECT pg_temp.ok((SELECT count(*) FROM public.v_cuenta_marca) = (SELECT cuenta FROM totales),
  'Suscripcion lee la cuenta de todas las marcas');
SELECT pg_temp.ok((SELECT count(*) FROM public.d6_cuadre_fiso()) >= 0, 'Suscripcion consulta el cuadre con FISO');
DO $$
BEGIN
  BEGIN
    INSERT INTO public.condiciones_marca_d6 (grupo_id) SELECT id FROM public.grupos_beneficiarios LIMIT 1;
    RAISE EXCEPTION 'FALLA: Suscripcion escribio condiciones de marca';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'ok: Suscripcion no agrega condiciones de marca';
  END;
  BEGIN
    INSERT INTO public.comunicaciones_d6 (cliente_id, canal, asunto, registrada_por)
    SELECT id, 'NOTA', 'Llamada', auth.uid() FROM public.clientes LIMIT 1;
    RAISE EXCEPTION 'FALLA: Suscripcion registro una llamada';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'ok: Suscripcion no registra llamadas en la bitacora';
  END;
END $$;
UPDATE public.condiciones_marca_d6 SET forma_pago = 'CREDITO' WHERE true;
DELETE FROM public.condiciones_marca_d6 WHERE true;
UPDATE public.comunicaciones_d6 SET asunto = 'cambiado' WHERE true;
DELETE FROM public.comunicaciones_d6 WHERE true;
RESET role;
SELECT pg_temp.ok((SELECT count(*) FROM public.condiciones_marca_d6) = (SELECT condiciones FROM totales)
                  AND (SELECT md5(string_agg(c::text, '' ORDER BY c.grupo_id)) FROM public.condiciones_marca_d6 c)
                      IS NOT DISTINCT FROM (SELECT condiciones_huella FROM totales),
  'Suscripcion no cambia ni borra condiciones de marca');
SELECT pg_temp.ok((SELECT count(*) FROM public.comunicaciones_d6) = (SELECT comunicaciones FROM totales)
                  AND NOT EXISTS (SELECT 1 FROM public.comunicaciones_d6 WHERE asunto = 'cambiado'),
  'ni edita ni borra la bitacora de llamadas');

ROLLBACK;
