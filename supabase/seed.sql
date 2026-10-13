-- Datos de prueba para desarrollo local (supabase db reset).
-- Todo es ficticio: nombres, NIT, numeros de poliza y correos. Nunca cargar este
-- archivo en un proyecto hospedado.
--
-- Usuarios de prueba. Contrasena de todos: Prueba2026local
--   admin@fidelis.test        admin
--   suscripcion@fidelis.test  suscripcion
--   comercial@fidelis.test    comercial
--   cobros@fidelis.test       cobros
--   consulta@fidelis.test     consulta (solo lectura)
--   contabilidad@fidelis.test contabilidad (concilia contra el banco)
--   comercializacion@fidelis.test coordinacion_comercial (genera y envia estados de cuenta)
--   marca@uma.test            marca Grupo UMA
--   marca@admosa.test         marca Central Americana / Motopremium
--   marca@honda.test          marca Honda

-- 1. Usuarios ---------------------------------------------------------------
WITH usuarios(id, email, nombre) AS (
  VALUES
    ('00000000-0000-4000-a000-000000000001'::uuid, 'admin@fidelis.test', 'Administracion Fidelis'),
    ('00000000-0000-4000-a000-000000000002'::uuid, 'suscripcion@fidelis.test', 'Ana Suscripcion'),
    ('00000000-0000-4000-a000-000000000003'::uuid, 'comercial@fidelis.test', 'Carlos Comercial'),
    ('00000000-0000-4000-a000-000000000004'::uuid, 'cobros@fidelis.test', 'Beatriz Cobros'),
    ('00000000-0000-4000-a000-000000000005'::uuid, 'consulta@fidelis.test', 'Gerencia Consulta'),
    ('00000000-0000-4000-a000-000000000006'::uuid, 'contabilidad@fidelis.test', 'Diego Contabilidad'),
    ('00000000-0000-4000-a000-000000000007'::uuid, 'comercializacion@fidelis.test', 'Elena Comercializacion'),
    ('00000000-0000-4000-a000-000000000011'::uuid, 'marca@uma.test', 'Usuario UMA'),
    ('00000000-0000-4000-a000-000000000012'::uuid, 'marca@admosa.test', 'Usuario ADMOSA'),
    ('00000000-0000-4000-a000-000000000013'::uuid, 'marca@honda.test', 'Usuario Honda')
)
INSERT INTO auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, email_change, email_change_token_new, recovery_token
)
SELECT
  '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated', email,
  extensions.crypt('Prueba2026local', extensions.gen_salt('bf')), now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  jsonb_build_object('full_name', nombre), now(), now(), '', '', '', ''
FROM usuarios;

INSERT INTO auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
SELECT gen_random_uuid(), u.id, u.id::text,
       jsonb_build_object('sub', u.id::text, 'email', u.email, 'email_verified', true),
       'email', now(), now(), now()
FROM auth.users u
WHERE u.email LIKE '%.test';

INSERT INTO public.user_role_assignments (user_id, role) VALUES
  ('00000000-0000-4000-a000-000000000001', 'admin'),
  ('00000000-0000-4000-a000-000000000002', 'suscripcion'),
  ('00000000-0000-4000-a000-000000000003', 'comercial'),
  ('00000000-0000-4000-a000-000000000004', 'cobros'),
  ('00000000-0000-4000-a000-000000000005', 'consulta'),
  ('00000000-0000-4000-a000-000000000006', 'contabilidad'),
  ('00000000-0000-4000-a000-000000000007', 'coordinacion_comercial'),
  ('00000000-0000-4000-a000-000000000011', 'beneficiario'),
  ('00000000-0000-4000-a000-000000000012', 'beneficiario'),
  ('00000000-0000-4000-a000-000000000013', 'beneficiario');

INSERT INTO public.user_grupos (user_id, grupo_id)
SELECT u.user_id, g.id
FROM (VALUES
  ('00000000-0000-4000-a000-000000000011'::uuid, 'GRP-UNIDADES-MOVILES'),
  ('00000000-0000-4000-a000-000000000012'::uuid, 'GRP-CENTRAL-MOTOPREMIUM'),
  ('00000000-0000-4000-a000-000000000013'::uuid, 'GRP-HONDA')
) AS u(user_id, codigo)
JOIN public.grupos_beneficiarios g ON g.codigo = u.codigo;

-- 2. Afianzados ficticios ---------------------------------------------------
WITH nombres(n, nombre, tipo) AS (
  VALUES
    (1, 'MARIO ESTUARDO PRUEBA LOPEZ', 'INDIVIDUAL'),
    (2, 'ANA LUCIA EJEMPLO GARCIA', 'INDIVIDUAL'),
    (3, 'JOSE ARMANDO FICTICIO PEREZ', 'INDIVIDUAL'),
    (4, 'SILVIA MARINA DEMO CASTILLO', 'INDIVIDUAL'),
    (5, 'MOTOS DEL ALTIPLANO DE PRUEBA, SOCIEDAD ANONIMA', 'JURIDICA'),
    (6, 'PEDRO PABLO MUESTRA RAMIREZ', 'INDIVIDUAL'),
    (7, 'LUCIA FERNANDA ENSAYO MORALES', 'INDIVIDUAL'),
    (8, 'REPUESTOS EJEMPLO ORIENTE, SOCIEDAD ANONIMA', 'JURIDICA'),
    (9, 'ERICK DANIEL SIMULADO HERRERA', 'INDIVIDUAL'),
    (10, 'MARTA ELENA PRUEBA SOLIS', 'INDIVIDUAL'),
    (11, 'OSCAR RENE FICTICIO AGUILAR', 'INDIVIDUAL'),
    (12, 'KARLA PATRICIA DEMO VASQUEZ', 'INDIVIDUAL'),
    (13, 'DISTRIBUIDORA FICTICIA DEL SUR, SOCIEDAD ANONIMA', 'JURIDICA'),
    (14, 'HUGO ALEJANDRO EJEMPLO REYES', 'INDIVIDUAL'),
    (15, 'SANDRA NOEMI MUESTRA CRUZ', 'INDIVIDUAL'),
    (16, 'WALTER ESTEBAN ENSAYO MENDEZ', 'INDIVIDUAL'),
    (17, 'ROSA ISABEL SIMULADA ORTIZ', 'INDIVIDUAL'),
    (18, 'MOTOCENTRO PRUEBA NORTE, SOCIEDAD ANONIMA', 'JURIDICA'),
    (19, 'FERNANDO JOSE DEMO CHAVEZ', 'INDIVIDUAL'),
    (20, 'GLADYS MARLENI FICTICIA PAZ', 'INDIVIDUAL')
)
INSERT INTO public.clientes (codigo_contacto, nombre, nit, tipo_persona, telefono, email)
SELECT 800000 + n, nombre, (1000000 + n * 7919)::text || '-' || (n % 10)::text,
       tipo::public.tipo_persona, '5500' || lpad(n::text, 4, '0'),
       'afianzado' || n || '@ejemplo.test'
FROM nombres;

-- 3. Polizas ficticias ------------------------------------------------------
-- 48 polizas repartidas entre las marcas. Tarifa 2 % (2.25 % UMA), derechos 8 % de
-- la prima, IVA 12 % sobre prima + derechos. Algunas canceladas, algunas por vencer.
WITH base AS (
  SELECT
    g AS n,
    (ARRAY[527613, 397637, 398866, 374863, 16818, 1118062])[1 + (g % 6)] AS beneficiario_codigo,
    800000 + 1 + (g % 20) AS cliente_codigo,
    (ARRAY[100000, 150000, 200000, 250000, 300000, 350000])[1 + (g * 7 % 6)]::numeric AS monto,
    (DATE '2025-10-15' + ((g * 11) % 360))::date AS desde
  FROM generate_series(1, 48) g
)
INSERT INTO public.fianzas (
  fianza, endoso, cliente_id, beneficiario_id, agente_id, fecha_emision, vigencia_desde, vigencia_hasta,
  fecha_cancelacion, cod_estado_poliza, status_raw, status, operational_status,
  monto_afianzado, prima, derechos, iva, prima_anual, contrato_numero, contrato_fecha, contrato_valor, tema_de_fianza
)
SELECT
  9000000 + b.n, 0, c.id, be.id, a.id, b.desde + 5, b.desde, (b.desde + INTERVAL '1 year' - INTERVAL '1 day')::date,
  CASE WHEN b.n % 9 = 0 THEN b.desde + 120 END,
  'EN', CASE WHEN b.n % 9 = 0 THEN 'C' ELSE 'V' END,
  (CASE WHEN b.n % 9 = 0 THEN 'CANCELADA' ELSE 'VIGENTE' END)::public.fianza_status,
  (CASE WHEN b.n % 9 = 0 THEN 'CANCELADA' ELSE 'VIGENTE' END)::public.d6_poliza_status,
  b.monto, p.prima, round(p.prima * 0.08, 2), round(p.prima * 1.08 * 0.12, 2), p.prima,
  'Escritura publica de prueba ' || b.n, b.desde, b.monto,
  'Consignacion comercial de linea de productos'
FROM base b
JOIN public.clientes c ON c.codigo_contacto = b.cliente_codigo
JOIN public.beneficiarios be ON be.codigo_contacto = b.beneficiario_codigo
JOIN public.agentes a ON a.numero_agente = 0 AND a.indice_agente = 0
CROSS JOIN LATERAL (
  SELECT round(b.monto * CASE WHEN b.beneficiario_codigo = 527613 THEN 0.0225 ELSE 0.02 END, 2) AS prima
) p;
