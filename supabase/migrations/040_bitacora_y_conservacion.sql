-- 040: bitacora y conservacion (auditoria del 2026-10-08).
--   * La bitacora registra solo lo que cambio, sin copiar el borrador del IVE en cada
--     autoguardado. Un UPDATE que no cambia nada no deja fila. Antes cada carga de Oracle
--     escribia 656 filas aunque nada cambiara: a ese ritmo, 600 MB al año.
--   * Se audita lo que faltaba: roles, marcas, tarifas, documentos, clientes, estados de cuenta.
--   * La bitacora no se edita ni se borra.
--   * Nadie borra un expediente, una fianza o un reclamo con sus documentos en cascada.
--     La IVE exige conservar el expediente 5 años.

-- ============================================================================
-- 1. Bitacora
-- ============================================================================
ALTER TABLE public.audit_log
  ADD COLUMN IF NOT EXISTS performed_by_email TEXT,
  ADD COLUMN IF NOT EXISTS origen TEXT,
  ADD COLUMN IF NOT EXISTS clave JSONB;
COMMENT ON COLUMN public.audit_log.performed_by_email IS 'Correo de quien hizo el cambio. Sobrevive aunque el usuario se desactive.';
COMMENT ON COLUMN public.audit_log.origen IS 'USUARIO, PORTAL (distribuidor sin sesion) o SISTEMA (carga de Oracle)';

-- El IVE no se copia: se guarda su huella para saber que cambio.
CREATE OR REPLACE FUNCTION public.d6_fila_auditable(p_fila JSONB)
RETURNS JSONB
LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
  SELECT CASE WHEN p_fila ? 'ive_data' AND p_fila->'ive_data' <> 'null'::jsonb
              THEN jsonb_set(p_fila, '{ive_data}', jsonb_build_object('md5', md5((p_fila->'ive_data')::text)))
              ELSE p_fila END
         - 'ive_borrador' - 'updated_at';
$$;

CREATE OR REPLACE FUNCTION public.log_audit_changes()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_old JSONB;
  v_new JSONB;
  v_cambios_old JSONB := '{}'::jsonb;
  v_cambios_new JSONB := '{}'::jsonb;
  v_clave TEXT;
  v_rol TEXT := COALESCE(current_setting('request.jwt.claims', true)::json ->> 'role', '');
  v_origen TEXT;
  v_fila JSONB;
BEGIN
  v_origen := CASE WHEN auth.uid() IS NOT NULL THEN 'USUARIO'
                   WHEN v_rol = 'anon' THEN 'PORTAL'
                   ELSE 'SISTEMA' END;
  IF TG_OP IN ('UPDATE', 'DELETE') THEN v_old := public.d6_fila_auditable(to_jsonb(OLD)); END IF;
  IF TG_OP IN ('UPDATE', 'INSERT') THEN v_new := public.d6_fila_auditable(to_jsonb(NEW)); END IF;

  IF TG_OP = 'UPDATE' THEN
    FOR v_clave IN SELECT jsonb_object_keys(v_new) LOOP
      IF v_new -> v_clave IS DISTINCT FROM v_old -> v_clave THEN
        v_cambios_old := v_cambios_old || jsonb_build_object(v_clave, v_old -> v_clave);
        v_cambios_new := v_cambios_new || jsonb_build_object(v_clave, v_new -> v_clave);
      END IF;
    END LOOP;
    IF v_cambios_new = '{}'::jsonb THEN
      RETURN NEW;
    END IF;
    v_old := v_cambios_old;
    v_new := v_cambios_new;
  END IF;

  v_fila := COALESCE(to_jsonb(NEW), to_jsonb(OLD));
  INSERT INTO public.audit_log (table_name, record_id, clave, action, old_data, new_data, performed_by, performed_by_email, origen)
  VALUES (TG_TABLE_NAME,
          CASE WHEN v_fila ? 'id' THEN (v_fila ->> 'id')::uuid END,
          CASE WHEN v_fila ? 'id' THEN NULL ELSE v_fila END,
          TG_OP, v_old, v_new, auth.uid(),
          COALESCE(current_setting('request.jwt.claims', true)::json ->> 'email',
                   (SELECT email FROM public.user_profiles WHERE id = auth.uid())),
          v_origen);
  RETURN COALESCE(NEW, OLD);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.log_audit_changes() FROM PUBLIC, anon, authenticated;

-- Tablas que faltaban en la bitacora.
DO $$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'clientes', 'documentos', 'estados_cuenta_d6', 'estado_cuenta_items_d6', 'conciliaciones',
    'ive_invitaciones', 'user_role_assignments', 'user_grupos', 'grupos_beneficiarios',
    'grupo_beneficiario_rel', 'beneficiarios', 'contratos_consignacion', 'reglas_cobro_d6',
    'ive_requisitos_d6', 'reclamo_movimientos_d6', 'facturas_fiso_d6'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_audit ON public.%I', t, t);
    EXECUTE format('CREATE TRIGGER trg_%s_audit AFTER INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.log_audit_changes()', t, t);
  END LOOP;
END $$;

-- La bitacora no se edita ni se borra.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.audit_log FROM anon, authenticated;
CREATE OR REPLACE FUNCTION public.d6_bitacora_inmutable()
RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = ''
AS $$
BEGIN
  RAISE EXCEPTION 'La bitacora no se modifica';
END;
$$;
DROP TRIGGER IF EXISTS trg_audit_log_inmutable ON public.audit_log;
CREATE TRIGGER trg_audit_log_inmutable BEFORE UPDATE OR DELETE ON public.audit_log
  FOR EACH ROW EXECUTE FUNCTION public.d6_bitacora_inmutable();
DROP TRIGGER IF EXISTS trg_audit_log_sin_truncate ON public.audit_log;
CREATE TRIGGER trg_audit_log_sin_truncate BEFORE TRUNCATE ON public.audit_log
  FOR EACH STATEMENT EXECUTE FUNCTION public.d6_bitacora_inmutable();

-- ============================================================================
-- 2. Carga de Oracle sin ruido
-- ============================================================================
-- Un UPDATE que no cambia nada se descarta antes de tocar la fila. La carga de Oracle
-- reescribia todas las fianzas en cada corrida y updated_at dejaba de servir.
CREATE OR REPLACE FUNCTION public.d6_descartar_sin_cambios()
RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = ''
AS $$
BEGIN
  IF (to_jsonb(NEW) - 'updated_at') = (to_jsonb(OLD) - 'updated_at') THEN
    RETURN NULL;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_00_fianzas_sin_cambios ON public.fianzas;
CREATE TRIGGER trg_00_fianzas_sin_cambios BEFORE UPDATE ON public.fianzas
  FOR EACH ROW EXECUTE FUNCTION public.d6_descartar_sin_cambios();
DROP TRIGGER IF EXISTS trg_00_clientes_sin_cambios ON public.clientes;
CREATE TRIGGER trg_00_clientes_sin_cambios BEFORE UPDATE ON public.clientes
  FOR EACH ROW EXECUTE FUNCTION public.d6_descartar_sin_cambios();

-- Lo que llega de Oracle reemplaza la prima provisional de una fianza emitida en la app.
CREATE OR REPLACE FUNCTION public.d6_montos_de_fiso()
RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = ''
AS $$
BEGIN
  IF COALESCE(current_setting('request.jwt.claims', true)::json ->> 'role', '') = 'service_role'
     AND OLD.montos_fuente = 'APP_PROVISIONAL'
     AND (NEW.prima, NEW.derechos, NEW.iva) IS DISTINCT FROM (OLD.prima, OLD.derechos, OLD.iva) THEN
    NEW.montos_fuente := 'FISO';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_01_fianzas_montos_fiso ON public.fianzas;
CREATE TRIGGER trg_01_fianzas_montos_fiso BEFORE UPDATE ON public.fianzas
  FOR EACH ROW EXECUTE FUNCTION public.d6_montos_de_fiso();

-- ============================================================================
-- 3. Conservacion: nada se borra en cascada
-- ============================================================================
DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT c.conname, c.conrelid::regclass AS hija, a.attname AS columna, c.confrelid::regclass AS padre,
           af.attname AS columna_padre
    FROM pg_constraint c
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
    JOIN pg_attribute af ON af.attrelid = c.confrelid AND af.attnum = c.confkey[1]
    WHERE c.contype = 'f' AND c.confdeltype = 'c' AND array_length(c.conkey, 1) = 1
      AND c.connamespace = 'public'::regnamespace
      AND c.confrelid::regclass::text IN ('solicitudes_alta', 'fianzas', 'reclamos_d6', 'solicitudes_baja', 'clientes')
  LOOP
    EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', r.hija, r.conname);
    EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I FOREIGN KEY (%I) REFERENCES %s(%I) ON DELETE RESTRICT',
                   r.hija, r.conname, r.columna, r.padre, r.columna_padre);
  END LOOP;
END $$;

-- Un usuario se desactiva, no se borra: su nombre queda en la bitacora y en las decisiones.
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS activo BOOLEAN NOT NULL DEFAULT true;
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS desactivado_at TIMESTAMPTZ;

CREATE OR REPLACE FUNCTION public.d6_rol_real(p_roles public.d6_role[])
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT auth.uid() IS NOT NULL
     AND EXISTS (SELECT 1 FROM public.user_profiles WHERE id = auth.uid() AND activo)
     AND EXISTS (SELECT 1 FROM public.user_role_assignments WHERE user_id = auth.uid() AND role = ANY (p_roles));
$$;

CREATE OR REPLACE FUNCTION public.d6_desactivar_usuario(p_user_id UUID, p_activo BOOLEAN DEFAULT false)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NOT public.has_d6_role(ARRAY['admin']::public.d6_role[]) THEN
    RAISE EXCEPTION 'Solo Administracion desactiva usuarios';
  END IF;
  IF p_user_id = auth.uid() AND NOT p_activo THEN
    RAISE EXCEPTION 'No puede desactivarse a usted mismo';
  END IF;
  UPDATE public.user_profiles SET activo = p_activo, desactivado_at = CASE WHEN p_activo THEN NULL ELSE now() END
  WHERE id = p_user_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Usuario no encontrado'; END IF;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.d6_desactivar_usuario(UUID, BOOLEAN) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.d6_desactivar_usuario(UUID, BOOLEAN) TO authenticated;
DROP TRIGGER IF EXISTS trg_user_profiles_audit ON public.user_profiles;
CREATE TRIGGER trg_user_profiles_audit AFTER INSERT OR UPDATE OR DELETE ON public.user_profiles
  FOR EACH ROW EXECUTE FUNCTION public.log_audit_changes();

-- ============================================================================
-- 4. Indices
-- ============================================================================
CREATE INDEX IF NOT EXISTS idx_ive_invitaciones_solicitud ON public.ive_invitaciones (solicitud_alta_id);
CREATE INDEX IF NOT EXISTS idx_solicitud_revisiones_solicitud ON public.solicitud_revisiones (solicitud_alta_id);
CREATE INDEX IF NOT EXISTS idx_pagos_estado_cuenta ON public.pagos (estado_cuenta_id);
CREATE INDEX IF NOT EXISTS idx_documentos_reclamo ON public.documentos (reclamo_id);
CREATE INDEX IF NOT EXISTS idx_partidas_fianza ON public.estado_cuenta_items_d6 (fianza_id);
CREATE INDEX IF NOT EXISTS idx_solicitudes_alta_cliente ON public.solicitudes_alta (cliente_id);
CREATE INDEX IF NOT EXISTS idx_audit_log_clave ON public.audit_log (table_name, created_at DESC);

-- Duplicados de restricciones UNIQUE que ya indexan lo mismo.
DROP INDEX IF EXISTS public.idx_clientes_codigo;
DROP INDEX IF EXISTS public.idx_beneficiarios_codigo;
DROP INDEX IF EXISTS public.idx_fianzas_fianza_endoso;

-- Un usuario no se reactiva a si mismo editando su perfil.
CREATE OR REPLACE FUNCTION public.d6_proteger_perfil()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF (NEW.role IS DISTINCT FROM OLD.role
      OR NEW.agente_id IS DISTINCT FROM OLD.agente_id
      OR NEW.email IS DISTINCT FROM OLD.email
      OR NEW.activo IS DISTINCT FROM OLD.activo
      OR NEW.desactivado_at IS DISTINCT FROM OLD.desactivado_at)
     AND COALESCE(auth.role(), '') IN ('authenticated', 'anon')
     AND NOT public.has_d6_role(ARRAY['admin']::public.d6_role[]) THEN
    RAISE EXCEPTION 'Solo un administrador puede cambiar el rol, el agente, el correo o el estado de un usuario';
  END IF;
  RETURN NEW;
END;
$$;
