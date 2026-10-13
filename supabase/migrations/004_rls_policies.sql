-- Migration 004: Row Level Security (RLS) Policies
-- Project: Fidelis D6 Consignación
-- Description: Enables RLS on all tables and creates granular access control policies for admin, operaciones, agente, and beneficiario.

-- Estas funciones deben existir antes de definir las polÃ­ticas que las usan.
-- Se mantienen tambiÃ©n en la migraciÃ³n 005 como CREATE OR REPLACE para
-- instalaciones ya existentes y para conservar la evoluciÃ³n del esquema.
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

-- Habilitar RLS en todas las tablas
ALTER TABLE public.user_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.grupos_beneficiarios ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.beneficiarios ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.grupo_beneficiario_rel ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_grupos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.clientes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.agentes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fianzas ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.solicitudes_alta ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.solicitudes_baja ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.documentos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pagos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.conciliaciones ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notificaciones ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_log ENABLE ROW LEVEL SECURITY;

-- ============================================================================
-- 1. POLÍTICAS PARA USER_PROFILES
-- ============================================================================
DROP POLICY IF EXISTS "Admin y Operaciones gestionan todos los perfiles" ON public.user_profiles;
CREATE POLICY "Admin y Operaciones gestionan todos los perfiles"
ON public.user_profiles FOR ALL
USING (public.get_user_role(auth.uid()) IN ('admin', 'operaciones'));

DROP POLICY IF EXISTS "Usuarios ven su propio perfil" ON public.user_profiles;
CREATE POLICY "Usuarios ven su propio perfil"
ON public.user_profiles FOR SELECT
USING (id = auth.uid());

-- ============================================================================
-- 2. POLÍTICAS PARA GRUPOS Y RELACIONES
-- ============================================================================
DROP POLICY IF EXISTS "Admin y Operaciones gestionan grupos" ON public.grupos_beneficiarios;
CREATE POLICY "Admin y Operaciones gestionan grupos"
ON public.grupos_beneficiarios FOR ALL
USING (public.get_user_role(auth.uid()) IN ('admin', 'operaciones'));

DROP POLICY IF EXISTS "Beneficiarios ven sus grupos asignados" ON public.grupos_beneficiarios;
CREATE POLICY "Beneficiarios ven sus grupos asignados"
ON public.grupos_beneficiarios FOR SELECT
USING (
    id IN (SELECT grupo_id FROM public.user_grupos WHERE user_id = auth.uid())
);

DROP POLICY IF EXISTS "Admin y Operaciones gestionan grupo_beneficiario_rel" ON public.grupo_beneficiario_rel;
CREATE POLICY "Admin y Operaciones gestionan grupo_beneficiario_rel"
ON public.grupo_beneficiario_rel FOR ALL
USING (public.get_user_role(auth.uid()) IN ('admin', 'operaciones'));

DROP POLICY IF EXISTS "Admin y Operaciones gestionan user_grupos" ON public.user_grupos;
CREATE POLICY "Admin y Operaciones gestionan user_grupos"
ON public.user_grupos FOR ALL
USING (public.get_user_role(auth.uid()) IN ('admin', 'operaciones'));

DROP POLICY IF EXISTS "Usuarios ven sus asignaciones de grupo" ON public.user_grupos;
CREATE POLICY "Usuarios ven sus asignaciones de grupo"
ON public.user_grupos FOR SELECT
USING (user_id = auth.uid());

-- ============================================================================
-- 3. POLÍTICAS PARA BENEFICIARIOS
-- ============================================================================
DROP POLICY IF EXISTS "Admin y Operaciones gestionan beneficiarios" ON public.beneficiarios;
CREATE POLICY "Admin y Operaciones gestionan beneficiarios"
ON public.beneficiarios FOR ALL
USING (public.get_user_role(auth.uid()) IN ('admin', 'operaciones'));

DROP POLICY IF EXISTS "Agentes ven todos los beneficiarios" ON public.beneficiarios;
CREATE POLICY "Agentes ven todos los beneficiarios"
ON public.beneficiarios FOR SELECT
USING (public.get_user_role(auth.uid()) = 'agente');

DROP POLICY IF EXISTS "Beneficiarios ven sus propios registros" ON public.beneficiarios;
CREATE POLICY "Beneficiarios ven sus propios registros"
ON public.beneficiarios FOR SELECT
USING (
    id IN (SELECT public.get_user_beneficiario_ids(auth.uid()))
);

-- ============================================================================
-- 4. POLÍTICAS PARA CLIENTES
-- ============================================================================
DROP POLICY IF EXISTS "Admin y Operaciones gestionan clientes" ON public.clientes;
CREATE POLICY "Admin y Operaciones gestionan clientes"
ON public.clientes FOR ALL
USING (public.get_user_role(auth.uid()) IN ('admin', 'operaciones'));

DROP POLICY IF EXISTS "Usuarios autenticados ven clientes" ON public.clientes;
CREATE POLICY "Usuarios autenticados ven clientes"
ON public.clientes FOR SELECT
USING (auth.role() = 'authenticated');

-- ============================================================================
-- 5. POLÍTICAS PARA AGENTES
-- ============================================================================
DROP POLICY IF EXISTS "Admin y Operaciones gestionan agentes" ON public.agentes;
CREATE POLICY "Admin y Operaciones gestionan agentes"
ON public.agentes FOR ALL
USING (public.get_user_role(auth.uid()) IN ('admin', 'operaciones'));

DROP POLICY IF EXISTS "Agentes ven su propia informacion" ON public.agentes;
CREATE POLICY "Agentes ven su propia informacion"
ON public.agentes FOR SELECT
USING (
    id = (SELECT agente_id FROM public.user_profiles WHERE id = auth.uid())
);

-- ============================================================================
-- 6. POLÍTICAS PARA FIANZAS
-- ============================================================================
DROP POLICY IF EXISTS "Admin y Operaciones gestionan fianzas" ON public.fianzas;
CREATE POLICY "Admin y Operaciones gestionan fianzas"
ON public.fianzas FOR ALL
USING (public.get_user_role(auth.uid()) IN ('admin', 'operaciones'));

DROP POLICY IF EXISTS "Agentes ven sus fianzas asignadas" ON public.fianzas;
CREATE POLICY "Agentes ven sus fianzas asignadas"
ON public.fianzas FOR SELECT
USING (
    agente_id = (SELECT agente_id FROM public.user_profiles WHERE id = auth.uid())
);

DROP POLICY IF EXISTS "Beneficiarios ven sus fianzas asignadas" ON public.fianzas;
CREATE POLICY "Beneficiarios ven sus fianzas asignadas"
ON public.fianzas FOR SELECT
USING (
    beneficiario_id IN (SELECT public.get_user_beneficiario_ids(auth.uid()))
);

-- ============================================================================
-- 7. POLÍTICAS PARA SOLICITUDES DE ALTA
-- ============================================================================
DROP POLICY IF EXISTS "Admin y Operaciones gestionan solicitudes alta" ON public.solicitudes_alta;
CREATE POLICY "Admin y Operaciones gestionan solicitudes alta"
ON public.solicitudes_alta FOR ALL
USING (public.get_user_role(auth.uid()) IN ('admin', 'operaciones'));

DROP POLICY IF EXISTS "Beneficiarios ven y crean sus solicitudes alta" ON public.solicitudes_alta;
CREATE POLICY "Beneficiarios ven y crean sus solicitudes alta"
ON public.solicitudes_alta FOR ALL
USING (
    beneficiario_id IN (SELECT public.get_user_beneficiario_ids(auth.uid()))
)
WITH CHECK (
    beneficiario_id IN (SELECT public.get_user_beneficiario_ids(auth.uid()))
);

DROP POLICY IF EXISTS "Agentes ven solicitudes alta" ON public.solicitudes_alta;
CREATE POLICY "Agentes ven solicitudes alta"
ON public.solicitudes_alta FOR SELECT
USING (public.get_user_role(auth.uid()) = 'agente');

-- ============================================================================
-- 8. POLÍTICAS PARA SOLICITUDES DE BAJA
-- ============================================================================
DROP POLICY IF EXISTS "Admin y Operaciones gestionan solicitudes baja" ON public.solicitudes_baja;
CREATE POLICY "Admin y Operaciones gestionan solicitudes baja"
ON public.solicitudes_baja FOR ALL
USING (public.get_user_role(auth.uid()) IN ('admin', 'operaciones'));

DROP POLICY IF EXISTS "Beneficiarios ven y crean sus solicitudes baja" ON public.solicitudes_baja;
CREATE POLICY "Beneficiarios ven y crean sus solicitudes baja"
ON public.solicitudes_baja FOR ALL
USING (
    fianza_id IN (
        SELECT id FROM public.fianzas 
        WHERE beneficiario_id IN (SELECT public.get_user_beneficiario_ids(auth.uid()))
    )
)
WITH CHECK (
    fianza_id IN (
        SELECT id FROM public.fianzas 
        WHERE beneficiario_id IN (SELECT public.get_user_beneficiario_ids(auth.uid()))
    )
);

-- ============================================================================
-- 9. POLÍTICAS PARA DOCUMENTOS
-- ============================================================================
DROP POLICY IF EXISTS "Admin y Operaciones gestionan documentos" ON public.documentos;
CREATE POLICY "Admin y Operaciones gestionan documentos"
ON public.documentos FOR ALL
USING (public.get_user_role(auth.uid()) IN ('admin', 'operaciones'));

DROP POLICY IF EXISTS "Usuarios autenticados ven y cargan documentos autorizados" ON public.documentos;
CREATE POLICY "Usuarios autenticados ven y cargan documentos autorizados"
ON public.documentos FOR ALL
USING (auth.role() = 'authenticated')
WITH CHECK (auth.role() = 'authenticated');

-- ============================================================================
-- 10. POLÍTICAS PARA PAGOS Y CONCILIACIONES
-- ============================================================================
DROP POLICY IF EXISTS "Admin y Operaciones gestionan pagos" ON public.pagos;
CREATE POLICY "Admin y Operaciones gestionan pagos"
ON public.pagos FOR ALL
USING (public.get_user_role(auth.uid()) IN ('admin', 'operaciones'));

DROP POLICY IF EXISTS "Beneficiarios ven pagos de sus fianzas" ON public.pagos;
CREATE POLICY "Beneficiarios ven pagos de sus fianzas"
ON public.pagos FOR SELECT
USING (
    fianza_id IN (
        SELECT id FROM public.fianzas 
        WHERE beneficiario_id IN (SELECT public.get_user_beneficiario_ids(auth.uid()))
    )
);

DROP POLICY IF EXISTS "Admin y Operaciones gestionan conciliaciones" ON public.conciliaciones;
CREATE POLICY "Admin y Operaciones gestionan conciliaciones"
ON public.conciliaciones FOR ALL
USING (public.get_user_role(auth.uid()) IN ('admin', 'operaciones'));

-- ============================================================================
-- 11. POLÍTICAS PARA NOTIFICACIONES
-- ============================================================================
DROP POLICY IF EXISTS "Usuarios gestionan sus notificaciones" ON public.notificaciones;
CREATE POLICY "Usuarios gestionan sus notificaciones"
ON public.notificaciones FOR ALL
USING (user_id = auth.uid());

-- ============================================================================
-- 12. POLÍTICAS PARA AUDIT_LOG (INMUTABLE)
-- ============================================================================
DROP POLICY IF EXISTS "Admin y Operaciones ven audit log" ON public.audit_log;
CREATE POLICY "Admin y Operaciones ven audit log"
ON public.audit_log FOR SELECT
USING (public.get_user_role(auth.uid()) IN ('admin', 'operaciones'));
