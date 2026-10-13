-- 038: permisos de funciones (auditoria del 2026-10-08).
-- Por defecto Postgres y Supabase dejan que cualquiera, incluso sin sesion, ejecute toda
-- funcion nueva. Con eso un anonimo dedujo la exposicion de un cliente con todas las marcas
-- llamando d6_requiere_documento_accesorio. Ahora el anonimo solo ejecuta el portal y los
-- ayudantes que las politicas de Storage evaluan, que solo miran al usuario en curso.

-- 1. Las funciones nuevas ya no nacen abiertas al anonimo.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM anon;

-- 2. Las existentes: se retira PUBLIC y anon de todas, y se devuelve anon solo a la lista blanca.
DO $$
DECLARE
  r RECORD;
  v_anon TEXT[] := ARRAY[
    -- Portal del distribuidor
    'portal_ive_contexto', 'portal_ive_guardar_borrador', 'portal_ive_preparar_carga',
    'portal_ive_confirmar_carga', 'portal_ive_quitar_documento', 'completar_ive_invitacion',
    -- Ayudantes que evaluan las politicas de Storage. Responden por el usuario en curso:
    -- para un anonimo siempre dan falso.
    'd6_ruta_reservada', 'has_d6_role', 'd6_rol_real', 'd6_marca_en_vista', 'd6_mis_grupos',
    'd6_es_personal_aseguradora', 'd6_es_personal_real', 'd6_puede_ver_documento',
    'd6_puede_ver_beneficiario', 'd6_beneficiario_es_mio', 'd6_baja_es_mia', 'd6_reclamo_es_mio',
    'get_user_beneficiario_ids'
  ];
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS firma, p.proname
    FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace
      AND p.prokind = 'f'
      AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon', r.firma);
    IF r.proname = ANY (v_anon) THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO anon', r.firma);
    END IF;
  END LOOP;
END $$;

-- 3. Lo que ni siquiera un usuario con sesion debe llamar directo.
--    La exposicion con otras marcas la calcula el servidor dentro de las RPC de Suscripcion.
REVOKE EXECUTE ON FUNCTION public.d6_requiere_documento_accesorio(UUID, NUMERIC) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.get_user_role(UUID) FROM authenticated;
-- Funciones de trigger: las ejecuta el trigger, no un usuario.
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS firma FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace AND p.prorettype = 'trigger'::regtype
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM authenticated', r.firma);
  END LOOP;
END $$;

-- 4. Montos negativos no tienen sentido en la regla del accesorio.
CREATE OR REPLACE FUNCTION public.d6_requiere_documento_accesorio(p_cliente_id UUID, p_monto NUMERIC)
RETURNS BOOLEAN
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_exposicion NUMERIC := 0;
BEGIN
  IF COALESCE(p_monto, 0) <= 0 THEN
    RAISE EXCEPTION 'El monto debe ser mayor que cero';
  END IF;
  SELECT COALESCE(sum(monto_afianzado), 0) INTO v_exposicion
  FROM public.fianzas
  WHERE cliente_id = p_cliente_id
    AND operational_status IN ('VIGENTE', 'POR_RENOVAR', 'PENDIENTE_ANULACION')
    AND vigencia_hasta >= CURRENT_DATE;
  RETURN p_monto > 300000 OR p_monto + v_exposicion > 300000;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.d6_requiere_documento_accesorio(UUID, NUMERIC) FROM PUBLIC, anon, authenticated;

-- 5. search_path fijo en las dos funciones SECURITY DEFINER que no lo tenian.
ALTER FUNCTION public.get_user_role(UUID) SET search_path = public;
ALTER FUNCTION public.log_audit_changes() SET search_path = public;

-- 6. Un solo camino para ser administrador: user_role_assignments, que la pantalla de accesos
--    muestra y la bitacora registra. Se retira la via vieja de user_profiles.role.
CREATE OR REPLACE FUNCTION public.d6_rol_real(p_roles public.d6_role[])
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT auth.uid() IS NOT NULL
     AND EXISTS (SELECT 1 FROM public.user_role_assignments WHERE user_id = auth.uid() AND role = ANY (p_roles));
$$;

-- 7. TRUNCATE no lo necesita nadie fuera del dueño.
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT tablename FROM pg_tables WHERE schemaname = 'public' LOOP
    EXECUTE format('REVOKE TRUNCATE ON public.%I FROM anon, authenticated', r.tablename);
  END LOOP;
END $$;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE TRUNCATE ON TABLES FROM anon, authenticated;
