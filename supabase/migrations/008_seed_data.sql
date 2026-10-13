-- Migration 008: sin datos reales.
-- Antes sembraba afianzados y polizas reales copiados del CSV de Oracle. Los datos
-- personales no viven en el repositorio: la cartera real entra por la sincronizacion
-- Oracle (integrations/oracle) y los datos de prueba viven en supabase/seed.sql.

INSERT INTO public.agentes (numero_agente, indice_agente, nombre) VALUES
(0, 0, 'AGENTE DIRECTO')
ON CONFLICT (numero_agente, indice_agente, nombre) DO NOTHING;
