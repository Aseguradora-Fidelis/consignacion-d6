-- Reproduce los ataques de la auditoria del 2026-10-08 y comprueba que ya no funcionan.
-- Migraciones 036 a 040. Se revierte al final.
BEGIN;

CREATE OR REPLACE FUNCTION pg_temp.como(p_user UUID)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('role', 'authenticated', true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_user::text, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', '{}', true);
END;
$$;
CREATE OR REPLACE FUNCTION pg_temp.anonimo()
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('role', 'anon', true);
  PERFORM set_config('request.jwt.claims', '{"role":"anon"}', true);
  PERFORM set_config('request.headers', '{"user-agent":"Prueba/1.0","x-forwarded-for":"203.0.113.7, 10.0.0.1"}', true);
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
GRANT ALL ON ctx TO authenticated, anon;

SELECT pg_temp.ok(current_setting('TimeZone') = 'America/Guatemala',
  'la base trabaja en hora de Guatemala: lo emitido a las 23:00 queda con la fecha de ese dia');

-- 1. Correo y celular obligatorios -----------------------------------------------
SELECT pg_temp.como('00000000-0000-4000-a000-000000000011');
SELECT pg_temp.falla_con($f$SELECT * FROM public.d6_solicitar_alta(527613, 'Sin Celular', 'a@ejemplo.test', 100000)$f$,
  'el celular del distribuidor es obligatorio');
INSERT INTO ctx SELECT 'sol', solicitud_id::text FROM public.d6_solicitar_alta(527613, 'Distribuidor Remediacion', 'rem@ejemplo.test', 100000,
  'INDIVIDUAL', NULL, '5555-1212', 'NR-9', CURRENT_DATE);
SELECT pg_temp.ok((SELECT afianzado_telefono = '5555-1212' FROM public.v_solicitudes_alta_marca WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'sol')),
  'la marca ve el celular para abrir WhatsApp al reenviar');
INSERT INTO ctx SELECT 'token', token FROM public.crear_invitacion_ive((SELECT valor::uuid FROM ctx WHERE clave = 'sol'), NULL);
RESET role;

-- 2. Sin firma dibujada y con evidencia del envio --------------------------------
SELECT pg_temp.anonimo();
SELECT public.portal_ive_guardar_borrador((SELECT valor FROM ctx WHERE clave = 'token'),
  '{"primerNombre":"Distribuidor","firmaImagen":"data:image/png;base64,AAAA","declaracionVeracidad":true}');
RESET role;
SELECT pg_temp.ok((SELECT NOT (ive_borrador ? 'firmaImagen') AND NOT (ive_borrador ? 'declaracionVeracidad')
                   FROM public.solicitudes_alta WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'sol')),
  'el borrador no guarda firma ni declaracion');
SELECT pg_temp.anonimo();
SELECT public.completar_ive_invitacion((SELECT valor FROM ctx WHERE clave = 'token'),
  '{"tipoIve":"IVE-ASS-01","primerNombre":"DISTRIBUIDOR","primerApellido":"REMEDIACION","dpi":"1234567890101","nit":"1234567-8","telefono":"55551212","correo":"rem@ejemplo.test","fechaNacimiento":"1980-01-01","direccion":"Zona 1","municipio":"Guatemala","departamento":"Guatemala","nacionalidad":"Guatemalteca","profesion":"Comerciante","lugarTrabajo":"Negocio propio","cargoTrabajo":"Propietario","fuenteIngresos":"NEGOCIO_PROPIO","ingresosMensuales":"20000","egresosMensuales":"8000","estadoCivil":"Casado","esPEP":"NO","parientePEP":"NO","asociadoPEP":"NO","refNombre1":"Ref","refTelefono1":"55550000","declaracionVeracidad":true}');
RESET role;
SELECT pg_temp.ok((SELECT ive_envio_hash IS NOT NULL AND ive_envio_ip = '203.0.113.7' AND ive_envio_user_agent = 'Prueba/1.0'
                     AND ive_declaracion_version IS NOT NULL AND NOT (ive_data ? 'firmaImagen')
                   FROM public.solicitudes_alta WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'sol')),
  'el envio guarda huella, IP, navegador y version de la declaracion, sin imagen de firma');
INSERT INTO ctx SELECT 'hash', ive_envio_hash FROM public.solicitudes_alta WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'sol');
SELECT pg_temp.falla_con(
  $f$SELECT public.validar_datos_ive_d6('{"tipoIve":"IVE-ASS-01","primerNombre":"X","primerApellido":"Y","dpi":"1","nit":"1","telefono":"1","correo":"a@b.c","direccion":"x","municipio":"x","departamento":"x","nacionalidad":"x","profesion":"x","lugarTrabajo":"x","cargoTrabajo":"x","ingresosMensuales":"1","egresosMensuales":"1","estadoCivil":"x","refNombre1":"x","refTelefono1":"1","declaracionVeracidad":true}')$f$,
  'el servidor exige fecha de nacimiento, fuente de ingresos y las respuestas PEP');

-- 3. Ataque de la auditoria: la marca regenera el enlace y reescribe el IVE enviado --
SELECT pg_temp.como('00000000-0000-4000-a000-000000000011');
UPDATE ctx SET valor = (SELECT token FROM public.crear_invitacion_ive((SELECT valor::uuid FROM ctx WHERE clave = 'sol'), NULL))
WHERE clave = 'token';
RESET role;
SELECT pg_temp.anonimo();
SELECT pg_temp.ok((SELECT (c->>'solo_documentos')::boolean AND c->'borrador' = '{}'::jsonb
                   FROM (SELECT public.portal_ive_contexto((SELECT valor FROM ctx WHERE clave = 'token')) c) x),
  'ya enviado, el enlace no devuelve el formulario: solo pide documentos');
SELECT pg_temp.falla_con(
  format($f$SELECT public.portal_ive_guardar_borrador(%L, '{"ingresosMensuales":"1"}')$f$, (SELECT valor FROM ctx WHERE clave = 'token')),
  'ya enviado, el borrador no se reescribe');
SELECT public.completar_ive_invitacion((SELECT valor FROM ctx WHERE clave = 'token'),
  '{"tipoIve":"IVE-ASS-01","ingresosMensuales":"1","declaracionVeracidad":true}');
RESET role;
SELECT pg_temp.ok((SELECT ive_data->>'ingresosMensuales' = '20000' AND ive_envio_hash = (SELECT valor FROM ctx WHERE clave = 'hash')
                   FROM public.solicitudes_alta WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'sol')),
  'el IVE jurado no cambia aunque se reenvie con el enlace nuevo');
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM public.solicitud_revisiones WHERE solicitud_alta_id = (SELECT valor::uuid FROM ctx WHERE clave = 'sol')
                            AND comentario LIKE 'Documentos subidos%')
                  AND NOT EXISTS (SELECT 1 FROM public.solicitud_revisiones WHERE solicitud_alta_id = (SELECT valor::uuid FROM ctx WHERE clave = 'sol')
                            AND comentario LIKE '%actualizó%'),
  'la bitacora no atribuye cambios del IVE al distribuidor');

-- 4. Ataque de la auditoria: un anonimo deduce la exposicion con otras marcas ------
SELECT pg_temp.anonimo();
SELECT pg_temp.falla_con(
  $f$SELECT public.d6_requiere_documento_accesorio((SELECT id FROM public.clientes LIMIT 1), 1)$f$,
  'un anonimo no ejecuta la regla del accesorio');
SELECT pg_temp.falla_con($f$SELECT public.get_user_role('00000000-0000-4000-a000-000000000001')$f$,
  'un anonimo no consulta el rol de otro usuario');
RESET role;
SELECT pg_temp.como('00000000-0000-4000-a000-000000000011');
SELECT pg_temp.falla_con(
  $f$SELECT public.d6_requiere_documento_accesorio((SELECT id FROM public.clientes LIMIT 1), 1)$f$,
  'una marca tampoco');
RESET role;

-- 4b. El enlace del IVE solo sirve para llenar la solicitud (042) ---------------------
SELECT pg_temp.ok(
  (SELECT array_agg(p.proname ORDER BY p.proname) FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
     AND has_function_privilege('anon', p.oid, 'EXECUTE'))
  = ARRAY['completar_ive_invitacion', 'portal_ive_confirmar_carga', 'portal_ive_contexto', 'portal_ive_guardar_borrador',
          'portal_ive_preparar_carga', 'portal_ive_quitar_documento']::name[],
  'por la API, el enlace solo ejecuta las 6 funciones del portal');
SELECT pg_temp.ok(
  NOT EXISTS (SELECT 1 FROM pg_class c WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'v', 'm', 'S', 'p')
              AND (has_table_privilege('anon', c.oid, 'SELECT') OR has_table_privilege('anon', c.oid, 'INSERT')
                   OR has_table_privilege('anon', c.oid, 'UPDATE') OR has_table_privilege('anon', c.oid, 'DELETE')
                   OR (c.relkind = 'S' AND has_sequence_privilege('anon', c.oid, 'USAGE')))),
  'el enlace no tiene permiso sobre ninguna tabla, vista ni secuencia');
SELECT pg_temp.ok(
  NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname IN ('public', 'storage') AND 'anon' = ANY (roles) AND cmd <> 'INSERT')
  AND NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'storage' AND tablename = 'objects'
                  AND ('anon' = ANY (roles) OR 'public' = ANY (roles))
                  AND policyname <> 'expedientes: afianzado sube a ruta reservada'),
  'en Storage el enlace solo sube a la ruta que reservo su solicitud');
SELECT pg_temp.anonimo();
SELECT pg_temp.falla_con($f$SELECT count(*) FROM public.solicitudes_alta$f$, 'el enlace no lee solicitudes');
SELECT pg_temp.falla_con($f$SELECT count(*) FROM public.v_fianzas$f$, 'ni la cartera');
SELECT pg_temp.falla_con($f$SELECT count(*) FROM public.ive_requisitos_d6$f$, 'ni los catalogos');
SELECT pg_temp.falla_con($f$SELECT public.d6_alta_compartida((SELECT valor::uuid FROM ctx WHERE clave = 'sol'))$f$,
  'ni las funciones de la marca');
SELECT pg_temp.falla_con($f$SELECT public.portal_ive_contexto('token-inventado')->>'valido' = 'true' OR public.completar_ive_invitacion('token-inventado', '{}') IS NULL$f$,
  'un token inventado no llena nada');
RESET role;
-- Con el enlace de una solicitud no se toca un documento de otra.
INSERT INTO ctx SELECT 'doc_otra', d.id::text FROM public.documentos d
WHERE d.solicitud_alta_id <> (SELECT valor::uuid FROM ctx WHERE clave = 'sol') LIMIT 1;
INSERT INTO ctx SELECT 'doc_otra', '00000000-0000-4000-c000-000000000001' WHERE NOT EXISTS (SELECT 1 FROM ctx WHERE clave = 'doc_otra');
SELECT pg_temp.anonimo();
SELECT pg_temp.falla_con(
  format($f$SELECT public.portal_ive_quitar_documento(%L, %L)$f$, (SELECT valor FROM ctx WHERE clave = 'token'), (SELECT valor FROM ctx WHERE clave = 'doc_otra')),
  'con el enlace de una solicitud no se retira un documento de otra');
RESET role;

-- 4c. La marca edita la solicitud de su distribuidor, con registro (042) --------------
SELECT pg_temp.como('00000000-0000-4000-a000-000000000011');
SELECT pg_temp.ok((SELECT (public.d6_alta_compartida((SELECT valor::uuid FROM ctx WHERE clave = 'sol'))->>'editable')::boolean),
  'ya enviada, la marca todavia puede editar la solicitud');
SELECT public.d6_alta_guardar_borrador((SELECT valor::uuid FROM ctx WHERE clave = 'sol'), '{"profesion":"Comerciante de motos","firmaImagen":"x"}');
SELECT pg_temp.falla_con(
  format($f$SELECT public.d6_alta_guardar_borrador(%L, '{"dpi":""}')$f$, (SELECT valor FROM ctx WHERE clave = 'sol')),
  'una edicion no deja incompleto el formulario enviado');
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM public.d6_alta_cambios((SELECT valor::uuid FROM ctx WHERE clave = 'sol'))
                          WHERE campo = 'profesion' AND quien = 'marca@uma.test' AND origen = 'MARCA' AND etapa = 'ENVIADA'
                            AND antes = '"Comerciante"' AND despues = '"Comerciante de motos"'),
  'el cambio queda registrado con quien, antes y despues');
RESET role;
SELECT pg_temp.ok((SELECT ive_data->>'profesion' = 'Comerciante de motos' AND NOT (ive_data ? 'firmaImagen')
                     AND ive_envio_hash = (SELECT valor FROM ctx WHERE clave = 'hash')
                   FROM public.solicitudes_alta WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'sol')),
  'la edicion cambia el formulario y conserva la huella de lo que envio el distribuidor');
SELECT pg_temp.falla_con($f$DELETE FROM public.alta_cambios_d6 WHERE true$f$, 'el registro de cambios no se borra');
SELECT pg_temp.como('00000000-0000-4000-a000-000000000012');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.d6_alta_cambios((SELECT valor::uuid FROM ctx WHERE clave = 'sol'))),
  'otra marca no ve el registro de cambios');
SELECT pg_temp.falla_con(
  format($f$SELECT public.d6_alta_guardar_borrador(%L, '{"profesion":"x"}')$f$, (SELECT valor FROM ctx WHERE clave = 'sol')),
  'ni edita la solicitud');
RESET role;

-- 5. Ataque de la auditoria: escritura directa sin RPC ---------------------------
SELECT pg_temp.como('00000000-0000-4000-a000-000000000003');
UPDATE public.solicitudes_alta SET estado_operativo = 'APROBADA_TOTAL' WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'sol');
RESET role;
SELECT pg_temp.ok((SELECT estado_operativo <> 'APROBADA_TOTAL' FROM public.solicitudes_alta WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'sol')),
  'Comercial no aprueba un expediente con un UPDATE directo');
INSERT INTO ctx SELECT 'fz', id::text FROM public.fianzas ORDER BY fianza LIMIT 1;
SELECT pg_temp.como('00000000-0000-4000-a000-000000000002');
UPDATE public.fianzas SET derechos = -5 WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'fz');
DELETE FROM public.fianzas WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'fz');
RESET role;
SELECT pg_temp.ok((SELECT derechos >= 0 FROM public.fianzas WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'fz')),
  'Suscripcion no pone derechos negativos ni borra fianzas con un UPDATE directo');
SELECT pg_temp.como('00000000-0000-4000-a000-000000000002');
UPDATE public.documentos SET revisado_por = '00000000-0000-4000-a000-000000000003'
WHERE solicitud_alta_id = (SELECT valor::uuid FROM ctx WHERE clave = 'sol');
RESET role;
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.documentos WHERE solicitud_alta_id = (SELECT valor::uuid FROM ctx WHERE clave = 'sol')
                              AND revisado_por = '00000000-0000-4000-a000-000000000003'),
  'nadie pone a otro como revisor de un documento');

-- 6. Conservacion: nada se borra en cascada ---------------------------------------
SELECT pg_temp.falla_con(
  format($f$DELETE FROM public.solicitudes_alta WHERE id = %L$f$, (SELECT valor FROM ctx WHERE clave = 'sol')),
  'un expediente con historial no se borra ni siquiera como dueño de la base');

-- 7. Bitacora ----------------------------------------------------------------------
INSERT INTO ctx SELECT 'antes', count(*)::text FROM public.audit_log WHERE table_name = 'fianzas';
UPDATE public.fianzas SET prima = prima WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'fz');
SELECT pg_temp.ok((SELECT count(*) FROM public.audit_log WHERE table_name = 'fianzas') = (SELECT valor::bigint FROM ctx WHERE clave = 'antes'),
  'un UPDATE que no cambia nada no deja fila en la bitacora');
UPDATE public.fianzas SET tema_de_fianza = 'Cambio de prueba' WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'fz');
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM public.audit_log WHERE table_name = 'fianzas'
                            AND record_id = (SELECT valor::uuid FROM ctx WHERE clave = 'fz')
                            AND new_data = '{"tema_de_fianza":"Cambio de prueba"}'::jsonb),
  'la bitacora guarda solo lo que cambio');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.audit_log WHERE table_name = 'solicitudes_alta'
                              AND record_id = (SELECT valor::uuid FROM ctx WHERE clave = 'sol')
                              AND (new_data ? 'ive_borrador' OR new_data->'ive_data' ? 'dpi')),
  'la bitacora no copia el borrador ni el IVE, solo su huella');
SELECT pg_temp.como('00000000-0000-4000-a000-000000000001');
INSERT INTO public.user_role_assignments (user_id, role) VALUES ('00000000-0000-4000-a000-000000000005', 'cobros');
RESET role;
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM public.audit_log WHERE table_name = 'user_role_assignments' AND action = 'INSERT'
                          AND performed_by = '00000000-0000-4000-a000-000000000001' AND origen = 'USUARIO'),
  'dar un rol queda en la bitacora con quien lo dio');
SELECT pg_temp.falla_con($f$DELETE FROM public.audit_log WHERE true$f$, 'la bitacora no se borra');
SELECT pg_temp.falla_con($f$UPDATE public.audit_log SET action = 'X' WHERE true$f$, 'la bitacora no se edita');

-- 8. Usuarios desactivados -----------------------------------------------------------
SELECT pg_temp.como('00000000-0000-4000-a000-000000000001');
SELECT public.d6_desactivar_usuario('00000000-0000-4000-a000-000000000004');
RESET role;
SELECT pg_temp.como('00000000-0000-4000-a000-000000000004');
SELECT pg_temp.ok(NOT public.has_d6_role(ARRAY['cobros']::public.d6_role[]), 'un usuario desactivado pierde sus permisos');
SELECT pg_temp.falla_con($f$UPDATE public.user_profiles SET activo = true WHERE id = auth.uid()$f$,
  'nadie se reactiva a si mismo');
RESET role;

-- 9. Emision: la prima no la escribe el navegador ------------------------------------
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname IN ('emitir_fianza_d6', 'd6_registrar_pago', 'd6_conciliar_pago', 'd6_registrar_lote_fiso')),
  'la app no captura emisiones ni pagos: vienen de FISO');

-- 10. Sin correos desde la app: los avisos de cobro los manda FISO (044) ---------------
SELECT pg_temp.ok(to_regclass('public.correos_salida_d6') IS NULL
                  AND NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname IN ('trg_correo_por_revision', 'trg_correo_por_rechazo', 'trg_correo_por_estado_cuenta'))
                  AND NOT EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'public'::regnamespace
                                  AND proname IN ('d6_encolar_correo', 'd6_correos_por_enviar', 'd6_correo_resultado',
                                                  'd6_correo_por_revision', 'd6_correo_por_rechazo', 'd6_correo_por_estado_cuenta')),
  'la app no encola correos: no hay bandeja de salida ni disparadores de correo');
-- Los avisos quedan dentro de la app y solo para la marca de la solicitud.
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM public.notificaciones WHERE user_id = '00000000-0000-4000-a000-000000000011'
                          AND link = '/altas/' || (SELECT valor FROM ctx WHERE clave = 'sol'))
                  AND NOT EXISTS (SELECT 1 FROM public.notificaciones WHERE user_id = '00000000-0000-4000-a000-000000000012'
                          AND link = '/altas/' || (SELECT valor FROM ctx WHERE clave = 'sol')),
  'el aviso del envio llega a la marca y no a otra marca');

-- 11. Sin segundo paso (042) -----------------------------------------------------------
SELECT set_config('role', 'authenticated', true),
       set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-000000000002","role":"authenticated","aal":"aal1"}', true);
SELECT pg_temp.ok(public.has_d6_role(ARRAY['suscripcion']::public.d6_role[]), 'el personal entra sin segundo paso');
RESET role;

ROLLBACK;
