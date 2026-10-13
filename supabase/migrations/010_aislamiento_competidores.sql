-- Aislamiento estricto entre marcas competidoras (por ejemplo ADMOSA y Grupo UMA).
-- El personal de la aseguradora conserva acceso operativo; una marca solo ve su propia cartera.
-- Esta migracion es exclusivamente hacia adelante y revoca las politicas autenticadas amplias.

CREATE OR REPLACE FUNCTION public.d6_es_personal_aseguradora()
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT public.get_user_role(auth.uid()) IN ('admin', 'operaciones', 'agente')
    OR public.has_d6_role(ARRAY[
      'admin', 'comercial', 'suscripcion', 'coordinacion_comercial', 'cobros', 'contabilidad'
    ]::public.d6_role[]);
$$;

CREATE OR REPLACE FUNCTION public.d6_puede_ver_beneficiario(p_beneficiario_id UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT p_beneficiario_id IS NOT NULL
    AND (
      public.d6_es_personal_aseguradora()
      OR p_beneficiario_id IN (SELECT beneficiario_id FROM public.get_user_beneficiario_ids(auth.uid()))
    );
$$;

CREATE OR REPLACE FUNCTION public.d6_puede_ver_documento(p_documento_id UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT public.d6_es_personal_aseguradora()
    OR EXISTS (
      SELECT 1
      FROM public.documentos d
      LEFT JOIN public.fianzas f ON f.id = d.fianza_id
      LEFT JOIN public.solicitudes_alta sa ON sa.id = d.solicitud_alta_id
      LEFT JOIN public.solicitudes_baja sb ON sb.id = d.solicitud_baja_id
      LEFT JOIN public.fianzas fb ON fb.id = sb.fianza_id
      WHERE d.id = p_documento_id
        AND public.d6_puede_ver_beneficiario(COALESCE(f.beneficiario_id, sa.beneficiario_id, fb.beneficiario_id))
    );
$$;

-- Los perfiles de una marca no pueden enumerar afianzados de otra marca.
DROP POLICY IF EXISTS "Usuarios autenticados ven clientes" ON public.clientes;
CREATE POLICY "D6 personal gestiona clientes"
ON public.clientes FOR ALL
USING (public.d6_es_personal_aseguradora())
WITH CHECK (public.d6_es_personal_aseguradora());

CREATE POLICY "Marcas ven solo sus afianzados relacionados"
ON public.clientes FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM public.fianzas f
    WHERE f.cliente_id = clientes.id
      AND public.d6_puede_ver_beneficiario(f.beneficiario_id)
  )
  OR EXISTS (
    SELECT 1 FROM public.solicitudes_alta sa
    WHERE sa.cliente_id = clientes.id
      AND public.d6_puede_ver_beneficiario(sa.beneficiario_id)
  )
);

CREATE POLICY "D6 personal ve marcas"
ON public.beneficiarios FOR SELECT
USING (public.d6_es_personal_aseguradora());

-- Comercial crea altas; las marcas solo pueden consultar las propias, no crear expedientes.
DROP POLICY IF EXISTS "Beneficiarios ven y crean sus solicitudes alta" ON public.solicitudes_alta;
CREATE POLICY "Marcas ven solo sus solicitudes alta"
ON public.solicitudes_alta FOR SELECT
USING (public.d6_puede_ver_beneficiario(beneficiario_id));

CREATE POLICY "D6 personal gestiona solicitudes baja"
ON public.solicitudes_baja FOR ALL
USING (public.d6_es_personal_aseguradora())
WITH CHECK (public.d6_es_personal_aseguradora());

CREATE POLICY "D6 cobros gestiona pagos"
ON public.pagos FOR ALL
USING (public.has_d6_role(ARRAY['admin', 'cobros', 'contabilidad']::public.d6_role[]))
WITH CHECK (public.has_d6_role(ARRAY['admin', 'cobros', 'contabilidad']::public.d6_role[]));

-- Revoca la lectura/escritura global de documentos. Una marca puede leer metadatos
-- solo de expedientes vinculados a su propio beneficiario; las cargas quedan en manos
-- del personal asegurador hasta exponer un endpoint de carga firmado y validado.
DROP POLICY IF EXISTS "Usuarios autenticados ven y cargan documentos autorizados" ON public.documentos;
CREATE POLICY "D6 personal gestiona documentos"
ON public.documentos FOR ALL
USING (public.d6_es_personal_aseguradora())
WITH CHECK (public.d6_es_personal_aseguradora());

CREATE POLICY "Marcas ven documentos de su cartera"
ON public.documentos FOR SELECT
USING (public.d6_puede_ver_documento(id));

-- Estados de cuenta y sus partidas siguen el mismo aislamiento de beneficiario.
CREATE POLICY "Marcas ven sus estados de cuenta"
ON public.estados_cuenta_d6 FOR SELECT
USING (public.d6_puede_ver_beneficiario(beneficiario_id));

CREATE POLICY "Marcas ven partidas de sus estados de cuenta"
ON public.estado_cuenta_items_d6 FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM public.estados_cuenta_d6 ec
    WHERE ec.id = estado_cuenta_items_d6.estado_cuenta_id
      AND public.d6_puede_ver_beneficiario(ec.beneficiario_id)
  )
);

-- Storage privado: se elimina el acceso de cualquier usuario autenticado.
-- La lectura de un archivo exige que exista un registro documental visible para la marca.
DROP POLICY IF EXISTS "Usuarios autenticados pueden ver expedientes" ON storage.objects;
DROP POLICY IF EXISTS "Usuarios autenticados pueden subir expedientes" ON storage.objects;
DROP POLICY IF EXISTS "Usuarios pueden actualizar sus propios expedientes" ON storage.objects;
DROP POLICY IF EXISTS "Usuarios pueden eliminar sus propios expedientes" ON storage.objects;

CREATE POLICY "D6 personal administra archivos de expedientes"
ON storage.objects FOR ALL
USING (bucket_id = 'expedientes' AND public.d6_es_personal_aseguradora())
WITH CHECK (bucket_id = 'expedientes' AND public.d6_es_personal_aseguradora());

CREATE POLICY "Marcas descargan solo archivos de su cartera"
ON storage.objects FOR SELECT
USING (
  bucket_id = 'expedientes'
  AND EXISTS (
    SELECT 1 FROM public.documentos d
    WHERE d.file_path = storage.objects.name
      AND public.d6_puede_ver_documento(d.id)
  )
);

COMMENT ON FUNCTION public.d6_puede_ver_beneficiario(UUID) IS
  'Barrera de tenant: evita que un beneficiario vea datos de otra marca competidora.';
