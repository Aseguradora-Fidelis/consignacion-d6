-- Expediente compartido entre marca y distribuidor (migraciones 033 y 034). Se revierte.
BEGIN;

CREATE OR REPLACE FUNCTION pg_temp.como(p_user UUID)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('role', 'authenticated', true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_user::text, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', '{}', true);
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

-- 1. UMA pide el alta solo con celular y adelanta datos -------------------------
SELECT pg_temp.como('00000000-0000-4000-a000-000000000011');
SELECT pg_temp.falla_con($f$SELECT * FROM public.d6_solicitar_alta(527613, 'Sin Correo', NULL, 100000, 'INDIVIDUAL', NULL, '55551111', 'NR-1', CURRENT_DATE)$f$,
  'el correo del distribuidor es obligatorio');
INSERT INTO ctx SELECT 'sol', solicitud_id::text FROM public.d6_solicitar_alta(527613, 'Distribuidor Compartido', 'compartido@ejemplo.test', 100000,
  'INDIVIDUAL', NULL, '55551111', 'NR-1', CURRENT_DATE);
SELECT public.d6_alta_guardar_borrador((SELECT valor::uuid FROM ctx WHERE clave = 'sol'),
  '{"primerNombre":"Distribuidor","dpi":"1234567890101","firmaImagen":"no-debe-guardarse"}'::jsonb);
SELECT public.d6_alta_guardar_borrador((SELECT valor::uuid FROM ctx WHERE clave = 'sol'), '{"nit":"1234567"}'::jsonb);
SELECT pg_temp.ok((SELECT d6_alta_compartida(valor::uuid)->'borrador'->>'dpi' = '1234567890101'
  AND d6_alta_compartida(valor::uuid)->'borrador'->>'nit' = '1234567' FROM ctx WHERE clave = 'sol'),
  'lo que guarda la marca se combina sin borrar lo anterior');
SELECT pg_temp.ok((SELECT d6_alta_compartida(valor::uuid)->'borrador'->>'firmaImagen' IS NULL FROM ctx WHERE clave = 'sol'),
  'la marca no puede firmar por el distribuidor');
SELECT pg_temp.ok((SELECT jsonb_array_length(d6_alta_compartida(valor::uuid)->'requisitos') > 0 FROM ctx WHERE clave = 'sol'),
  'la marca ve la lista de documentos de la solicitud');
INSERT INTO ctx SELECT 'carga', (public.d6_alta_preparar_carga((SELECT valor::uuid FROM ctx WHERE clave = 'sol'),
  'APROBACION_FIANZA', 'carta.pdf', 'application/pdf', 1000))->>'documento_id';
RESET role;
SELECT pg_temp.ok((SELECT origen = 'MARCA' FROM public.documentos WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'carga')),
  'la marca reserva la carga de su carta');

-- 2. ADMOSA no ve ni toca la solicitud de UMA ------------------------------------
SELECT pg_temp.como('00000000-0000-4000-a000-000000000012');
SELECT pg_temp.falla_con(format('SELECT public.d6_alta_compartida(%L)', (SELECT valor FROM ctx WHERE clave = 'sol')),
  'otra marca no ve el expediente');
SELECT pg_temp.falla_con(format($f$SELECT public.d6_alta_guardar_borrador(%L, '{"dpi":"x"}')$f$, (SELECT valor FROM ctx WHERE clave = 'sol')),
  'otra marca no escribe en el expediente');
SELECT pg_temp.falla_con(format($f$SELECT public.d6_alta_preparar_carga(%L, 'DPI', 'x.pdf', 'application/pdf', 100)$f$, (SELECT valor FROM ctx WHERE clave = 'sol')),
  'otra marca no sube documentos');
RESET role;

-- 3. El distribuidor envia sin la carta de la marca: queda como faltante hasta que llega
UPDATE public.documentos SET carga_pendiente = true WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'carga');
INSERT INTO public.documentos (solicitud_alta_id, categoria, nombre_archivo, file_path, origen, carga_pendiente, requerido)
SELECT (SELECT valor::uuid FROM ctx WHERE clave = 'sol'), r.categoria, 'doc.pdf', 'altas/' || (SELECT valor FROM ctx WHERE clave = 'sol') || '/' || r.categoria || '.pdf', 'AFIANZADO', false, true
FROM public.ive_requisitos_d6 r
WHERE r.activo AND r.tipo_persona = 'INDIVIDUAL' AND r.obligatorio AND r.responsable = 'AFIANZADO'
  AND r.categoria NOT IN ('IVE_ASS_01', 'IVE_ASS_02') AND NOT r.requiere_umbral_exposicion;
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.d6_documentos_faltantes((SELECT valor::uuid FROM ctx WHERE clave = 'sol'), true)),
  'al distribuidor no le falta nada aunque la marca no haya subido su carta');
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM public.d6_documentos_faltantes((SELECT valor::uuid FROM ctx WHERE clave = 'sol'))
  WHERE categoria = 'APROBACION_FIANZA'), 'para Fidelis sigue faltando la carta de la marca');
-- El envio del portal deja la solicitud recibida (aqui se simula el cambio de estado).
UPDATE public.solicitudes_alta SET estado_operativo = 'EXPEDIENTE_RECIBIDO', ive_data = '{"tipoIve":"IVE-ASS-01"}'
WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'sol');
SELECT pg_temp.como('00000000-0000-4000-a000-000000000002');
SELECT pg_temp.ok((SELECT estado_operativo = 'EXPEDIENTE_RECIBIDO' AND faltantes ? 'APROBACION_FIANZA'
                   FROM public.solicitudes_alta WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'sol')),
  'Fidelis consulta el expediente recibido con la carta de la marca como faltante');
RESET role;
SELECT pg_temp.como('00000000-0000-4000-a000-000000000011');
INSERT INTO ctx SELECT 'token2', token FROM public.crear_invitacion_ive((SELECT valor::uuid FROM ctx WHERE clave = 'sol'), NULL);
SELECT pg_temp.ok((SELECT valor FROM ctx WHERE clave = 'token2') IS NOT NULL, 'con la solicitud recibida la marca genera un enlace para actualizar');
RESET role;
SELECT pg_temp.ok((public.portal_ive_contexto((SELECT valor FROM ctx WHERE clave = 'token2'))->>'actualizacion')::boolean,
  'el enlace nuevo abre la solicitud para completar lo pendiente');
SELECT pg_temp.como('00000000-0000-4000-a000-000000000011');
SELECT pg_temp.falla_con(format($f$SELECT public.d6_alta_guardar_borrador(%L, '{"dpi":"y"}')$f$, (SELECT valor FROM ctx WHERE clave = 'sol')),
  'ya enviado, la marca edita pero no deja incompleto el formulario');
SELECT pg_temp.ok((SELECT (d6_alta_compartida(valor::uuid)->>'recibe_documentos')::boolean FROM ctx WHERE clave = 'sol'),
  'ya enviado, la marca todavia puede subir documentos pendientes');
-- La marca sube su carta: deja de faltar sola, sin revision de Fidelis.
INSERT INTO ctx SELECT 'reserva', public.d6_alta_preparar_carga((SELECT valor::uuid FROM ctx WHERE clave = 'sol'),
  'APROBACION_FIANZA', 'carta-firmada.pdf', 'application/pdf', 1000)::text;
RESET role;
-- El navegador sube el archivo a la ruta reservada.
INSERT INTO storage.objects (bucket_id, name) SELECT 'expedientes', valor::jsonb->>'path' FROM ctx WHERE clave = 'reserva';
SELECT pg_temp.como('00000000-0000-4000-a000-000000000011');
SELECT public.d6_alta_confirmar_carga((SELECT (valor::jsonb->>'documento_id')::uuid FROM ctx WHERE clave = 'reserva'));
RESET role;
SELECT pg_temp.ok((SELECT NOT faltantes ? 'APROBACION_FIANZA' AND estado_operativo = 'EXPEDIENTE_RECIBIDO'
                   FROM public.solicitudes_alta WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'sol')),
  'al llegar la carta de la marca deja de faltar');

ROLLBACK;
