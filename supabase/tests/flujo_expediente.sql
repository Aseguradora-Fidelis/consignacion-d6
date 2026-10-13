-- Recorrido completo de un alta y una baja sobre los datos de supabase/seed.sql (migracion 044).
-- marca pide -> el distribuidor llena el IVE y sube el expediente -> queda recibido y lo que
-- falta se recalcula solo -> la carga de FISO trae la fianza y la solicitud queda emitida ->
-- la marca ve la poliza y pide la baja -> FISO la cancela. Fidelis solo consulta.
-- Todo se revierte al final.

BEGIN;

CREATE OR REPLACE FUNCTION pg_temp.como(p_user UUID)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('role', 'authenticated', true);
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', p_user::text, 'role', 'authenticated')::text, true);
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.anonimo()
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', '{"role":"anon"}', true);
  PERFORM set_config('role', 'anon', true);
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

CREATE OR REPLACE FUNCTION pg_temp.falla_con(p_sql TEXT, p_msg TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'ok: % (%)', p_msg, SQLERRM;
    RETURN;
  END;
  RAISE EXCEPTION 'FALLA: %', p_msg;
END;
$$;

CREATE TEMP TABLE ctx (clave TEXT PRIMARY KEY, valor TEXT);
GRANT ALL ON ctx TO anon, authenticated;

-- 1. La marca UMA pide el alta con su resolucion ----------------------------
SELECT pg_temp.como('00000000-0000-4000-a000-000000000011');
INSERT INTO ctx
SELECT 'solicitud', solicitud_id::text FROM public.d6_solicitar_alta(
  527613, 'JUAN CARLOS PRUEBA FLUJO', 'flujo@ejemplo.test', 120000, 'INDIVIDUAL', '7777777-7', '55551234',
  'RES-0001', CURRENT_DATE - 3, 150000, 90, NULL);
SELECT pg_temp.falla_con(
  $$SELECT * FROM public.d6_solicitar_alta(527613, 'X', 'x@ejemplo.test', 200000, 'INDIVIDUAL', NULL, '55550001', 'R', CURRENT_DATE, 150000)$$,
  'no se pide mas que el limite aprobado por la marca');
-- Para el resto de la prueba hace falta el token en claro: la marca genera uno nuevo.
INSERT INTO ctx SELECT 'token', token FROM public.crear_invitacion_ive(
  (SELECT valor::uuid FROM ctx WHERE clave = 'solicitud'), NULL);
RESET role;

SELECT pg_temp.ok(
  (SELECT estado_operativo FROM public.solicitudes_alta WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'solicitud')) = 'IVE_PENDIENTE',
  'la solicitud nace en IVE pendiente');

-- 2. El afianzado abre el portal ---------------------------------------------
SELECT pg_temp.anonimo();
SELECT pg_temp.ok(
  (public.portal_ive_contexto((SELECT valor FROM ctx WHERE clave = 'token'))->>'valido')::boolean,
  'el portal reconoce el enlace');
SELECT pg_temp.ok(
  jsonb_array_length(public.portal_ive_contexto((SELECT valor FROM ctx WHERE clave = 'token'))->'requisitos') >= 7,
  'el portal lista los documentos del expediente individual');
SELECT pg_temp.ok(
  (public.portal_ive_contexto('token-inventado')->>'motivo') = 'NO_EXISTE',
  'un enlace inventado no abre nada');
SELECT public.portal_ive_guardar_borrador((SELECT valor FROM ctx WHERE clave = 'token'), '{"primerNombre":"JUAN"}');
SELECT pg_temp.ok(
  public.portal_ive_contexto((SELECT valor FROM ctx WHERE clave = 'token'))->'borrador'->>'primerNombre' = 'JUAN',
  'el borrador queda guardado en el servidor');

-- Antes de subir, los documentos del distribuidor aparecen como pendientes (enviar no lo impide).
RESET role;
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM public.d6_documentos_faltantes((SELECT valor::uuid FROM ctx WHERE clave = 'solicitud'), true)),
  'sin documentos, quedan pendientes');
SELECT pg_temp.anonimo();

-- Sube cada documento obligatorio por el flujo de carga en dos pasos, menos el estado de
-- cuenta, que el distribuidor manda despues de enviar.
DO $$
DECLARE
  r RECORD;
  v_reserva JSONB;
  v_token TEXT := (SELECT valor FROM ctx WHERE clave = 'token');
BEGIN
  FOR r IN
    SELECT x->>'categoria' AS categoria
    FROM jsonb_array_elements(public.portal_ive_contexto(v_token)->'requisitos') x
    WHERE (x->>'obligatorio')::boolean AND x->>'categoria' <> 'ESTADO_CUENTA'
  LOOP
    v_reserva := public.portal_ive_preparar_carga(v_token, r.categoria::public.doc_categoria, r.categoria || '.pdf', 'application/pdf', 1000);
    INSERT INTO storage.objects (bucket_id, name) VALUES ('expedientes', v_reserva->>'path');
    PERFORM public.portal_ive_confirmar_carga(v_token, (v_reserva->>'documento_id')::uuid);
  END LOOP;
END $$;
SELECT pg_temp.ok(true, 'el afianzado sube a rutas reservadas');

SELECT pg_temp.falla_con(
  $$INSERT INTO storage.objects (bucket_id, name) VALUES ('expedientes', 'altas/inventada/archivo.pdf')$$,
  'el afianzado no sube a una ruta no reservada');
SELECT pg_temp.falla_con(
  format($f$SELECT public.portal_ive_preparar_carga(%L, 'DPI', 'x.exe', 'application/x-msdownload', 10)$f$,
         (SELECT valor FROM ctx WHERE clave = 'token')),
  'el portal rechaza tipos de archivo no permitidos');

SELECT public.completar_ive_invitacion((SELECT valor FROM ctx WHERE clave = 'token'),
  '{"tipoIve":"IVE-ASS-01","primerNombre":"JUAN","primerApellido":"PRUEBA","dpi":"1234567890101","nit":"7777777-7","telefono":"55551234","correo":"flujo@ejemplo.test","direccion":"Zona 1","municipio":"Guatemala","departamento":"Guatemala","nacionalidad":"Guatemalteca","profesion":"Comerciante","lugarTrabajo":"Negocio propio","cargoTrabajo":"Propietario","ingresosMensuales":"20000","egresosMensuales":"8000","estadoCivil":"Casado","refNombre1":"Ref","refTelefono1":"55550000","declaracionVeracidad":true,"firmaImagen":"data:image/png;base64,AAAA","esPEP":"NO","parientePEP":"NO","asociadoPEP":"NO","fechaNacimiento":"1980-01-01","fuenteIngresos":"NEGOCIO_PROPIO"}');
SELECT pg_temp.ok(
  (public.portal_ive_contexto((SELECT valor FROM ctx WHERE clave = 'token'))->>'motivo') = 'ENVIADO',
  'tras enviar, el enlace ya no admite cambios');
RESET role;

SELECT pg_temp.ok(
  (SELECT estado_operativo FROM public.solicitudes_alta WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'solicitud')) = 'EXPEDIENTE_RECIBIDO',
  'el expediente queda recibido');
SELECT pg_temp.ok(
  EXISTS (SELECT 1 FROM public.notificaciones n
          WHERE n.user_id = '00000000-0000-4000-a000-000000000002' AND n.link LIKE '/altas/%'),
  'Suscripcion recibe aviso del expediente recibido para consultarlo');
SELECT pg_temp.ok(
  EXISTS (SELECT 1 FROM public.notificaciones n WHERE n.user_id = '00000000-0000-4000-a000-000000000011'),
  'la marca recibe aviso del avance');

-- 3. Lo que falta se recalcula solo con cada documento ------------------------
SELECT pg_temp.ok(
  (SELECT faltantes ? 'ESTADO_CUENTA' FROM public.solicitudes_alta WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'solicitud')),
  'recibido sin el estado de cuenta, la solicitud lo marca como faltante');
SELECT pg_temp.ok(
  (SELECT faltantes = COALESCE((SELECT jsonb_agg(categoria) FROM public.d6_documentos_faltantes(sa.id, false)), '[]'::jsonb)
   FROM public.solicitudes_alta sa WHERE sa.id = (SELECT valor::uuid FROM ctx WHERE clave = 'solicitud')),
  'los faltantes guardados son los de la lista de requisitos');

-- La marca genera un enlace nuevo y el distribuidor manda el estado de cuenta.
SELECT pg_temp.como('00000000-0000-4000-a000-000000000011');
UPDATE ctx SET valor = (SELECT token FROM public.crear_invitacion_ive(
  (SELECT valor::uuid FROM ctx WHERE clave = 'solicitud'), NULL)) WHERE clave = 'token';
RESET role;
SELECT pg_temp.anonimo();
SELECT pg_temp.ok(
  (public.portal_ive_contexto((SELECT valor FROM ctx WHERE clave = 'token'))->>'solo_documentos')::boolean,
  'ya recibido, el enlace nuevo solo pide documentos');
DO $$
DECLARE
  v_reserva JSONB;
  v_token TEXT := (SELECT valor FROM ctx WHERE clave = 'token');
BEGIN
  v_reserva := public.portal_ive_preparar_carga(v_token, 'ESTADO_CUENTA', 'estado-cuenta.pdf', 'application/pdf', 2000);
  INSERT INTO storage.objects (bucket_id, name) VALUES ('expedientes', v_reserva->>'path');
  PERFORM public.portal_ive_confirmar_carga(v_token, (v_reserva->>'documento_id')::uuid);
END $$;
RESET role;
SELECT pg_temp.ok(
  (SELECT NOT faltantes ? 'ESTADO_CUENTA' AND estado_operativo = 'EXPEDIENTE_RECIBIDO'
   FROM public.solicitudes_alta WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'solicitud')),
  'al llegar el documento deja de faltar, sin que nadie lo revise');

-- Fidelis consulta el expediente en su bandeja.
SELECT pg_temp.como('00000000-0000-4000-a000-000000000002');
SELECT pg_temp.ok(
  EXISTS (SELECT 1 FROM public.v_bandeja_altas WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'solicitud')
          AND estado_operativo = 'EXPEDIENTE_RECIBIDO'),
  'Suscripcion ve el expediente recibido en la bandeja');
SELECT pg_temp.falla_con('SELECT public.d6_vincular_emisiones_fiso()', 'Suscripcion no ejecuta el vinculo: lo hace la carga de FISO');
RESET role;

-- 4. La carga de FISO reconoce la fianza emitida ------------------------------
-- Contactos de FISO: el distribuidor con el NIT que lleno en el IVE y otro distribuidor.
INSERT INTO public.clientes (codigo_contacto, nombre, nit) VALUES
  (99500001, 'JUAN CARLOS PRUEBA FLUJO', '7777777-7'),
  (99500002, 'OTRO DISTRIBUIDOR DE PRUEBA', '1111111-1');
-- Fianzas que NO son de esta solicitud: otra marca, otro NIT y una emitida antes de pedir el alta.
INSERT INTO public.fianzas (fianza, endoso, cliente_id, beneficiario_id, fecha_emision, vigencia_desde, vigencia_hasta,
  status, operational_status, monto_afianzado, contrato_numero, contrato_fecha, contrato_valor)
SELECT x.fianza, 0, c.id, b.id, x.emision, x.emision, x.emision + 364, 'VIGENTE', 'VIGENTE', 120000, 'Otra', x.emision, 120000
FROM (VALUES (9500002, 99500001, 397637, CURRENT_DATE),
             (9500003, 99500002, 527613, CURRENT_DATE),
             (9500004, 99500001, 527613, CURRENT_DATE - 1)) x(fianza, cliente, marca, emision)
JOIN public.clientes c ON c.codigo_contacto = x.cliente
JOIN public.beneficiarios b ON b.codigo_contacto = x.marca;
SELECT public.d6_vincular_emisiones_fiso();
SELECT pg_temp.ok(
  (SELECT estado_operativo = 'EXPEDIENTE_RECIBIDO' AND fianza_emitida_id IS NULL
   FROM public.solicitudes_alta WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'solicitud')),
  'una fianza de otra marca, de otro NIT o emitida antes de la solicitud no se vincula');
SELECT pg_temp.ok(
  NOT EXISTS (SELECT 1 FROM public.solicitudes_alta sa JOIN public.fianzas f ON f.id = sa.fianza_emitida_id
              WHERE f.fianza IN (9500002, 9500003, 9500004)),
  'esas fianzas tampoco quedan vinculadas a otra solicitud');

-- Suscripcion emite en FISO y la carga trae la fianza (simulada como el job interno).
INSERT INTO public.fianzas (fianza, endoso, cliente_id, beneficiario_id, fecha_emision, vigencia_desde, vigencia_hasta,
  status, operational_status, monto_afianzado, prima, derechos, iva, prima_anual, contrato_numero, contrato_fecha, contrato_valor)
SELECT 9500001, 0, c.id, sa.beneficiario_id, CURRENT_DATE, CURRENT_DATE + 1, CURRENT_DATE + 365, 'VIGENTE', 'VIGENTE',
  100000, 2250, 180, 291.6, 2250, 'Escritura 99 de prueba', CURRENT_DATE, 100000
FROM public.solicitudes_alta sa
JOIN public.clientes c ON c.codigo_contacto = 99500001
WHERE sa.id = (SELECT valor::uuid FROM ctx WHERE clave = 'solicitud');
SELECT pg_temp.ok(public.d6_vincular_emisiones_fiso() >= 1, 'la carga reconoce la emision');
INSERT INTO ctx SELECT 'fianza', id::text FROM public.fianzas WHERE fianza = 9500001;
SELECT pg_temp.ok(
  (SELECT estado_operativo = 'EMITIDA' AND fianza_emitida_id = (SELECT valor::uuid FROM ctx WHERE clave = 'fianza')
          AND contrato_numero = 'Escritura 99 de prueba' AND contrato_valor = 100000 AND monto_aprobado = 100000
          AND vigencia_desde = CURRENT_DATE + 1 AND vigencia_hasta = CURRENT_DATE + 365
          AND cliente_id = (SELECT id FROM public.clientes WHERE codigo_contacto = 99500001)
   FROM public.solicitudes_alta WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'solicitud')),
  'la solicitud queda emitida con la fianza, el contrato y la vigencia de FISO');
SELECT pg_temp.ok(
  EXISTS (SELECT 1 FROM public.solicitud_revisiones WHERE solicitud_alta_id = (SELECT valor::uuid FROM ctx WHERE clave = 'solicitud')
          AND estado_nuevo = 'EMITIDA' AND creado_por IS NULL AND comentario LIKE 'Fianza 9500001 emitida en FISO%'),
  'el historial atribuye la emision a FISO, no a una persona');
SELECT pg_temp.ok(
  EXISTS (SELECT 1 FROM public.notificaciones WHERE user_id = '00000000-0000-4000-a000-000000000011'
          AND mensaje LIKE 'Fianza emitida en FISO%'),
  'la marca recibe aviso de la emision');

-- La misma fianza no sirve para otra solicitud del mismo distribuidor.
SELECT pg_temp.como('00000000-0000-4000-a000-000000000011');
INSERT INTO ctx
SELECT 'solicitud2', solicitud_id::text FROM public.d6_solicitar_alta(
  527613, 'JUAN CARLOS PRUEBA FLUJO', 'flujo@ejemplo.test', 100000, 'INDIVIDUAL', '7777777-7', '55551234',
  'RES-0002', CURRENT_DATE, 150000, 90, NULL);
RESET role;
SELECT public.d6_vincular_emisiones_fiso();
SELECT pg_temp.ok(
  (SELECT estado_operativo <> 'EMITIDA' AND fianza_emitida_id IS NULL
   FROM public.solicitudes_alta WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'solicitud2')),
  'una fianza ya vinculada no se vincula a otra solicitud');
SELECT pg_temp.ok(
  (SELECT fianza_emitida_id FROM public.solicitudes_alta WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'solicitud'))
    = (SELECT valor::uuid FROM ctx WHERE clave = 'fianza'),
  'volver a cargar no cambia lo ya emitido');

-- 5. Emitida, la marca ya no edita ---------------------------------------------
SELECT pg_temp.como('00000000-0000-4000-a000-000000000011');
SELECT pg_temp.ok(NOT (public.d6_alta_compartida((SELECT valor::uuid FROM ctx WHERE clave = 'solicitud'))->>'editable')::boolean,
  'emitida, la solicitud ya no aparece editable');
SELECT pg_temp.falla_con(
  format($f$SELECT public.d6_alta_guardar_borrador(%L, '{"profesion":"Otra"}')$f$, (SELECT valor FROM ctx WHERE clave = 'solicitud')),
  'emitida, la marca no edita el formulario');
SELECT pg_temp.falla_con(
  format($f$SELECT * FROM public.crear_invitacion_ive(%L, NULL)$f$, (SELECT valor FROM ctx WHERE clave = 'solicitud')),
  'emitida, no se genera otro enlace');
SELECT pg_temp.falla_con(
  format($f$SELECT public.d6_alta_preparar_carga(%L, 'DPI', 'x.pdf', 'application/pdf', 100)$f$, (SELECT valor FROM ctx WHERE clave = 'solicitud')),
  'emitida, no recibe mas documentos');

-- 6. La marca ve su poliza y pide la baja ------------------------------------
SELECT pg_temp.ok(
  (SELECT estado FROM public.v_fianzas WHERE fianza = 9500001) = 'VIGENTE',
  'la marca ve la poliza nueva como vigente');
SELECT pg_temp.ok(
  (SELECT fianza_emitida FROM public.v_solicitudes_alta_marca WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'solicitud')) = 9500001,
  'la marca ve el numero de fianza en su solicitud');
INSERT INTO ctx SELECT 'baja', baja_id::text FROM public.d6_solicitar_baja(
  (SELECT valor::uuid FROM ctx WHERE clave = 'fianza'), 'DEVOLUCION_MERCADERIA', 'El distribuidor cierra el punto de venta');
SELECT pg_temp.ok(
  (SELECT fecha_efectiva FROM public.solicitudes_baja WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'baja'))
    = (date_trunc('month', now()) + INTERVAL '1 month - 1 day')::date,
  'la baja surte efecto al cierre del mes en que se pidio');
SELECT pg_temp.falla_con(
  format($f$SELECT * FROM public.d6_solicitar_baja(%L, 'OTRO', 'otra vez')$f$, (SELECT valor FROM ctx WHERE clave = 'fianza')),
  'no se piden dos bajas para la misma poliza');
RESET role;

-- Fidelis no la resuelve en la app: la cancela en FISO.
SELECT pg_temp.como('00000000-0000-4000-a000-000000000002');
UPDATE public.solicitudes_baja SET estado = 'APROBADA' WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'baja');
RESET role;
SELECT pg_temp.ok(
  (SELECT estado FROM public.solicitudes_baja WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'baja')) = 'PENDIENTE_REVISION',
  'Suscripcion no aprueba la baja en la app');
-- La carga siguiente trae la fianza cancelada en FISO.
UPDATE public.fianzas SET operational_status = 'CANCELADA', status_raw = 'C', fecha_cancelacion = CURRENT_DATE
WHERE fianza = 9500001;
SELECT pg_temp.como('00000000-0000-4000-a000-000000000011');
SELECT pg_temp.ok((SELECT estado FROM public.v_fianzas WHERE fianza = 9500001) = 'CANCELADA',
  'cuando FISO la cancela la marca la ve cancelada');
RESET role;

ROLLBACK;
