-- 033: expediente compartido entre la marca y el distribuidor.
-- La marca puede adelantar datos y subir documentos desde su portal, y ver lo que el
-- distribuidor va subiendo. Los dos editan el mismo borrador: cada uno manda solo lo que
-- cambio y el servidor lo combina. Firmar y enviar sigue siendo del distribuidor.
-- Cambia la decision del 17-09 ("la marca no sube al expediente") por pedido del 2026-10-08.

-- Quien suele entregar cada documento. La resolucion de credito es de la marca.
ALTER TABLE public.ive_requisitos_d6 ADD COLUMN IF NOT EXISTS responsable TEXT NOT NULL DEFAULT 'AFIANZADO';
ALTER TABLE public.ive_requisitos_d6 DROP CONSTRAINT IF EXISTS ive_requisitos_d6_responsable_check;
ALTER TABLE public.ive_requisitos_d6 ADD CONSTRAINT ive_requisitos_d6_responsable_check
  CHECK (responsable IN ('AFIANZADO', 'MARCA'));
UPDATE public.ive_requisitos_d6 SET responsable = 'MARCA',
  ayuda = 'Nota de resolución o solicitud de distribución. La sube la marca.'
WHERE categoria = 'APROBACION_FIANZA';

-- La lista de documentos no es sensible: la marca la necesita para avisarle al distribuidor.
DROP POLICY IF EXISTS "requisitos: usuarios leen los activos" ON public.ive_requisitos_d6;
CREATE POLICY "requisitos: usuarios leen los activos" ON public.ive_requisitos_d6 FOR SELECT
  TO authenticated USING (activo);

-- Documentos que faltan. Con p_solo_afianzado no cuenta lo que entrega la marca: el
-- distribuidor puede enviar aunque la marca no haya subido su resolucion. Suscripcion si la
-- exige para empezar la revision.
CREATE OR REPLACE FUNCTION public.d6_documentos_faltantes(p_solicitud_id UUID, p_solo_afianzado BOOLEAN)
RETURNS TABLE(categoria public.doc_categoria, nombre TEXT)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT r.categoria, r.nombre
  FROM public.solicitudes_alta sa
  JOIN public.ive_requisitos_d6 r ON r.tipo_persona = sa.tipo_persona AND r.activo AND r.obligatorio
  WHERE sa.id = p_solicitud_id
    AND (NOT p_solo_afianzado OR r.responsable = 'AFIANZADO')
    AND (NOT r.requiere_umbral_exposicion OR sa.requiere_documento_accesorio)
    AND NOT (r.categoria IN ('IVE_ASS_01', 'IVE_ASS_02') AND sa.ive_data IS NOT NULL)
    AND r.categoria NOT IN ('IVE_ASS_01', 'IVE_ASS_02')
    AND NOT EXISTS (
      SELECT 1 FROM public.documentos d
      WHERE d.solicitud_alta_id = sa.id AND d.categoria = r.categoria
        AND NOT d.carga_pendiente AND d.estado_revision <> 'RECHAZADO'
    )
  ORDER BY r.orden;
$$;
REVOKE EXECUTE ON FUNCTION public.d6_documentos_faltantes(UUID, BOOLEAN) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.d6_documentos_faltantes(UUID, BOOLEAN) TO authenticated;

CREATE OR REPLACE FUNCTION public.d6_documentos_faltantes(p_solicitud_id UUID)
RETURNS TABLE(categoria public.doc_categoria, nombre TEXT)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT * FROM public.d6_documentos_faltantes(p_solicitud_id, false);
$$;

-- El borrador se combina: quien guarda manda solo los campos que cambio.
CREATE OR REPLACE FUNCTION public.portal_ive_guardar_borrador(p_token TEXT, p_datos JSONB)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_sol public.solicitudes_alta;
BEGIN
  v_sol := public.d6_portal_solicitud(p_token);
  IF pg_column_size(p_datos) > 512000 THEN
    RAISE EXCEPTION 'El borrador es demasiado grande';
  END IF;
  UPDATE public.solicitudes_alta
  SET ive_borrador = COALESCE(ive_borrador, ive_data, '{}'::jsonb) || COALESCE(p_datos, '{}'::jsonb)
  WHERE id = v_sol.id;
END;
$$;

-- El distribuidor envia cuando estan sus documentos. Los de la marca no lo detienen.
CREATE OR REPLACE FUNCTION public.completar_ive_invitacion(p_token TEXT, p_datos JSONB)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_sol public.solicitudes_alta;
  v_inv public.ive_invitaciones;
  v_faltan TEXT;
BEGIN
  v_sol := public.d6_portal_solicitud(p_token);
  v_inv := public.d6_invitacion_por_token(p_token);
  PERFORM public.validar_datos_ive_d6(p_datos);
  IF (v_sol.tipo_persona = 'INDIVIDUAL' AND p_datos->>'tipoIve' NOT IN ('IVE-ASS-01', 'IVE-IR-01'))
     OR (v_sol.tipo_persona = 'JURIDICA' AND p_datos->>'tipoIve' NOT IN ('IVE-ASS-02', 'IVE-IR-02')) THEN
    RAISE EXCEPTION 'El formulario no corresponde al tipo de cliente del expediente';
  END IF;
  SELECT string_agg(nombre, ', ') INTO v_faltan FROM public.d6_documentos_faltantes(v_sol.id, true);
  IF v_faltan IS NOT NULL THEN
    RAISE EXCEPTION 'Faltan documentos: %', v_faltan;
  END IF;

  PERFORM 1 FROM public.ive_invitaciones WHERE id = v_inv.id FOR UPDATE;
  UPDATE public.solicitudes_alta
  SET ive_data = p_datos,
      ive_borrador = NULL,
      ive_form_version = COALESCE(NULLIF(p_datos->>'versionFormulario', ''), 'FIDELIS-D6-2026.4'),
      ive_completed_at = now(),
      estado_operativo = 'EXPEDIENTE_RECIBIDO',
      faltantes = '[]'::jsonb
  WHERE id = v_sol.id;
  UPDATE public.ive_invitaciones SET used_at = now() WHERE id = v_inv.id;
  INSERT INTO public.solicitud_revisiones (solicitud_alta_id, estado_anterior, estado_nuevo, comentario, creado_por)
  VALUES (v_sol.id, v_sol.estado_operativo, 'EXPEDIENTE_RECIBIDO', 'Expediente enviado por el afianzado', NULL);
  RETURN v_sol.id;
END;
$$;

-- ============================================================================
-- Acceso de la marca (o del personal) al expediente en tramite.

CREATE OR REPLACE FUNCTION public.d6_alta_editable(p_sol public.solicitudes_alta)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT p_sol.estado_operativo IN ('BORRADOR', 'IVE_PENDIENTE', 'INFORMACION_COMPLEMENTARIA')
    AND (public.has_d6_role(ARRAY['admin', 'comercial', 'suscripcion']::public.d6_role[])
         OR public.d6_beneficiario_es_mio(p_sol.beneficiario_id));
$$;
REVOKE EXECUTE ON FUNCTION public.d6_alta_editable(public.solicitudes_alta) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.d6_alta_compartida(p_solicitud_id UUID)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_sol public.solicitudes_alta;
  v_editable BOOLEAN;
BEGIN
  SELECT * INTO v_sol FROM public.solicitudes_alta WHERE id = p_solicitud_id;
  IF NOT FOUND OR NOT public.d6_puede_ver_beneficiario(v_sol.beneficiario_id) THEN
    RAISE EXCEPTION 'Solicitud no encontrada';
  END IF;
  v_editable := public.d6_alta_editable(v_sol);
  RETURN jsonb_build_object(
    'id', v_sol.id,
    'numero_solicitud', v_sol.numero_solicitud,
    'estado', v_sol.estado_operativo,
    'tipo_persona', v_sol.tipo_persona,
    'afianzado', v_sol.cliente_nombre_tmp,
    'monto_solicitado', v_sol.monto_solicitado,
    'editable', v_editable,
    'enviado', v_sol.ive_completed_at IS NOT NULL,
    -- Mientras se llena, la marca ve el borrador para adelantar. Ya enviado, el IVE es de Fidelis.
    'borrador', CASE WHEN v_editable THEN COALESCE(v_sol.ive_borrador, '{}'::jsonb) END,
    'requisitos', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'categoria', r.categoria, 'nombre', r.nombre, 'ayuda', r.ayuda, 'obligatorio', r.obligatorio,
        'responsable', r.responsable,
        'documentos', COALESCE((
          SELECT jsonb_agg(jsonb_build_object(
            'id', d.id, 'nombre_archivo', d.nombre_archivo, 'estado', d.estado_revision, 'origen', d.origen,
            'comentario', d.comentario_revision, 'subido', d.created_at) ORDER BY d.created_at)
          FROM public.documentos d
          WHERE d.solicitud_alta_id = v_sol.id AND d.categoria = r.categoria AND NOT d.carga_pendiente
            AND NOT (d.estado_revision = 'RECHAZADO' AND COALESCE(d.comentario_revision, '') ~ '^(Reemplazado|Retirado)')
        ), '[]'::jsonb)
      ) ORDER BY r.orden)
      FROM public.ive_requisitos_d6 r
      WHERE r.activo AND r.tipo_persona = v_sol.tipo_persona
        AND r.categoria NOT IN ('IVE_ASS_01', 'IVE_ASS_02')
        AND (NOT r.requiere_umbral_exposicion OR v_sol.requiere_documento_accesorio)
    ), '[]'::jsonb)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.d6_alta_guardar_borrador(p_solicitud_id UUID, p_cambios JSONB)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_sol public.solicitudes_alta;
BEGIN
  SELECT * INTO v_sol FROM public.solicitudes_alta WHERE id = p_solicitud_id FOR UPDATE;
  IF NOT FOUND OR NOT public.d6_alta_editable(v_sol) THEN
    RAISE EXCEPTION 'Esta solicitud ya no se puede editar';
  END IF;
  IF pg_column_size(p_cambios) > 512000 THEN RAISE EXCEPTION 'Los datos son demasiado grandes'; END IF;
  -- La firma y la declaracion son solo del distribuidor.
  UPDATE public.solicitudes_alta
  SET ive_borrador = COALESCE(ive_borrador, '{}'::jsonb) || (COALESCE(p_cambios, '{}'::jsonb) - 'firmaImagen' - 'declaracionVeracidad')
  WHERE id = p_solicitud_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.d6_alta_preparar_carga(
  p_solicitud_id UUID, p_categoria public.doc_categoria, p_nombre_archivo TEXT, p_mime TEXT, p_tamano INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_sol public.solicitudes_alta;
  v_ext TEXT;
  v_path TEXT;
  v_id UUID;
BEGIN
  SELECT * INTO v_sol FROM public.solicitudes_alta WHERE id = p_solicitud_id;
  IF NOT FOUND OR NOT public.d6_alta_editable(v_sol) THEN
    RAISE EXCEPTION 'Esta solicitud ya no recibe documentos desde aquí';
  END IF;
  IF p_mime NOT IN ('application/pdf', 'image/png', 'image/jpeg') THEN
    RAISE EXCEPTION 'Solo se aceptan archivos PDF, PNG o JPG';
  END IF;
  IF COALESCE(p_tamano, 0) <= 0 OR p_tamano > 15728640 THEN
    RAISE EXCEPTION 'El archivo debe pesar menos de 15 MB';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.ive_requisitos_d6 r
                 WHERE r.activo AND r.tipo_persona = v_sol.tipo_persona AND r.categoria = p_categoria) THEN
    RAISE EXCEPTION 'Ese tipo de documento no corresponde a esta solicitud';
  END IF;
  IF (SELECT count(*) FROM public.documentos WHERE solicitud_alta_id = v_sol.id) >= 60 THEN
    RAISE EXCEPTION 'La solicitud alcanzó el límite de archivos. Contacte a Fidelis.';
  END IF;
  v_ext := CASE p_mime WHEN 'application/pdf' THEN 'pdf' WHEN 'image/png' THEN 'png' ELSE 'jpg' END;
  v_id := gen_random_uuid();
  v_path := 'altas/' || v_sol.id || '/' || v_id || '.' || v_ext;
  INSERT INTO public.documentos (id, solicitud_alta_id, categoria, nombre_archivo, file_path, file_size, mime_type,
                                 origen, subido_por, carga_pendiente, carga_expira, requerido)
  VALUES (v_id, v_sol.id, p_categoria, left(regexp_replace(COALESCE(p_nombre_archivo, 'documento'), '[\\/]', '_', 'g'), 180),
          v_path, p_tamano, p_mime,
          CASE WHEN public.d6_es_personal_aseguradora() THEN 'FIDELIS' ELSE 'MARCA' END,
          auth.uid(), true, now() + INTERVAL '15 minutes', true);
  RETURN jsonb_build_object('documento_id', v_id, 'path', v_path);
END;
$$;

CREATE OR REPLACE FUNCTION public.d6_alta_confirmar_carga(p_documento_id UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, storage
AS $$
DECLARE
  v_doc public.documentos;
  v_sol public.solicitudes_alta;
BEGIN
  SELECT * INTO v_doc FROM public.documentos WHERE id = p_documento_id AND carga_pendiente AND subido_por = auth.uid() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No hay una carga pendiente con ese identificador'; END IF;
  SELECT * INTO v_sol FROM public.solicitudes_alta WHERE id = v_doc.solicitud_alta_id;
  IF NOT public.d6_alta_editable(v_sol) THEN RAISE EXCEPTION 'Esta solicitud ya no recibe documentos desde aquí'; END IF;
  IF NOT EXISTS (SELECT 1 FROM storage.objects o WHERE o.bucket_id = 'expedientes' AND o.name = v_doc.file_path) THEN
    RAISE EXCEPTION 'El archivo no llegó al servidor. Intente subirlo de nuevo.';
  END IF;
  UPDATE public.documentos SET carga_pendiente = false, carga_expira = NULL WHERE id = v_doc.id;
END;
$$;

CREATE OR REPLACE FUNCTION public.d6_alta_quitar_documento(p_documento_id UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_doc public.documentos;
  v_sol public.solicitudes_alta;
BEGIN
  SELECT * INTO v_doc FROM public.documentos WHERE id = p_documento_id;
  SELECT * INTO v_sol FROM public.solicitudes_alta WHERE id = v_doc.solicitud_alta_id;
  IF NOT FOUND OR NOT public.d6_alta_editable(v_sol) THEN RAISE EXCEPTION 'Esta solicitud ya no se puede editar'; END IF;
  UPDATE public.documentos SET estado_revision = 'RECHAZADO', comentario_revision = 'Retirado antes de enviar'
  WHERE id = p_documento_id AND estado_revision = 'PENDIENTE';
  IF NOT FOUND THEN RAISE EXCEPTION 'Ese documento ya fue revisado y no se puede retirar'; END IF;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.d6_alta_compartida(UUID) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.d6_alta_guardar_borrador(UUID, JSONB) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.d6_alta_preparar_carga(UUID, public.doc_categoria, TEXT, TEXT, INTEGER) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.d6_alta_confirmar_carga(UUID) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.d6_alta_quitar_documento(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.d6_alta_compartida(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.d6_alta_guardar_borrador(UUID, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.d6_alta_preparar_carga(UUID, public.doc_categoria, TEXT, TEXT, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.d6_alta_confirmar_carga(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.d6_alta_quitar_documento(UUID) TO authenticated;

-- ============================================================================
-- Portal: los requisitos dicen quien los entrega y muestran lo que subio la marca.

CREATE OR REPLACE FUNCTION public.portal_ive_contexto(p_token TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_inv public.ive_invitaciones;
  v_sol public.solicitudes_alta;
  v_motivo TEXT;
  v_previo JSONB;
BEGIN
  v_inv := public.d6_invitacion_por_token(p_token);
  v_motivo := CASE
    WHEN v_inv.id IS NULL THEN 'NO_EXISTE'
    WHEN v_inv.used_at IS NOT NULL THEN 'ENVIADO'
    WHEN v_inv.revoked_at IS NOT NULL THEN 'REEMPLAZADO'
    WHEN v_inv.expires_at <= now() THEN 'EXPIRADO'
  END;
  IF v_motivo IS NOT NULL THEN
    RETURN jsonb_build_object('valido', false, 'motivo', v_motivo);
  END IF;
  SELECT * INTO v_sol FROM public.solicitudes_alta WHERE id = v_inv.solicitud_alta_id;
  IF v_sol.estado_operativo NOT IN ('IVE_PENDIENTE', 'INFORMACION_COMPLEMENTARIA') THEN
    RETURN jsonb_build_object('valido', false, 'motivo', 'CERRADO');
  END IF;
  IF v_sol.ive_data IS NULL AND v_sol.cliente_id IS NOT NULL THEN
    SELECT sa.ive_data INTO v_previo FROM public.solicitudes_alta sa
    WHERE sa.cliente_id = v_sol.cliente_id AND sa.id <> v_sol.id AND sa.ive_data IS NOT NULL
      AND sa.tipo_persona = v_sol.tipo_persona
      AND EXISTS (
        SELECT 1 FROM public.grupo_beneficiario_rel a
        JOIN public.grupo_beneficiario_rel b ON b.grupo_id = a.grupo_id
        JOIN public.grupos_beneficiarios g ON g.id = a.grupo_id AND g.codigo <> 'GRP-GENERAL'
        WHERE a.beneficiario_id = v_sol.beneficiario_id AND b.beneficiario_id = sa.beneficiario_id)
    ORDER BY sa.ive_completed_at DESC NULLS LAST LIMIT 1;
  END IF;

  RETURN jsonb_build_object(
    'valido', true,
    'numero_solicitud', v_sol.numero_solicitud,
    'estado', v_sol.estado_operativo,
    -- El nombre de la marca que el distribuidor conoce, no la razon social del beneficiario.
    'marca', COALESCE((SELECT g.nombre FROM public.grupo_beneficiario_rel r
                       JOIN public.grupos_beneficiarios g ON g.id = r.grupo_id AND g.codigo <> 'GRP-GENERAL'
                       WHERE r.beneficiario_id = v_sol.beneficiario_id LIMIT 1),
                      (SELECT nombre FROM public.beneficiarios WHERE id = v_sol.beneficiario_id)),
    'afianzado', v_sol.cliente_nombre_tmp,
    'tipo_persona', v_sol.tipo_persona,
    'tipo_solicitud', v_sol.tipo_solicitud,
    'monto_solicitado', v_sol.monto_solicitado,
    'expira', v_inv.expires_at,
    'comentario', CASE WHEN v_sol.estado_operativo = 'INFORMACION_COMPLEMENTARIA' THEN v_sol.resolucion_comentario END,
    'faltantes', v_sol.faltantes,
    -- Lo que llenaron la marca o el distribuidor pesa mas que el formulario de una solicitud anterior.
    'borrador', COALESCE(v_previo, '{}'::jsonb) || COALESCE(v_sol.ive_data, '{}'::jsonb) || COALESCE(v_sol.ive_borrador, '{}'::jsonb),
    'precargado', v_previo IS NOT NULL,
    'requisitos', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'categoria', r.categoria, 'nombre', r.nombre, 'ayuda', r.ayuda, 'obligatorio', r.obligatorio,
        'responsable', r.responsable,
        'documentos', COALESCE((
          SELECT jsonb_agg(jsonb_build_object(
            'id', d.id, 'nombre_archivo', d.nombre_archivo, 'estado', d.estado_revision, 'origen', d.origen,
            'comentario', d.comentario_revision, 'subido', d.created_at) ORDER BY d.created_at)
          FROM public.documentos d
          WHERE d.solicitud_alta_id = v_sol.id AND d.categoria = r.categoria AND NOT d.carga_pendiente
            AND NOT (d.estado_revision = 'RECHAZADO' AND COALESCE(d.comentario_revision, '') ~ '^(Reemplazado|Retirado)')
        ), '[]'::jsonb)
      ) ORDER BY r.orden)
      FROM public.ive_requisitos_d6 r
      WHERE r.activo AND r.tipo_persona = v_sol.tipo_persona
        AND r.categoria NOT IN ('IVE_ASS_01', 'IVE_ASS_02')
        AND (NOT r.requiere_umbral_exposicion OR v_sol.requiere_documento_accesorio)
    ), '[]'::jsonb)
  );
END;
$$;

-- Nombres de documentos en el lenguaje de quien los entrega.
UPDATE public.ive_requisitos_d6 SET nombre = 'DPI vigente, de los dos lados',
  ayuda = 'El de la persona que recibe la mercadería, no el de la marca.'
WHERE tipo_persona = 'INDIVIDUAL' AND categoria = 'DPI';
UPDATE public.ive_requisitos_d6 SET nombre = 'RTU actualizado', ayuda = 'Constancia de inscripción en la SAT. Se descarga de la Agencia Virtual.'
WHERE tipo_persona = 'INDIVIDUAL' AND categoria = 'RTU';
UPDATE public.ive_requisitos_d6 SET nombre = 'Recibo de luz, agua o teléfono fijo',
  ayuda = 'De la dirección de su casa. Puede estar a nombre de otra persona.'
WHERE tipo_persona = 'INDIVIDUAL' AND categoria = 'RECIBO_SERVICIO';
UPDATE public.ive_requisitos_d6 SET nombre = 'Estados de cuenta del banco, últimos 3 meses',
  ayuda = 'Que se vea el nombre del titular.'
WHERE categoria = 'ESTADO_CUENTA';
UPDATE public.ive_requisitos_d6 SET nombre = 'Estado patrimonial',
  ayuda = 'Lista de sus bienes y deudas, firmada por usted y por un contador.'
WHERE categoria = 'ESTADO_PATRIMONIAL';
UPDATE public.ive_requisitos_d6 SET ayuda = 'Solo si lleva contabilidad con contador. Si no está seguro, Fidelis le dice.'
WHERE tipo_persona = 'INDIVIDUAL' AND categoria = 'ESTADOS_FINANCIEROS';
UPDATE public.ive_requisitos_d6 SET nombre = 'Carta de aprobación de crédito de la marca'
WHERE categoria = 'APROBACION_FIANZA';
UPDATE public.ive_requisitos_d6 SET nombre = 'Documento de garantía (documento accesorio)',
  ayuda = 'Solo cuando la fianza, o lo que suma con otras, pasa de Q300,000. Fidelis le envía el formato.'
WHERE categoria = 'DOCUMENTO_ACCESORIO';
