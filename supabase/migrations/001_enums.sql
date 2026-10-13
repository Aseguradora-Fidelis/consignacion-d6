-- Migration 001: Enum Types Definition
-- Project: Fidelis D6 Consignación
-- Description: Defines all custom ENUM types required by the system with idempotency.

DO $$ 
BEGIN
    -- 1. Roles de usuario en el sistema
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'app_role') THEN
        CREATE TYPE app_role AS ENUM ('admin', 'operaciones', 'agente', 'beneficiario');
    END IF;

    -- 2. Estado de la fianza / póliza
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'fianza_status') THEN
        CREATE TYPE fianza_status AS ENUM ('VIGENTE', 'CANCELADA', 'ANULADA', 'VENCIDA', 'EN_TRAMITE');
    END IF;

    -- 3. Estado de pagos asociados
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'estado_pago') THEN
        CREATE TYPE estado_pago AS ENUM ('PENDIENTE', 'PAGADO', 'PARCIAL', 'VENCIDO', 'CANCELADO');
    END IF;

    -- 4. Estado de solicitudes de alta y baja
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'estado_solicitud') THEN
        CREATE TYPE estado_solicitud AS ENUM ('BORRADOR', 'PENDIENTE_REVISION', 'APROBADA', 'RECHAZADA', 'CANCELADA');
    END IF;

    -- 5. Motivo/tipo de baja de fianza
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'tipo_baja') THEN
        CREATE TYPE tipo_baja AS ENUM ('DEVOLUCION_MERCADERIA', 'VENTA_EFECTUADA', 'SUSTITUCION_POLIZA', 'VENCIMIENTO_PLAZO', 'OTRO');
    END IF;

    -- 6. Categoría de documentos cargados
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'doc_categoria') THEN
        CREATE TYPE doc_categoria AS ENUM (
            'IVE_IR_01',
            'IVE_IR_02',
            'ESTADO_CUENTA',
            'FORMULARIO_FIDELIS',
            'APROBACION_FIANZA',
            'DOCUMENTO_LEGAL',
            'RECIBO_PAGO',
            'FINIQUITO',
            'OTRO'
        );
    END IF;

    -- 7. Tipo de persona (individual vs jurídica)
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'tipo_persona') THEN
        CREATE TYPE tipo_persona AS ENUM ('INDIVIDUAL', 'JURIDICA');
    END IF;

    -- 8. Estado del registro de pago
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'estado_pago_registro') THEN
        CREATE TYPE estado_pago_registro AS ENUM ('PENDIENTE', 'CONCILIADO', 'DISCREPANCIA', 'RECHAZADO');
    END IF;

    -- 9. Resultado de la conciliación bancaria
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'resultado_conciliacion') THEN
        CREATE TYPE resultado_conciliacion AS ENUM (
            'CONCILIADO_EXACTO',
            'DISCREPANCIA_MONTO',
            'DISCREPANCIA_REFERENCIA',
            'NO_ENCONTRADO',
            'PENDIENTE'
        );
    END IF;
END $$;
