-- Migration 002: Relational Tables Schema Definition
-- Project: Fidelis D6 Consignación
-- Description: Creates all 13 core relational tables plus notification and audit tables with PKs, FKs, constraints, and defaults.

-- 1. Agentes
CREATE TABLE IF NOT EXISTS public.agentes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    numero_agente INTEGER NOT NULL DEFAULT 0,
    indice_agente INTEGER NOT NULL DEFAULT 0,
    nombre TEXT NOT NULL,
    email TEXT,
    telefono TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_agente_num_idx_nombre UNIQUE (numero_agente, indice_agente, nombre)
);

-- 2. User Profiles (Extensión de auth.users)
CREATE TABLE IF NOT EXISTS public.user_profiles (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    email TEXT NOT NULL UNIQUE,
    full_name TEXT NOT NULL,
    role app_role NOT NULL DEFAULT 'beneficiario',
    agente_id UUID REFERENCES public.agentes(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 3. Grupos de Beneficiarios
CREATE TABLE IF NOT EXISTS public.grupos_beneficiarios (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    codigo TEXT NOT NULL UNIQUE,
    nombre TEXT NOT NULL,
    descripcion TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 4. Beneficiarios
CREATE TABLE IF NOT EXISTS public.beneficiarios (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    codigo_contacto INTEGER NOT NULL UNIQUE,
    nombre TEXT NOT NULL,
    nit TEXT,
    direccion TEXT,
    telefono TEXT,
    email TEXT,
    tipo_persona tipo_persona NOT NULL DEFAULT 'JURIDICA',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 5. Relación Grupo - Beneficiario (Muchos a Muchos)
CREATE TABLE IF NOT EXISTS public.grupo_beneficiario_rel (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    grupo_id UUID NOT NULL REFERENCES public.grupos_beneficiarios(id) ON DELETE CASCADE,
    beneficiario_id UUID NOT NULL REFERENCES public.beneficiarios(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_grupo_beneficiario UNIQUE (grupo_id, beneficiario_id)
);

-- 6. Relación Usuario - Grupos (Para permisos de usuarios tipo beneficiario)
CREATE TABLE IF NOT EXISTS public.user_grupos (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
    grupo_id UUID NOT NULL REFERENCES public.grupos_beneficiarios(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_user_grupo UNIQUE (user_id, grupo_id)
);

-- 7. Clientes / Afianzados
CREATE TABLE IF NOT EXISTS public.clientes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    codigo_contacto INTEGER NOT NULL UNIQUE,
    nombre TEXT NOT NULL,
    nit TEXT,
    tipo_persona tipo_persona NOT NULL DEFAULT 'INDIVIDUAL',
    direccion TEXT,
    telefono TEXT,
    email TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 8. Fianzas / Pólizas D-6
CREATE TABLE IF NOT EXISTS public.fianzas (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    ramo TEXT NOT NULL DEFAULT 'FIA',
    fianza BIGINT NOT NULL,
    endoso INTEGER NOT NULL DEFAULT 0,
    clase TEXT NOT NULL DEFAULT 'D-6',
    cliente_id UUID NOT NULL REFERENCES public.clientes(id) ON DELETE RESTRICT,
    beneficiario_id UUID NOT NULL REFERENCES public.beneficiarios(id) ON DELETE RESTRICT,
    agente_id UUID REFERENCES public.agentes(id) ON DELETE SET NULL,
    fecha_emision DATE,
    vigencia_desde DATE NOT NULL,
    vigencia_hasta DATE NOT NULL,
    fecha_cancelacion DATE,
    fecha_anulacion DATE,
    cod_estado_poliza TEXT,
    status_raw TEXT,
    status fianza_status NOT NULL DEFAULT 'VIGENTE',
    monto_afianzado NUMERIC(15,2) NOT NULL DEFAULT 0.00,
    prima NUMERIC(15,2) NOT NULL DEFAULT 0.00,
    derechos NUMERIC(15,2) NOT NULL DEFAULT 0.00,
    otros NUMERIC(15,2) DEFAULT 0.00,
    gastos_envio NUMERIC(15,2) DEFAULT 0.00,
    iva NUMERIC(15,2) DEFAULT 0.00,
    prima_anual NUMERIC(15,2) DEFAULT 0.00,
    contrato_numero TEXT,
    contrato_fecha DATE,
    contrato_valor NUMERIC(15,2) DEFAULT 0.00,
    tema_de_fianza TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_fianza_endoso UNIQUE (fianza, endoso)
);

-- 9. Solicitudes de Alta de Póliza
CREATE TABLE IF NOT EXISTS public.solicitudes_alta (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    numero_solicitud TEXT NOT NULL UNIQUE,
    cliente_id UUID REFERENCES public.clientes(id) ON DELETE SET NULL,
    cliente_nombre_tmp TEXT,
    cliente_nit_tmp TEXT,
    beneficiario_id UUID NOT NULL REFERENCES public.beneficiarios(id) ON DELETE RESTRICT,
    monto_solicitado NUMERIC(15,2) NOT NULL,
    vigencia_desde DATE NOT NULL,
    vigencia_hasta DATE NOT NULL,
    contrato_numero TEXT,
    contrato_fecha DATE,
    contrato_valor NUMERIC(15,2),
    tema_de_fianza TEXT,
    estado estado_solicitud NOT NULL DEFAULT 'BORRADOR',
    observaciones TEXT,
    creado_por UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
    revisado_por UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 10. Solicitudes de Baja / Cancelación
CREATE TABLE IF NOT EXISTS public.solicitudes_baja (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    numero_solicitud TEXT NOT NULL UNIQUE,
    fianza_id UUID NOT NULL REFERENCES public.fianzas(id) ON DELETE CASCADE,
    tipo_baja tipo_baja NOT NULL DEFAULT 'DEVOLUCION_MERCADERIA',
    motivo TEXT NOT NULL,
    estado estado_solicitud NOT NULL DEFAULT 'PENDIENTE_REVISION',
    observaciones TEXT,
    solicitado_por UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
    procesado_por UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 11. Documentos Expedientes
CREATE TABLE IF NOT EXISTS public.documentos (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    solicitud_alta_id UUID REFERENCES public.solicitudes_alta(id) ON DELETE CASCADE,
    solicitud_baja_id UUID REFERENCES public.solicitudes_baja(id) ON DELETE CASCADE,
    fianza_id UUID REFERENCES public.fianzas(id) ON DELETE CASCADE,
    categoria doc_categoria NOT NULL,
    nombre_archivo TEXT NOT NULL,
    file_path TEXT NOT NULL,
    file_size INTEGER,
    mime_type TEXT DEFAULT 'application/pdf',
    subido_por UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 12. Pagos de Fianzas
CREATE TABLE IF NOT EXISTS public.pagos (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    fianza_id UUID NOT NULL REFERENCES public.fianzas(id) ON DELETE CASCADE,
    numero_recibo TEXT,
    monto NUMERIC(15,2) NOT NULL,
    fecha_pago DATE NOT NULL,
    metodo_pago TEXT,
    referencia_bancaria TEXT,
    banco TEXT,
    comprobante_path TEXT,
    estado estado_pago_registro NOT NULL DEFAULT 'PENDIENTE',
    registrado_por UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 13. Conciliaciones Bancarias
CREATE TABLE IF NOT EXISTS public.conciliaciones (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    pago_id UUID REFERENCES public.pagos(id) ON DELETE SET NULL,
    fianza_id UUID NOT NULL REFERENCES public.fianzas(id) ON DELETE CASCADE,
    fecha_conciliacion TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    monto_esperado NUMERIC(15,2) NOT NULL,
    monto_recibido NUMERIC(15,2) NOT NULL,
    diferencia NUMERIC(15,2) GENERATED ALWAYS AS (monto_recibido - monto_esperado) STORED,
    resultado resultado_conciliacion NOT NULL DEFAULT 'PENDIENTE',
    notas TEXT,
    conciliado_por UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 14. Notificaciones
CREATE TABLE IF NOT EXISTS public.notificaciones (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
    titulo TEXT NOT NULL,
    mensaje TEXT NOT NULL,
    leido BOOLEAN NOT NULL DEFAULT FALSE,
    link TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 15. Audit Log (Inmutable)
CREATE TABLE IF NOT EXISTS public.audit_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    table_name TEXT NOT NULL,
    record_id UUID,
    action TEXT NOT NULL,
    old_data JSONB,
    new_data JSONB,
    performed_by UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
