-- Migration 007: Initial Seed for Beneficiaries and Groups
-- Project: Fidelis D6 Consignación
-- Description: Inserts initial beneficiary groups, unique beneficiaries from the D-6 dataset, and establishes group relationships.

-- 1. Insertar Grupos Iniciales de Beneficiarios
INSERT INTO public.grupos_beneficiarios (codigo, nombre, descripcion) VALUES
('GRP-HONDA-SUZUKI', 'Grupo Honda-Suzuki', 'Grupo consolidado de concesionarios e importadores Honda y Suzuki'),
('GRP-CENTRAL-MOTOPREMIUM', 'Grupo Central Motor / Motopremium', 'Grupo de distribuidores Central Americana de Distribución y Motopremium'),
('GRP-INDY-MOTOS', 'Grupo Indy Motos', 'Grupo de distribución Indy Motos'),
('GRP-UNIDADES-MOVILES', 'Grupo Unidades Móviles', 'Grupo Unidades Móviles Automotrices, S.A.'),
('GRP-GENERAL', 'Grupo General Beneficiarios', 'Grupo general para beneficiarios varios')
ON CONFLICT (codigo) DO UPDATE SET 
    nombre = EXCLUDED.nombre,
    descripcion = EXCLUDED.descripcion;

-- 2. Insertar Beneficiarios Únicos de la Cartera D-6
INSERT INTO public.beneficiarios (codigo_contacto, nombre, tipo_persona) VALUES
(16818, 'AGENCIA Y FABRICA HONDA, SOCIEDAD ANONIMA', 'JURIDICA'::tipo_persona),
(60825, 'CENTRAL AMERICANA DE DISTRIBUCION, SOCIEDAD ANONIMA', 'JURIDICA'::tipo_persona),
(374863, 'INDY MOTOS, SOCIEDAD ANONIMA', 'JURIDICA'::tipo_persona),
(397637, 'MOTOPREMIUM, SOCIEDAD ANÓNIMA', 'JURIDICA'::tipo_persona),
(398866, 'CENTRAL AMERICANA DE DISTRIBUCION, SOCIEDAD ANÓNIMA', 'JURIDICA'::tipo_persona),
(398878, 'CENTRAL AMERICANA DE DISTRIBUCION, SOCIEDAD ANÓNIMA / MOTOPREMIUM, S.A.', 'JURIDICA'::tipo_persona),
(521278, 'SUZUKI, SOCIEDAD ANÓNIMA', 'JURIDICA'::tipo_persona),
(527613, 'UNIDADES MÓVILES AUTOMOTRICES, S.A', 'JURIDICA'::tipo_persona),
(541453, 'CENTRAL AMERICANA DE DISTRIBUCIÓN, SOCIEDAD ANÓNIMA', 'JURIDICA'::tipo_persona),
(541582, 'SUZUKI, SOCIEDAD ANÓNIMA', 'JURIDICA'::tipo_persona),
(1118062, 'SUZUKI, S.A.', 'JURIDICA'::tipo_persona)
ON CONFLICT (codigo_contacto) DO UPDATE SET 
    nombre = EXCLUDED.nombre,
    tipo_persona = EXCLUDED.tipo_persona;

-- 3. Mapeo e Inserción de Relaciones entre Grupos y Beneficiarios
INSERT INTO public.grupo_beneficiario_rel (grupo_id, beneficiario_id)
SELECT g.id, b.id
FROM public.beneficiarios b
CROSS JOIN public.grupos_beneficiarios g
WHERE 
  (g.codigo = 'GRP-HONDA-SUZUKI' AND (b.nombre ILIKE '%HONDA%' OR b.nombre ILIKE '%SUZUKI%')) OR
  (g.codigo = 'GRP-CENTRAL-MOTOPREMIUM' AND (b.nombre ILIKE '%CENTRAL AMERICANA%' OR b.nombre ILIKE '%MOTOPREMIUM%')) OR
  (g.codigo = 'GRP-INDY-MOTOS' AND b.nombre ILIKE '%INDY MOTOS%') OR
  (g.codigo = 'GRP-UNIDADES-MOVILES' AND b.nombre ILIKE '%UNIDADES MÓVILES%') OR
  (g.codigo = 'GRP-GENERAL' AND b.nombre NOT ILIKE '%HONDA%' AND b.nombre NOT ILIKE '%SUZUKI%' AND b.nombre NOT ILIKE '%CENTRAL AMERICANA%' AND b.nombre NOT ILIKE '%MOTOPREMIUM%' AND b.nombre NOT ILIKE '%INDY MOTOS%' AND b.nombre NOT ILIKE '%UNIDADES MÓVILES%')
ON CONFLICT (grupo_id, beneficiario_id) DO NOTHING;
