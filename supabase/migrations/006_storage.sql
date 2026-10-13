-- Migration 006: Storage Configuration and RLS Policies for 'expedientes'
-- Project: Fidelis D6 Consignación

-- 1. Crear / actualizar configuración del bucket privado 'expedientes'
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'expedientes',
    'expedientes',
    false,
    52428800, -- Limit 50MB
    ARRAY['application/pdf', 'image/png', 'image/jpeg']
)
ON CONFLICT (id) DO UPDATE SET
    public = false,
    file_size_limit = 52428800,
    allowed_mime_types = ARRAY['application/pdf', 'image/png', 'image/jpeg'];

-- 2. Asegurar que RLS esté habilitado en storage.objects
-- storage.objects es administrada por Supabase y ya trae RLS habilitado.
-- No se altera la tabla porque su propietario es el rol interno de Storage.

-- 3. Políticas RLS para storage.objects en el bucket expedientes

DROP POLICY IF EXISTS "Admin y Operaciones tienen control total en expedientes" ON storage.objects;
CREATE POLICY "Admin y Operaciones tienen control total en expedientes"
ON storage.objects FOR ALL
USING (
    bucket_id = 'expedientes' AND
    public.get_user_role(auth.uid()) IN ('admin', 'operaciones')
)
WITH CHECK (
    bucket_id = 'expedientes' AND
    public.get_user_role(auth.uid()) IN ('admin', 'operaciones')
);

DROP POLICY IF EXISTS "Usuarios autenticados pueden ver expedientes" ON storage.objects;
CREATE POLICY "Usuarios autenticados pueden ver expedientes"
ON storage.objects FOR SELECT
USING (
    bucket_id = 'expedientes' AND
    auth.role() = 'authenticated'
);

DROP POLICY IF EXISTS "Usuarios autenticados pueden subir expedientes" ON storage.objects;
CREATE POLICY "Usuarios autenticados pueden subir expedientes"
ON storage.objects FOR INSERT
WITH CHECK (
    bucket_id = 'expedientes' AND
    auth.role() = 'authenticated'
);

DROP POLICY IF EXISTS "Usuarios pueden actualizar sus propios expedientes" ON storage.objects;
CREATE POLICY "Usuarios pueden actualizar sus propios expedientes"
ON storage.objects FOR UPDATE
USING (
    bucket_id = 'expedientes' AND
    auth.uid() = owner
);

DROP POLICY IF EXISTS "Usuarios pueden eliminar sus propios expedientes" ON storage.objects;
CREATE POLICY "Usuarios pueden eliminar sus propios expedientes"
ON storage.objects FOR DELETE
USING (
    bucket_id = 'expedientes' AND
    auth.uid() = owner
);
