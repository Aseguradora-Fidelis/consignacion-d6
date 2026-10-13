-- Migration 003: Indexes for Fast Search, Filtering, and Pagination
-- Project: Fidelis D6 Consignación

-- 1. Índices para la tabla fianzas
CREATE INDEX IF NOT EXISTS idx_fianzas_beneficiario_id ON public.fianzas(beneficiario_id);
CREATE INDEX IF NOT EXISTS idx_fianzas_cliente_id ON public.fianzas(cliente_id);
CREATE INDEX IF NOT EXISTS idx_fianzas_agente_id ON public.fianzas(agente_id);
CREATE INDEX IF NOT EXISTS idx_fianzas_status ON public.fianzas(status);
CREATE INDEX IF NOT EXISTS idx_fianzas_fianza_endoso ON public.fianzas(fianza, endoso);
CREATE INDEX IF NOT EXISTS idx_fianzas_vigencia ON public.fianzas(vigencia_desde, vigencia_hasta);
CREATE INDEX IF NOT EXISTS idx_fianzas_created_at ON public.fianzas(created_at DESC);

-- 2. Índices para la tabla beneficiarios
CREATE INDEX IF NOT EXISTS idx_beneficiarios_codigo ON public.beneficiarios(codigo_contacto);
CREATE INDEX IF NOT EXISTS idx_beneficiarios_nombre ON public.beneficiarios(nombre);

-- 3. Índices para la tabla clientes
CREATE INDEX IF NOT EXISTS idx_clientes_codigo ON public.clientes(codigo_contacto);
CREATE INDEX IF NOT EXISTS idx_clientes_nombre ON public.clientes(nombre);
CREATE INDEX IF NOT EXISTS idx_clientes_nit ON public.clientes(nit);

-- 4. Índices para relaciones de grupos
CREATE INDEX IF NOT EXISTS idx_gbr_grupo_id ON public.grupo_beneficiario_rel(grupo_id);
CREATE INDEX IF NOT EXISTS idx_gbr_beneficiario_id ON public.grupo_beneficiario_rel(beneficiario_id);
CREATE INDEX IF NOT EXISTS idx_user_grupos_user_id ON public.user_grupos(user_id);
CREATE INDEX IF NOT EXISTS idx_user_grupos_grupo_id ON public.user_grupos(grupo_id);

-- 5. Índices para solicitudes de alta
CREATE INDEX IF NOT EXISTS idx_sol_alta_beneficiario ON public.solicitudes_alta(beneficiario_id);
CREATE INDEX IF NOT EXISTS idx_sol_alta_estado ON public.solicitudes_alta(estado);
CREATE INDEX IF NOT EXISTS idx_sol_alta_creado_por ON public.solicitudes_alta(creado_por);
CREATE INDEX IF NOT EXISTS idx_sol_alta_created_at ON public.solicitudes_alta(created_at DESC);

-- 6. Índices para solicitudes de baja
CREATE INDEX IF NOT EXISTS idx_sol_baja_fianza ON public.solicitudes_baja(fianza_id);
CREATE INDEX IF NOT EXISTS idx_sol_baja_estado ON public.solicitudes_baja(estado);
CREATE INDEX IF NOT EXISTS idx_sol_baja_solicitado_por ON public.solicitudes_baja(solicitado_por);
CREATE INDEX IF NOT EXISTS idx_sol_baja_created_at ON public.solicitudes_baja(created_at DESC);

-- 7. Índices para documentos
CREATE INDEX IF NOT EXISTS idx_documentos_alta ON public.documentos(solicitud_alta_id);
CREATE INDEX IF NOT EXISTS idx_documentos_baja ON public.documentos(solicitud_baja_id);
CREATE INDEX IF NOT EXISTS idx_documentos_fianza ON public.documentos(fianza_id);
CREATE INDEX IF NOT EXISTS idx_documentos_categoria ON public.documentos(categoria);

-- 8. Índices para pagos y conciliaciones
CREATE INDEX IF NOT EXISTS idx_pagos_fianza ON public.pagos(fianza_id);
CREATE INDEX IF NOT EXISTS idx_pagos_estado ON public.pagos(estado);
CREATE INDEX IF NOT EXISTS idx_conciliaciones_pago ON public.conciliaciones(pago_id);
CREATE INDEX IF NOT EXISTS idx_conciliaciones_fianza ON public.conciliaciones(fianza_id);

-- 9. Índices para notificaciones
CREATE INDEX IF NOT EXISTS idx_notif_user_leido ON public.notificaciones(user_id, leido);

-- 10. Índices para audit log
CREATE INDEX IF NOT EXISTS idx_audit_table_record ON public.audit_log(table_name, record_id);
CREATE INDEX IF NOT EXISTS idx_audit_created_at ON public.audit_log(created_at DESC);
