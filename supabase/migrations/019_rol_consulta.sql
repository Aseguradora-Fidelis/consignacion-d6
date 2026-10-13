-- Rol de solo lectura para personal de Fidelis (gerencia, auditoria interna).
-- Va en su propia migracion porque PostgreSQL no permite usar un valor de enum
-- recien agregado dentro de la misma transaccion.
ALTER TYPE public.d6_role ADD VALUE IF NOT EXISTS 'consulta';
