-- Reclamos y perfil del afianzado sobre los datos de supabase/seed.sql. Se revierte.
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

-- Una fianza vigente de UMA y su afianzado.
INSERT INTO ctx SELECT 'fianza', f.id::text FROM public.fianzas f JOIN public.beneficiarios b ON b.id = f.beneficiario_id
WHERE b.codigo_contacto = 527613 AND f.operational_status = 'VIGENTE' AND f.vigencia_hasta >= CURRENT_DATE
ORDER BY f.fianza LIMIT 1;
INSERT INTO ctx SELECT 'desde', vigencia_desde::text FROM public.fianzas WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'fianza');

-- 1. La marca avisa un incumplimiento -------------------------------------
SELECT pg_temp.como('00000000-0000-4000-a000-000000000011');
SELECT pg_temp.falla_con(
  format($f$SELECT * FROM public.d6_reportar_incumplimiento(%L, 'FALTA_PAGO', CURRENT_DATE, 999999999, 'x')$f$, (SELECT valor FROM ctx WHERE clave = 'fianza')),
  'no se reclama mas que el monto afianzado');
SELECT pg_temp.falla_con(
  format($f$SELECT * FROM public.d6_reportar_incumplimiento(%L, 'FALTA_PAGO', %L::date - 30, 1000, 'x')$f$,
    (SELECT valor FROM ctx WHERE clave = 'fianza'), (SELECT valor FROM ctx WHERE clave = 'desde')),
  'no se reclama un incumplimiento anterior a la vigencia');
INSERT INTO ctx SELECT 'reclamo', reclamo_id::text FROM public.d6_reportar_incumplimiento(
  (SELECT valor::uuid FROM ctx WHERE clave = 'fianza'), 'FALTA_PAGO', CURRENT_DATE, 45000,
  'El distribuidor vendio 3 motos y no pago', 3, false);
SELECT pg_temp.ok((SELECT estado FROM public.reclamos_d6 WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'reclamo')) = 'AVISO',
  'la marca deja un aviso de incumplimiento');
-- La marca agrega informacion a su reclamo. Un comentario suyo nunca queda como nota interna.
SELECT public.d6_comentar_reclamo((SELECT valor::uuid FROM ctx WHERE clave = 'reclamo'), 'Adjuntamos estado de cuenta del distribuidor', true);
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM public.reclamo_movimientos_d6 WHERE reclamo_id = (SELECT valor::uuid FROM ctx WHERE clave = 'reclamo')
                          AND comentario = 'Adjuntamos estado de cuenta del distribuidor' AND NOT interno
                          AND creado_por = '00000000-0000-4000-a000-000000000011'),
  'la marca comenta su reclamo y el comentario queda visible');
SELECT pg_temp.falla_con(
  format($f$SELECT public.d6_comentar_reclamo(%L, '   ')$f$, (SELECT valor FROM ctx WHERE clave = 'reclamo')),
  'un comentario vacio no se guarda');
-- Un reclamo presentado de una vez, sin pasar por aviso.
INSERT INTO ctx SELECT 'reclamo2', reclamo_id::text FROM public.d6_reportar_incumplimiento(
  (SELECT valor::uuid FROM ctx WHERE clave = 'fianza'), 'NO_DEVOLUCION_INVENTARIO', CURRENT_DATE, 20000,
  'No devolvio dos unidades en consignacion', 2, true);
SELECT pg_temp.ok((SELECT estado FROM public.reclamos_d6 WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'reclamo2')) = 'PRESENTADO',
  'la marca presenta el reclamo formal');
UPDATE public.reclamos_d6 SET estado = 'PAGADO' WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'reclamo');
RESET role;
SELECT pg_temp.ok((SELECT estado FROM public.reclamos_d6 WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'reclamo')) = 'AVISO',
  'la marca no cambia el estado de su reclamo');

SELECT pg_temp.como('00000000-0000-4000-a000-000000000012');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.v_reclamos WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'reclamo')),
  'otra marca no ve el reclamo');
SELECT pg_temp.falla_con(
  format($f$SELECT * FROM public.d6_reportar_incumplimiento(%L, 'OTRO', CURRENT_DATE, 10, 'x')$f$, (SELECT valor FROM ctx WHERE clave = 'fianza')),
  'otra marca no reclama fianzas ajenas');
SELECT pg_temp.falla_con(
  format($f$SELECT public.d6_comentar_reclamo(%L, 'x')$f$, (SELECT valor FROM ctx WHERE clave = 'reclamo')),
  'otra marca no comenta reclamos ajenos');
RESET role;

-- 2. Fidelis consulta el reclamo: lo resuelve fuera de la app ------------------
SELECT pg_temp.como('00000000-0000-4000-a000-000000000002');
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM public.notificaciones WHERE user_id = auth.uid() AND link LIKE '/reclamos/%'),
  'Suscripcion recibe aviso del reclamo');
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM public.v_reclamos WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'reclamo')),
  'Suscripcion consulta el reclamo');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'd6_avanzar_reclamo'),
  'el estado del reclamo no se avanza en la app');
UPDATE public.reclamos_d6 SET estado = 'PAGADO', monto_pagado = 45000 WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'reclamo');
SELECT pg_temp.ok((SELECT estado = 'AVISO' AND COALESCE(monto_pagado, 0) = 0 FROM public.reclamos_d6 WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'reclamo')),
  'ni con un UPDATE directo');
SELECT pg_temp.ok(
  (SELECT nivel_riesgo = 'ALTO' AND alerta_reclamo AND reclamos_abiertos >= 2 FROM public.v_perfil_afianzados
   WHERE cliente_id = (SELECT cliente_id FROM public.reclamos_d6 WHERE id = (SELECT valor::uuid FROM ctx WHERE clave = 'reclamo'))),
  'el afianzado con reclamos abiertos pasa a riesgo alto');
SELECT pg_temp.ok((SELECT afianzados_activos > 0 FROM public.d6_resumen_riesgo()), 'el resumen de riesgo responde');
RESET role;

-- 3. La marca no ve notas internas ni el perfil ----------------------------
-- Nota interna del historial anterior a la 044.
INSERT INTO public.reclamo_movimientos_d6 (reclamo_id, comentario, interno, creado_por)
VALUES ((SELECT valor::uuid FROM ctx WHERE clave = 'reclamo'), 'Revisar contragarantia', true, '00000000-0000-4000-a000-000000000002');
SELECT pg_temp.como('00000000-0000-4000-a000-000000000011');
SELECT pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.reclamo_movimientos_d6 WHERE interno), 'la marca no ve notas internas');
SELECT pg_temp.ok(EXISTS (SELECT 1 FROM public.reclamo_movimientos_d6 WHERE reclamo_id = (SELECT valor::uuid FROM ctx WHERE clave = 'reclamo')
                          AND estado_nuevo = 'AVISO'), 'la marca ve el historial de su reclamo');
SELECT pg_temp.ok((SELECT count(*) FROM public.v_perfil_afianzados) = 0, 'la marca no ve perfiles de riesgo');
SELECT pg_temp.ok((SELECT count(*) FROM public.perfil_afianzado_oracle) = 0, 'la marca no ve datos de Oracle');
RESET role;

-- 4. Perfil con datos de Oracle --------------------------------------------
INSERT INTO public.perfil_afianzado_oracle (cliente_codigo, ive_fecha_renovacion, saldo, saldo_atrasado, max_dias_atraso)
SELECT c.codigo_contacto, CURRENT_DATE + 200, 500, 500, 45 FROM public.clientes c WHERE c.codigo_contacto = 800002
UNION ALL
SELECT c.codigo_contacto, CURRENT_DATE - 10, 500, 500, 75 FROM public.clientes c WHERE c.codigo_contacto = 800004;
SELECT pg_temp.como('00000000-0000-4000-a000-000000000005');
SELECT pg_temp.ok(
  (SELECT NOT alerta_atraso FROM public.v_perfil_afianzados WHERE codigo = 800002),
  'un atraso dentro del plazo de pago de la marca (60 dias) no es alerta');
SELECT pg_temp.ok(
  (SELECT alerta_ive AND alerta_atraso AND nivel_riesgo IN ('MEDIO', 'ALTO') FROM public.v_perfil_afianzados WHERE codigo = 800004),
  'IVE vencido y mora de mas de 60 dias elevan el riesgo');
RESET role;

ROLLBACK;
