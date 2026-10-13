-- Migration 005: Functions, Triggers, and Security Helpers
-- Project: Fidelis D6 Consignación

-- 1. Helper Function: Obtener el rol del usuario actual
CREATE OR REPLACE FUNCTION public.get_user_role(p_user_id UUID DEFAULT auth.uid())
RETURNS app_role
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
    v_role app_role;
BEGIN
    IF p_user_id IS NULL THEN
        RETURN 'beneficiario'::app_role;
    END IF;

    SELECT role INTO v_role
    FROM public.user_profiles
    WHERE id = p_user_id;

    RETURN COALESCE(v_role, 'beneficiario'::app_role);
END;
$$;

-- 2. Helper Function: Obtener IDs de beneficiarios asignados al usuario (directa o mediante grupo)
CREATE OR REPLACE FUNCTION public.get_user_beneficiario_ids(p_user_id UUID DEFAULT auth.uid())
RETURNS TABLE(beneficiario_id UUID)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
BEGIN
    IF p_user_id IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT DISTINCT gbr.beneficiario_id
    FROM public.user_grupos ug
    JOIN public.grupo_beneficiario_rel gbr ON gbr.grupo_id = ug.grupo_id
    WHERE ug.user_id = p_user_id;
END;
$$;

-- 3. Trigger Function: Crear perfil automáticamente al crear un auth.user
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    INSERT INTO public.user_profiles (id, email, full_name, role)
    VALUES (
        NEW.id,
        NEW.email,
        COALESCE(NEW.raw_user_meta_data->>'full_name', NEW.email),
        COALESCE((NEW.raw_user_meta_data->>'role')::app_role, 'beneficiario'::app_role)
    )
    ON CONFLICT (id) DO UPDATE SET
        email = EXCLUDED.email,
        full_name = EXCLUDED.full_name;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- 4. Trigger Function: Actualizar automáticamente el campo updated_at
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

-- Aplicar trigger updated_at a tablas relevantes
DROP TRIGGER IF EXISTS trg_user_profiles_updated_at ON public.user_profiles;
CREATE TRIGGER trg_user_profiles_updated_at BEFORE UPDATE ON public.user_profiles FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

DROP TRIGGER IF EXISTS trg_grupos_beneficiarios_updated_at ON public.grupos_beneficiarios;
CREATE TRIGGER trg_grupos_beneficiarios_updated_at BEFORE UPDATE ON public.grupos_beneficiarios FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

DROP TRIGGER IF EXISTS trg_beneficiarios_updated_at ON public.beneficiarios;
CREATE TRIGGER trg_beneficiarios_updated_at BEFORE UPDATE ON public.beneficiarios FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

DROP TRIGGER IF EXISTS trg_clientes_updated_at ON public.clientes;
CREATE TRIGGER trg_clientes_updated_at BEFORE UPDATE ON public.clientes FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

DROP TRIGGER IF EXISTS trg_agentes_updated_at ON public.agentes;
CREATE TRIGGER trg_agentes_updated_at BEFORE UPDATE ON public.agentes FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

DROP TRIGGER IF EXISTS trg_fianzas_updated_at ON public.fianzas;
CREATE TRIGGER trg_fianzas_updated_at BEFORE UPDATE ON public.fianzas FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

DROP TRIGGER IF EXISTS trg_solicitudes_alta_updated_at ON public.solicitudes_alta;
CREATE TRIGGER trg_solicitudes_alta_updated_at BEFORE UPDATE ON public.solicitudes_alta FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

DROP TRIGGER IF EXISTS trg_solicitudes_baja_updated_at ON public.solicitudes_baja;
CREATE TRIGGER trg_solicitudes_baja_updated_at BEFORE UPDATE ON public.solicitudes_baja FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

DROP TRIGGER IF EXISTS trg_pagos_updated_at ON public.pagos;
CREATE TRIGGER trg_pagos_updated_at BEFORE UPDATE ON public.pagos FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- 5. Trigger Function: Auditoría Inmutable (audit_log)
CREATE OR REPLACE FUNCTION public.log_audit_changes()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        INSERT INTO public.audit_log (table_name, record_id, action, old_data, performed_by)
        VALUES (TG_TABLE_NAME, OLD.id, 'DELETE', to_jsonb(OLD), auth.uid());
        RETURN OLD;
    ELSIF TG_OP = 'UPDATE' THEN
        INSERT INTO public.audit_log (table_name, record_id, action, old_data, new_data, performed_by)
        VALUES (TG_TABLE_NAME, NEW.id, 'UPDATE', to_jsonb(OLD), to_jsonb(NEW), auth.uid());
        RETURN NEW;
    ELSIF TG_OP = 'INSERT' THEN
        INSERT INTO public.audit_log (table_name, record_id, action, new_data, performed_by)
        VALUES (TG_TABLE_NAME, NEW.id, 'INSERT', to_jsonb(NEW), auth.uid());
        RETURN NEW;
    END IF;
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_fianzas_audit ON public.fianzas;
CREATE TRIGGER trg_fianzas_audit AFTER INSERT OR UPDATE OR DELETE ON public.fianzas FOR EACH ROW EXECUTE FUNCTION public.log_audit_changes();

DROP TRIGGER IF EXISTS trg_solicitudes_alta_audit ON public.solicitudes_alta;
CREATE TRIGGER trg_solicitudes_alta_audit AFTER INSERT OR UPDATE OR DELETE ON public.solicitudes_alta FOR EACH ROW EXECUTE FUNCTION public.log_audit_changes();

DROP TRIGGER IF EXISTS trg_solicitudes_baja_audit ON public.solicitudes_baja;
CREATE TRIGGER trg_solicitudes_baja_audit AFTER INSERT OR UPDATE OR DELETE ON public.solicitudes_baja FOR EACH ROW EXECUTE FUNCTION public.log_audit_changes();

DROP TRIGGER IF EXISTS trg_pagos_audit ON public.pagos;
CREATE TRIGGER trg_pagos_audit AFTER INSERT OR UPDATE OR DELETE ON public.pagos FOR EACH ROW EXECUTE FUNCTION public.log_audit_changes();

-- 6. Trigger Function: Generación de Notificaciones de cambio de estado
CREATE OR REPLACE FUNCTION public.notify_on_solicitud_status_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_user_id UUID;
    v_msg TEXT;
BEGIN
    IF (OLD.estado IS DISTINCT FROM NEW.estado) THEN
        v_user_id := COALESCE(NEW.creado_por, NEW.solicitado_por);
        v_msg := 'La solicitud ' || NEW.numero_solicitud || ' cambió de estado a: ' || NEW.estado;
        
        IF v_user_id IS NOT NULL THEN
            INSERT INTO public.notificaciones (user_id, titulo, mensaje, link)
            VALUES (v_user_id, 'Actualización de Solicitud', v_msg, '/solicitudes/' || NEW.id);
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_sol_alta ON public.solicitudes_alta;
CREATE TRIGGER trg_notify_sol_alta AFTER UPDATE ON public.solicitudes_alta FOR EACH ROW EXECUTE FUNCTION public.notify_on_solicitud_status_change();

DROP TRIGGER IF EXISTS trg_notify_sol_baja ON public.solicitudes_baja;
CREATE TRIGGER trg_notify_sol_baja AFTER UPDATE ON public.solicitudes_baja FOR EACH ROW EXECUTE FUNCTION public.notify_on_solicitud_status_change();
