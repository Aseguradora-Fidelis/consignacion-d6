-- Documentos que llegan en los expedientes reales y que el catalogo no tenia.
-- Origen: procedimiento "Fianzas en Consignacion" v01 y dos expedientes reales de referencia (sin datos en este repositorio).
-- Va en su propia migracion porque un valor de enum nuevo no se puede usar en la
-- misma transaccion en que se crea.
ALTER TYPE public.doc_categoria ADD VALUE IF NOT EXISTS 'ESTADO_PATRIMONIAL';
ALTER TYPE public.doc_categoria ADD VALUE IF NOT EXISTS 'ESTADOS_FINANCIEROS';
ALTER TYPE public.doc_categoria ADD VALUE IF NOT EXISTS 'RECIBO_SERVICIO';
ALTER TYPE public.doc_categoria ADD VALUE IF NOT EXISTS 'CARTA_INVESTIGACION';
ALTER TYPE public.doc_categoria ADD VALUE IF NOT EXISTS 'PAGO_ELECTRONICO';
ALTER TYPE public.doc_categoria ADD VALUE IF NOT EXISTS 'SOLICITUD_DISTRIBUCION';
ALTER TYPE public.doc_categoria ADD VALUE IF NOT EXISTS 'CARTA_BAJA';
