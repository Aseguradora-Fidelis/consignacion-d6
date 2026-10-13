-- Migracion 020: seguridad y permisos.
--
-- Cierra los huecos encontrados en la revision del 2026-10-05:
--   1. El alta de usuario tomaba el rol de la metadata que manda el navegador.
--   2. Operaciones pasaba todos los chequeos de rol y podia promoverse a admin.
--   3. Una marca podia aprobar o borrar sus propias bajas (politica FOR ALL de 004).
--   4. Una marca leia ive_data completo (DPI, ingresos, PEP, firma) de sus altas.
--   5. La RPC de alta reutilizaba clientes por nombre y exponia afianzados de otra marca.
--   6. El rol "agente" contaba como personal de la aseguradora y veia todas las marcas.
--   7. Se podia reemitir un link IVE con el expediente en revision y el afianzado
--      sobrescribia los datos ya revisados.
--
-- Las politicas se reconstruyen desde cero en este archivo. Despues de esta migracion,
-- este es el unico lugar donde hay que leer para saber quien ve y escribe cada tabla.

-- ============================================================================
-- 1. Funciones de rol
-- ============================================================================

-- El rol de app_role 'admin' queda como superusuario de arranque. 'operaciones' y
-- 'agente' ya no otorgan nada: los permisos viven en user_role_assignments.
CREATE OR REPLACE FUNCTION public.has_d6_role(p_roles public.d6_role[])
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT auth.uid() IS NOT NULL AND (
    EXISTS (
      SELECT 1 FROM public.user_role_assignments
      WHERE user_id = auth.uid() AND role = ANY (p_roles)
    )
    OR public.get_user_role(auth.uid()) = 'admin'
  );
$$;

CREATE OR REPLACE FUNCTION public.d6_es_personal_aseguradora()
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT public.has_d6_role(ARRAY[
    'admin', 'comercial', 'suscripcion', 'coordinacion_comercial',
    'cobros', 'contabilidad', 'consulta'
  ]::public.d6_role[]);
$$;

-- Solo el propio usuario o el personal puede preguntar por las marcas de alguien.
CREATE OR REPLACE FUNCTION public.get_user_beneficiario_ids(p_user_id UUID DEFAULT auth.uid())
RETURNS TABLE(beneficiario_id UUID)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF p_user_id IS NULL THEN
    RETURN;
  END IF;
  IF p_user_id IS DISTINCT FROM auth.uid() AND NOT public.d6_es_personal_aseguradora() THEN
    RETURN;
  END IF;
  RETURN QUERY
  SELECT DISTINCT gbr.beneficiario_id
  FROM public.user_grupos ug
  JOIN public.grupo_beneficiario_rel gbr ON gbr.grupo_id = ug.grupo_id
  WHERE ug.user_id = p_user_id;
END;
$$;

-- Verdadero solo si el beneficiario es de la marca del usuario (no por ser personal).
CREATE OR REPLACE FUNCTION public.d6_beneficiario_es_mio(p_beneficiario_id UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT p_beneficiario_id IS NOT NULL
    AND p_beneficiario_id IN (SELECT beneficiario_id FROM public.get_user_beneficiario_ids(auth.uid()));
$$;

CREATE OR REPLACE FUNCTION public.d6_puede_ver_beneficiario(p_beneficiario_id UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT p_beneficiario_id IS NOT NULL
    AND (public.d6_es_personal_aseguradora() OR public.d6_beneficiario_es_mio(p_beneficiario_id));
$$;

CREATE OR REPLACE FUNCTION public.d6_baja_es_mia(p_baja_id UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.solicitudes_baja sb
    JOIN public.fianzas f ON f.id = sb.fianza_id
    WHERE sb.id = p_baja_id AND public.d6_beneficiario_es_mio(f.beneficiario_id)
  );
$$;

-- Una marca ve documentos de sus bajas y de sus polizas emitidas. Los documentos del
-- expediente de alta (DPI, estados de cuenta, patrimonial) son del afianzado y solo
-- los ve el personal de Fidelis.
CREATE OR REPLACE FUNCTION public.d6_puede_ver_documento(p_documento_id UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT public.d6_es_personal_aseguradora()
    OR EXISTS (
      SELECT 1
      FROM public.documentos d
      LEFT JOIN public.fianzas f ON f.id = d.fianza_id
      WHERE d.id = p_documento_id
        AND d.solicitud_alta_id IS NULL
        AND (
          (d.solicitud_baja_id IS NOT NULL AND public.d6_baja_es_mia(d.solicitud_baja_id))
          OR (d.fianza_id IS NOT NULL AND public.d6_beneficiario_es_mio(f.beneficiario_id))
        )
    );
$$;

-- ============================================================================
-- 2. Alta de usuarios y perfil
-- ============================================================================

-- Todo usuario nuevo nace como marca sin grupos asignados, es decir, sin acceso.
-- El administrador le da rol y marcas despues. La metadata del navegador se ignora.
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  INSERT INTO public.user_profiles (id, email, full_name, role)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NULLIF(btrim(NEW.raw_user_meta_data->>'full_name'), ''), NEW.email),
    'beneficiario'::public.app_role
  )
  ON CONFLICT (id) DO UPDATE SET email = EXCLUDED.email;
  RETURN NEW;
END;
$$;

-- Nadie cambia su propio rol, agente o correo desde el navegador. Solo un admin, o el
-- servidor (service_role, migraciones), puede hacerlo.
CREATE OR REPLACE FUNCTION public.d6_proteger_perfil()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF (NEW.role IS DISTINCT FROM OLD.role
      OR NEW.agente_id IS DISTINCT FROM OLD.agente_id
      OR NEW.email IS DISTINCT FROM OLD.email)
     AND COALESCE(auth.role(), '') IN ('authenticated', 'anon')
     AND NOT public.has_d6_role(ARRAY['admin']::public.d6_role[]) THEN
    RAISE EXCEPTION 'Solo un administrador puede cambiar el rol, el agente o el correo de un usuario';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_user_profiles_proteger ON public.user_profiles;
CREATE TRIGGER trg_user_profiles_proteger
  BEFORE UPDATE ON public.user_profiles
  FOR EACH ROW EXECUTE FUNCTION public.d6_proteger_perfil();

-- ============================================================================
-- 3. Politicas: se borran todas y se crean de nuevo
-- ============================================================================

DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT schemaname, tablename, policyname
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = ANY (ARRAY[
        'user_profiles', 'user_role_assignments', 'grupos_beneficiarios', 'grupo_beneficiario_rel',
        'user_grupos', 'beneficiarios', 'agentes', 'clientes', 'fianzas', 'solicitudes_alta',
        'solicitud_revisiones', 'solicitudes_baja', 'documentos', 'pagos', 'conciliaciones',
        'notificaciones', 'audit_log', 'contratos_consignacion', 'ive_invitaciones',
        'importaciones_d6', 'estados_cuenta_d6', 'estado_cuenta_items_d6',
        'conciliacion_propuestas_d6', 'notificaciones_envio', 'reglas_cobro_d6',
        'ive_requisitos_d6', 'oracle_sync_runs_d6', 'oracle_d6_staging'
      ])
  LOOP
    EXECUTE format('DROP POLICY %I ON %I.%I', r.policyname, r.schemaname, r.tablename);
  END LOOP;

  FOR r IN
    SELECT policyname FROM pg_policies
    WHERE schemaname = 'storage' AND tablename = 'objects'
      AND policyname = ANY (ARRAY[
        'Admin y Operaciones tienen control total en expedientes',
        'Usuarios autenticados pueden ver expedientes',
        'Usuarios autenticados pueden subir expedientes',
        'Usuarios pueden actualizar sus propios expedientes',
        'Usuarios pueden eliminar sus propios expedientes',
        'D6 personal administra archivos de expedientes',
        'Marcas descargan solo archivos de su cartera'
      ])
  LOOP
    EXECUTE format('DROP POLICY %I ON storage.objects', r.policyname);
  END LOOP;
END $$;

-- Perfiles y roles ------------------------------------------------------------
CREATE POLICY "perfil: ver el propio o personal ve todos" ON public.user_profiles FOR SELECT
  USING (id = auth.uid() OR public.d6_es_personal_aseguradora());
CREATE POLICY "perfil: editar el propio" ON public.user_profiles FOR UPDATE
  USING (id = auth.uid()) WITH CHECK (id = auth.uid());
CREATE POLICY "perfil: admin administra" ON public.user_profiles FOR ALL
  USING (public.has_d6_role(ARRAY['admin']::public.d6_role[]))
  WITH CHECK (public.has_d6_role(ARRAY['admin']::public.d6_role[]));

CREATE POLICY "roles: ver los propios o personal ve todos" ON public.user_role_assignments FOR SELECT
  USING (user_id = auth.uid() OR public.d6_es_personal_aseguradora());
CREATE POLICY "roles: admin administra" ON public.user_role_assignments FOR ALL
  USING (public.has_d6_role(ARRAY['admin']::public.d6_role[]))
  WITH CHECK (public.has_d6_role(ARRAY['admin']::public.d6_role[]));

-- Marcas (grupos) y beneficiarios ---------------------------------------------
CREATE POLICY "grupos: personal o miembros ven" ON public.grupos_beneficiarios FOR SELECT
  USING (public.d6_es_personal_aseguradora()
         OR id IN (SELECT grupo_id FROM public.user_grupos WHERE user_id = auth.uid()));
CREATE POLICY "grupos: admin administra" ON public.grupos_beneficiarios FOR ALL
  USING (public.has_d6_role(ARRAY['admin']::public.d6_role[]))
  WITH CHECK (public.has_d6_role(ARRAY['admin']::public.d6_role[]));

CREATE POLICY "grupo_rel: personal o miembros ven" ON public.grupo_beneficiario_rel FOR SELECT
  USING (public.d6_es_personal_aseguradora()
         OR grupo_id IN (SELECT grupo_id FROM public.user_grupos WHERE user_id = auth.uid()));
CREATE POLICY "grupo_rel: admin administra" ON public.grupo_beneficiario_rel FOR ALL
  USING (public.has_d6_role(ARRAY['admin']::public.d6_role[]))
  WITH CHECK (public.has_d6_role(ARRAY['admin']::public.d6_role[]));

CREATE POLICY "user_grupos: ver los propios o personal" ON public.user_grupos FOR SELECT
  USING (user_id = auth.uid() OR public.d6_es_personal_aseguradora());
CREATE POLICY "user_grupos: admin administra" ON public.user_grupos FOR ALL
  USING (public.has_d6_role(ARRAY['admin']::public.d6_role[]))
  WITH CHECK (public.has_d6_role(ARRAY['admin']::public.d6_role[]));

CREATE POLICY "beneficiarios: personal o la propia marca ven" ON public.beneficiarios FOR SELECT
  USING (public.d6_puede_ver_beneficiario(id));
CREATE POLICY "beneficiarios: admin administra" ON public.beneficiarios FOR ALL
  USING (public.has_d6_role(ARRAY['admin']::public.d6_role[]))
  WITH CHECK (public.has_d6_role(ARRAY['admin']::public.d6_role[]));

CREATE POLICY "agentes: personal ve" ON public.agentes FOR SELECT
  USING (public.d6_es_personal_aseguradora());
CREATE POLICY "agentes: admin administra" ON public.agentes FOR ALL
  USING (public.has_d6_role(ARRAY['admin']::public.d6_role[]))
  WITH CHECK (public.has_d6_role(ARRAY['admin']::public.d6_role[]));

-- Afianzados -------------------------------------------------------------------
-- Una marca ve a un afianzado solo si tiene una poliza emitida con el. Lo que la marca
-- escribio al pedir el alta lo ve por v_solicitudes_alta_marca, no por esta tabla.
CREATE POLICY "clientes: personal ve" ON public.clientes FOR SELECT
  USING (public.d6_es_personal_aseguradora());
CREATE POLICY "clientes: marca ve afianzados con poliza suya" ON public.clientes FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM public.fianzas f
    WHERE f.cliente_id = clientes.id AND public.d6_beneficiario_es_mio(f.beneficiario_id)
  ));
CREATE POLICY "clientes: comercial y suscripcion crean" ON public.clientes FOR INSERT
  WITH CHECK (public.has_d6_role(ARRAY['admin', 'comercial', 'suscripcion']::public.d6_role[]));
CREATE POLICY "clientes: comercial y suscripcion editan" ON public.clientes FOR UPDATE
  USING (public.has_d6_role(ARRAY['admin', 'comercial', 'suscripcion']::public.d6_role[]))
  WITH CHECK (public.has_d6_role(ARRAY['admin', 'comercial', 'suscripcion']::public.d6_role[]));
CREATE POLICY "clientes: admin borra" ON public.clientes FOR DELETE
  USING (public.has_d6_role(ARRAY['admin']::public.d6_role[]));

-- Polizas ----------------------------------------------------------------------
CREATE POLICY "fianzas: personal o la propia marca ven" ON public.fianzas FOR SELECT
  USING (public.d6_puede_ver_beneficiario(beneficiario_id));
CREATE POLICY "fianzas: suscripcion crea" ON public.fianzas FOR INSERT
  WITH CHECK (public.has_d6_role(ARRAY['admin', 'suscripcion']::public.d6_role[]));
CREATE POLICY "fianzas: suscripcion edita" ON public.fianzas FOR UPDATE
  USING (public.has_d6_role(ARRAY['admin', 'suscripcion']::public.d6_role[]))
  WITH CHECK (public.has_d6_role(ARRAY['admin', 'suscripcion']::public.d6_role[]));
CREATE POLICY "fianzas: admin borra" ON public.fianzas FOR DELETE
  USING (public.has_d6_role(ARRAY['admin']::public.d6_role[]));

CREATE POLICY "contratos: personal ve" ON public.contratos_consignacion FOR SELECT
  USING (public.d6_es_personal_aseguradora());
CREATE POLICY "contratos: suscripcion administra" ON public.contratos_consignacion FOR ALL
  USING (public.has_d6_role(ARRAY['admin', 'suscripcion']::public.d6_role[]))
  WITH CHECK (public.has_d6_role(ARRAY['admin', 'suscripcion']::public.d6_role[]));

-- Altas ------------------------------------------------------------------------
-- La marca no lee esta tabla: contiene ive_data. Usa v_solicitudes_alta_marca.
CREATE POLICY "altas: personal ve" ON public.solicitudes_alta FOR SELECT
  USING (public.d6_es_personal_aseguradora());
CREATE POLICY "altas: comercial y suscripcion crean" ON public.solicitudes_alta FOR INSERT
  WITH CHECK (public.has_d6_role(ARRAY['admin', 'comercial', 'suscripcion']::public.d6_role[]));
CREATE POLICY "altas: comercial y suscripcion editan" ON public.solicitudes_alta FOR UPDATE
  USING (public.has_d6_role(ARRAY['admin', 'comercial', 'suscripcion']::public.d6_role[]))
  WITH CHECK (public.has_d6_role(ARRAY['admin', 'comercial', 'suscripcion']::public.d6_role[]));
CREATE POLICY "altas: admin borra" ON public.solicitudes_alta FOR DELETE
  USING (public.has_d6_role(ARRAY['admin']::public.d6_role[]));

CREATE POLICY "revisiones: personal ve" ON public.solicitud_revisiones FOR SELECT
  USING (public.d6_es_personal_aseguradora());
CREATE POLICY "revisiones: suscripcion escribe" ON public.solicitud_revisiones FOR INSERT
  WITH CHECK (public.has_d6_role(ARRAY['admin', 'suscripcion']::public.d6_role[]));

CREATE POLICY "invitaciones: comercial y suscripcion ven" ON public.ive_invitaciones FOR SELECT
  USING (public.has_d6_role(ARRAY['admin', 'comercial', 'suscripcion']::public.d6_role[]));

CREATE POLICY "requisitos: personal ve" ON public.ive_requisitos_d6 FOR SELECT
  USING (public.d6_es_personal_aseguradora());
CREATE POLICY "requisitos: admin administra" ON public.ive_requisitos_d6 FOR ALL
  USING (public.has_d6_role(ARRAY['admin']::public.d6_role[]))
  WITH CHECK (public.has_d6_role(ARRAY['admin']::public.d6_role[]));

-- Bajas ------------------------------------------------------------------------
-- La marca crea la solicitud y la consulta. Aprobar, rechazar o borrar es de Suscripcion.
CREATE POLICY "bajas: personal o la propia marca ven" ON public.solicitudes_baja FOR SELECT
  USING (public.d6_es_personal_aseguradora() OR public.d6_baja_es_mia(id));
CREATE POLICY "bajas: personal crea" ON public.solicitudes_baja FOR INSERT
  WITH CHECK (public.has_d6_role(ARRAY['admin', 'comercial', 'suscripcion']::public.d6_role[]));
CREATE POLICY "bajas: marca crea solo pendientes de su cartera" ON public.solicitudes_baja FOR INSERT
  WITH CHECK (
    estado = 'PENDIENTE_REVISION'
    AND solicitado_por = auth.uid()
    AND procesado_por IS NULL
    AND EXISTS (
      SELECT 1 FROM public.fianzas f
      WHERE f.id = fianza_id AND public.d6_beneficiario_es_mio(f.beneficiario_id)
    )
  );
CREATE POLICY "bajas: suscripcion resuelve" ON public.solicitudes_baja FOR UPDATE
  USING (public.has_d6_role(ARRAY['admin', 'suscripcion']::public.d6_role[]))
  WITH CHECK (public.has_d6_role(ARRAY['admin', 'suscripcion']::public.d6_role[]));
CREATE POLICY "bajas: admin borra" ON public.solicitudes_baja FOR DELETE
  USING (public.has_d6_role(ARRAY['admin']::public.d6_role[]));

-- Documentos -------------------------------------------------------------------
CREATE POLICY "documentos: personal o marca autorizada ven" ON public.documentos FOR SELECT
  USING (public.d6_puede_ver_documento(id));
CREATE POLICY "documentos: personal carga" ON public.documentos FOR INSERT
  WITH CHECK (public.has_d6_role(ARRAY['admin', 'comercial', 'suscripcion', 'cobros', 'contabilidad']::public.d6_role[]));
CREATE POLICY "documentos: marca adjunta a sus bajas" ON public.documentos FOR INSERT
  WITH CHECK (
    solicitud_baja_id IS NOT NULL
    AND solicitud_alta_id IS NULL
    AND fianza_id IS NULL
    AND subido_por = auth.uid()
    AND public.d6_baja_es_mia(solicitud_baja_id)
  );
CREATE POLICY "documentos: personal revisa" ON public.documentos FOR UPDATE
  USING (public.has_d6_role(ARRAY['admin', 'comercial', 'suscripcion']::public.d6_role[]))
  WITH CHECK (public.has_d6_role(ARRAY['admin', 'comercial', 'suscripcion']::public.d6_role[]));
CREATE POLICY "documentos: personal borra" ON public.documentos FOR DELETE
  USING (public.has_d6_role(ARRAY['admin', 'suscripcion']::public.d6_role[]));

-- Pagos y conciliacion ---------------------------------------------------------
CREATE POLICY "pagos: personal o la propia marca ven" ON public.pagos FOR SELECT
  USING (public.d6_es_personal_aseguradora() OR EXISTS (
    SELECT 1 FROM public.fianzas f
    WHERE f.id = pagos.fianza_id AND public.d6_beneficiario_es_mio(f.beneficiario_id)
  ));
CREATE POLICY "pagos: cobros administra" ON public.pagos FOR ALL
  USING (public.has_d6_role(ARRAY['admin', 'cobros', 'contabilidad']::public.d6_role[]))
  WITH CHECK (public.has_d6_role(ARRAY['admin', 'cobros', 'contabilidad']::public.d6_role[]));

CREATE POLICY "conciliaciones: personal ve" ON public.conciliaciones FOR SELECT
  USING (public.d6_es_personal_aseguradora());
CREATE POLICY "conciliaciones: cobros administra" ON public.conciliaciones FOR ALL
  USING (public.has_d6_role(ARRAY['admin', 'cobros', 'contabilidad']::public.d6_role[]))
  WITH CHECK (public.has_d6_role(ARRAY['admin', 'cobros', 'contabilidad']::public.d6_role[]));

CREATE POLICY "propuestas: personal ve" ON public.conciliacion_propuestas_d6 FOR SELECT
  USING (public.d6_es_personal_aseguradora());
CREATE POLICY "propuestas: cobros administra" ON public.conciliacion_propuestas_d6 FOR ALL
  USING (public.has_d6_role(ARRAY['admin', 'cobros', 'contabilidad']::public.d6_role[]))
  WITH CHECK (public.has_d6_role(ARRAY['admin', 'cobros', 'contabilidad']::public.d6_role[]));

CREATE POLICY "importaciones: personal ve" ON public.importaciones_d6 FOR SELECT
  USING (public.d6_es_personal_aseguradora());
CREATE POLICY "importaciones: cobros y comercializacion administran" ON public.importaciones_d6 FOR ALL
  USING (public.has_d6_role(ARRAY['admin', 'coordinacion_comercial', 'cobros', 'contabilidad']::public.d6_role[]))
  WITH CHECK (public.has_d6_role(ARRAY['admin', 'coordinacion_comercial', 'cobros', 'contabilidad']::public.d6_role[]));

CREATE POLICY "estados_cuenta: personal o la propia marca ven" ON public.estados_cuenta_d6 FOR SELECT
  USING (public.d6_puede_ver_beneficiario(beneficiario_id));
CREATE POLICY "estados_cuenta: comercializacion y cobros administran" ON public.estados_cuenta_d6 FOR ALL
  USING (public.has_d6_role(ARRAY['admin', 'coordinacion_comercial', 'cobros']::public.d6_role[]))
  WITH CHECK (public.has_d6_role(ARRAY['admin', 'coordinacion_comercial', 'cobros']::public.d6_role[]));

CREATE POLICY "partidas: personal o la propia marca ven" ON public.estado_cuenta_items_d6 FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM public.estados_cuenta_d6 ec
    WHERE ec.id = estado_cuenta_items_d6.estado_cuenta_id
      AND public.d6_puede_ver_beneficiario(ec.beneficiario_id)
  ));
CREATE POLICY "partidas: comercializacion y cobros administran" ON public.estado_cuenta_items_d6 FOR ALL
  USING (public.has_d6_role(ARRAY['admin', 'coordinacion_comercial', 'cobros']::public.d6_role[]))
  WITH CHECK (public.has_d6_role(ARRAY['admin', 'coordinacion_comercial', 'cobros']::public.d6_role[]));

CREATE POLICY "reglas_cobro: personal ve" ON public.reglas_cobro_d6 FOR SELECT
  USING (public.d6_es_personal_aseguradora());
CREATE POLICY "reglas_cobro: admin administra" ON public.reglas_cobro_d6 FOR ALL
  USING (public.has_d6_role(ARRAY['admin']::public.d6_role[]))
  WITH CHECK (public.has_d6_role(ARRAY['admin']::public.d6_role[]));

-- Notificaciones y auditoria ---------------------------------------------------
-- Las notificaciones las crean triggers SECURITY DEFINER. El usuario solo lee,
-- marca como leidas o borra las suyas.
CREATE POLICY "notificaciones: ver las propias" ON public.notificaciones FOR SELECT
  USING (user_id = auth.uid());
CREATE POLICY "notificaciones: marcar las propias" ON public.notificaciones FOR UPDATE
  USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());
CREATE POLICY "notificaciones: borrar las propias" ON public.notificaciones FOR DELETE
  USING (user_id = auth.uid());

CREATE POLICY "envios: personal ve" ON public.notificaciones_envio FOR SELECT
  USING (public.d6_es_personal_aseguradora());
CREATE POLICY "envios: personal registra" ON public.notificaciones_envio FOR INSERT
  WITH CHECK (public.d6_es_personal_aseguradora());

CREATE POLICY "auditoria: admin ve" ON public.audit_log FOR SELECT
  USING (public.has_d6_role(ARRAY['admin']::public.d6_role[]));

-- Oracle -----------------------------------------------------------------------
CREATE POLICY "oracle_runs: personal ve" ON public.oracle_sync_runs_d6 FOR SELECT
  USING (public.d6_es_personal_aseguradora());
CREATE POLICY "oracle_staging: admin ve" ON public.oracle_d6_staging FOR SELECT
  USING (public.has_d6_role(ARRAY['admin']::public.d6_role[]));

-- Storage: bucket privado expedientes -----------------------------------------
CREATE POLICY "expedientes: personal ve archivos" ON storage.objects FOR SELECT
  USING (bucket_id = 'expedientes' AND public.d6_es_personal_aseguradora());
CREATE POLICY "expedientes: personal carga archivos" ON storage.objects FOR INSERT
  WITH CHECK (bucket_id = 'expedientes'
    AND public.has_d6_role(ARRAY['admin', 'comercial', 'suscripcion', 'cobros', 'contabilidad']::public.d6_role[]));
CREATE POLICY "expedientes: personal reemplaza archivos" ON storage.objects FOR UPDATE
  USING (bucket_id = 'expedientes'
    AND public.has_d6_role(ARRAY['admin', 'comercial', 'suscripcion']::public.d6_role[]));
CREATE POLICY "expedientes: suscripcion borra archivos" ON storage.objects FOR DELETE
  USING (bucket_id = 'expedientes'
    AND public.has_d6_role(ARRAY['admin', 'suscripcion']::public.d6_role[]));
CREATE POLICY "expedientes: marca descarga archivos autorizados" ON storage.objects FOR SELECT
  USING (bucket_id = 'expedientes' AND EXISTS (
    SELECT 1 FROM public.documentos d
    WHERE d.file_path = storage.objects.name AND public.d6_puede_ver_documento(d.id)
  ));
-- Ruta esperada: bajas/<id de la solicitud de baja>/<archivo>
CREATE POLICY "expedientes: marca carga cartas de sus bajas" ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'expedientes'
    AND split_part(name, '/', 1) = 'bajas'
    AND split_part(name, '/', 2) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    AND public.d6_baja_es_mia(split_part(name, '/', 2)::uuid)
  );

-- ============================================================================
-- 4. Vista de altas para la marca (sin datos IVE)
-- ============================================================================
-- Corre con los permisos del propietario y filtra por tenant en el WHERE. No expone
-- ive_data, exposicion acumulada del afianzado ni comentarios internos.
DROP VIEW IF EXISTS public.v_solicitudes_alta_marca;
CREATE VIEW public.v_solicitudes_alta_marca
WITH (security_barrier = true)
AS
SELECT
  sa.id,
  sa.numero_solicitud,
  sa.beneficiario_id,
  b.codigo_contacto AS beneficiario_codigo,
  b.nombre AS beneficiario_nombre,
  COALESCE(sa.cliente_nombre_tmp, c.nombre) AS afianzado_nombre,
  sa.monto_solicitado,
  sa.monto_aprobado,
  sa.estado_operativo,
  sa.ive_completed_at IS NOT NULL AS ive_completado,
  inv.expires_at AS ive_link_expira,
  sa.vigencia_desde,
  sa.vigencia_hasta,
  sa.emitida_en,
  sa.created_at,
  sa.updated_at
FROM public.solicitudes_alta sa
JOIN public.beneficiarios b ON b.id = sa.beneficiario_id
LEFT JOIN public.clientes c ON c.id = sa.cliente_id
LEFT JOIN LATERAL (
  SELECT i.expires_at FROM public.ive_invitaciones i
  WHERE i.solicitud_alta_id = sa.id AND i.used_at IS NULL AND i.revoked_at IS NULL
  ORDER BY i.created_at DESC LIMIT 1
) inv ON true
WHERE public.d6_puede_ver_beneficiario(sa.beneficiario_id);

REVOKE ALL ON public.v_solicitudes_alta_marca FROM PUBLIC, anon;
GRANT SELECT ON public.v_solicitudes_alta_marca TO authenticated;

-- ============================================================================
-- 5. RPC de alta, invitacion y portal IVE
-- ============================================================================

CREATE SEQUENCE IF NOT EXISTS public.clientes_app_codigo_seq START WITH 900000001;
SELECT setval(
  'public.clientes_app_codigo_seq',
  GREATEST((SELECT COALESCE(MAX(codigo_contacto), 900000000) FROM public.clientes WHERE codigo_contacto >= 900000000), 900000000) + 1,
  false
);

CREATE OR REPLACE FUNCTION public.d6_normalizar_nit(p_nit TEXT)
RETURNS TEXT
LANGUAGE sql IMMUTABLE
AS $$
  SELECT NULLIF(regexp_replace(upper(COALESCE(p_nit, '')), '[^0-9A-Z]', '', 'g'), '');
$$;

-- Misma firma que la 018. Cambios: reutiliza un afianzado solo por NIT (nunca por
-- nombre), guarda lo que la marca escribio en los campos _tmp de la solicitud y usa
-- una secuencia para el codigo de los afianzados nuevos.
CREATE OR REPLACE FUNCTION public.d6_marca_crear_solicitud_alta(
  p_beneficiario_codigo INTEGER,
  p_cliente_nombre TEXT,
  p_cliente_email TEXT,
  p_monto NUMERIC,
  p_cliente_nit TEXT DEFAULT NULL,
  p_cliente_telefono TEXT DEFAULT NULL,
  p_tipo_persona public.tipo_persona DEFAULT 'INDIVIDUAL',
  p_vigencia_desde DATE DEFAULT NULL,
  p_vigencia_hasta DATE DEFAULT NULL,
  p_contrato_numero TEXT DEFAULT NULL,
  p_horas_ive INTEGER DEFAULT 72
)
RETURNS TABLE(solicitud_id UUID, numero_solicitud TEXT, ive_token TEXT, ive_expira TIMESTAMPTZ)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_beneficiario public.beneficiarios%ROWTYPE;
  v_cliente_id UUID;
  v_nit TEXT := public.d6_normalizar_nit(p_cliente_nit);
  v_solicitud_id UUID;
  v_numero TEXT;
  v_token TEXT := encode(extensions.gen_random_bytes(32), 'hex');
  v_expira TIMESTAMPTZ := now() + make_interval(hours => LEAST(GREATEST(COALESCE(p_horas_ive, 72), 1), 720));
  v_exposicion NUMERIC(15,2) := 0;
  v_desde DATE := COALESCE(p_vigencia_desde, CURRENT_DATE);
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Debe iniciar sesion para solicitar un alta';
  END IF;
  IF p_cliente_nombre IS NULL OR btrim(p_cliente_nombre) = '' THEN
    RAISE EXCEPTION 'El nombre del afianzado es obligatorio';
  END IF;
  IF p_cliente_email IS NULL OR btrim(p_cliente_email) !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
    RAISE EXCEPTION 'El correo del afianzado es obligatorio y debe ser valido: a ese correo llega el enlace del formulario IVE';
  END IF;
  IF COALESCE(p_monto, 0) <= 0 THEN
    RAISE EXCEPTION 'El monto solicitado debe ser mayor que cero';
  END IF;

  SELECT * INTO v_beneficiario FROM public.beneficiarios WHERE codigo_contacto = p_beneficiario_codigo;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'El beneficiario % no existe', p_beneficiario_codigo;
  END IF;

  IF NOT public.has_d6_role(ARRAY['admin', 'comercial', 'suscripcion']::public.d6_role[])
     AND NOT public.d6_beneficiario_es_mio(v_beneficiario.id) THEN
    RAISE EXCEPTION 'No puede solicitar altas de una marca que no es la suya';
  END IF;

  IF v_nit IS NOT NULL THEN
    SELECT id INTO v_cliente_id FROM public.clientes
    WHERE public.d6_normalizar_nit(nit) = v_nit
    ORDER BY created_at LIMIT 1;
  END IF;

  IF v_cliente_id IS NULL THEN
    INSERT INTO public.clientes (codigo_contacto, nombre, nit, tipo_persona, telefono, email)
    VALUES (
      nextval('public.clientes_app_codigo_seq'),
      regexp_replace(btrim(p_cliente_nombre), '\s+', ' ', 'g'),
      NULLIF(btrim(COALESCE(p_cliente_nit, '')), ''),
      COALESCE(p_tipo_persona, 'INDIVIDUAL'),
      NULLIF(btrim(COALESCE(p_cliente_telefono, '')), ''),
      btrim(p_cliente_email)
    )
    RETURNING id INTO v_cliente_id;
  END IF;

  SELECT COALESCE(SUM(monto_afianzado), 0) INTO v_exposicion
  FROM public.fianzas
  WHERE cliente_id = v_cliente_id
    AND operational_status IN ('VIGENTE', 'POR_RENOVAR', 'PENDIENTE_ANULACION');

  v_numero := 'ALT-' || to_char(now(), 'YYYY') || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));

  INSERT INTO public.solicitudes_alta (
    numero_solicitud, cliente_id, cliente_nombre_tmp, cliente_nit_tmp, beneficiario_id,
    monto_solicitado, vigencia_desde, vigencia_hasta, contrato_numero, tema_de_fianza,
    estado, estado_operativo, requiere_documento_accesorio, exposicion_vigente, creado_por
  ) VALUES (
    v_numero, v_cliente_id, regexp_replace(btrim(p_cliente_nombre), '\s+', ' ', 'g'),
    NULLIF(btrim(COALESCE(p_cliente_nit, '')), ''), v_beneficiario.id,
    p_monto, v_desde, COALESCE(p_vigencia_hasta, (v_desde + INTERVAL '1 year')::date),
    NULLIF(btrim(COALESCE(p_contrato_numero, '')), ''), 'Consignacion comercial',
    'BORRADOR', 'IVE_PENDIENTE',
    (p_monto > 300000 OR p_monto + v_exposicion > 300000), v_exposicion, auth.uid()
  )
  RETURNING id INTO v_solicitud_id;

  INSERT INTO public.ive_invitaciones (solicitud_alta_id, token_hash, destinatario_email, expires_at, created_by)
  VALUES (v_solicitud_id, encode(extensions.digest(v_token, 'sha256'), 'hex'), btrim(p_cliente_email), v_expira, auth.uid());

  INSERT INTO public.solicitud_revisiones (solicitud_alta_id, estado_anterior, estado_nuevo, comentario, creado_por)
  VALUES (v_solicitud_id, NULL, 'IVE_PENDIENTE', 'Alta solicitada', auth.uid());

  RETURN QUERY SELECT v_solicitud_id, v_numero, v_token, v_expira;
END;
$$;

-- Un link nuevo solo mientras el afianzado todavia tiene algo que entregar. Con el
-- expediente recibido o en revision no se reemite: el afianzado sobrescribiria lo
-- que Suscripcion ya esta revisando.
CREATE OR REPLACE FUNCTION public.crear_invitacion_ive(p_solicitud_id UUID, p_destinatario_email TEXT, p_horas INTEGER DEFAULT 72)
RETURNS TABLE(token TEXT, expires_at TIMESTAMPTZ)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_token TEXT := encode(extensions.gen_random_bytes(32), 'hex');
  v_expires_at TIMESTAMPTZ := now() + make_interval(hours => LEAST(GREATEST(COALESCE(p_horas, 72), 1), 720));
  v_solicitud public.solicitudes_alta%ROWTYPE;
  v_es_personal BOOLEAN := public.has_d6_role(ARRAY['admin', 'comercial', 'suscripcion']::public.d6_role[]);
BEGIN
  SELECT * INTO v_solicitud FROM public.solicitudes_alta WHERE id = p_solicitud_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'La solicitud de alta no existe';
  END IF;
  IF NOT v_es_personal AND NOT public.d6_beneficiario_es_mio(v_solicitud.beneficiario_id) THEN
    RAISE EXCEPTION 'No tiene permiso para crear invitaciones IVE de este expediente';
  END IF;
  IF p_destinatario_email IS NULL OR btrim(p_destinatario_email) !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
    RAISE EXCEPTION 'Indique un correo valido para el afianzado';
  END IF;
  IF v_solicitud.estado_operativo NOT IN ('BORRADOR', 'IVE_PENDIENTE', 'INFORMACION_COMPLEMENTARIA')
     AND NOT (v_es_personal AND v_solicitud.estado_operativo = 'SUSPENDIDA') THEN
    RAISE EXCEPTION 'El expediente esta en estado % y no admite un enlace IVE nuevo', v_solicitud.estado_operativo;
  END IF;

  UPDATE public.ive_invitaciones SET revoked_at = now()
  WHERE solicitud_alta_id = p_solicitud_id AND used_at IS NULL AND revoked_at IS NULL;
  INSERT INTO public.ive_invitaciones (solicitud_alta_id, token_hash, destinatario_email, expires_at, created_by)
  VALUES (p_solicitud_id, encode(extensions.digest(v_token, 'sha256'), 'hex'), btrim(p_destinatario_email), v_expires_at, auth.uid());

  IF v_solicitud.estado_operativo IN ('BORRADOR', 'SUSPENDIDA') THEN
    UPDATE public.solicitudes_alta SET estado_operativo = 'IVE_PENDIENTE' WHERE id = p_solicitud_id;
    INSERT INTO public.solicitud_revisiones (solicitud_alta_id, estado_anterior, estado_nuevo, comentario, creado_por)
    VALUES (p_solicitud_id, v_solicitud.estado_operativo, 'IVE_PENDIENTE', 'Enlace IVE enviado', auth.uid());
  END IF;
  RETURN QUERY SELECT v_token, v_expires_at;
END;
$$;

CREATE OR REPLACE FUNCTION public.completar_ive_invitacion(p_token TEXT, p_datos JSONB)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_invitacion public.ive_invitaciones%ROWTYPE;
  v_estado public.d6_solicitud_status;
BEGIN
  SELECT * INTO v_invitacion FROM public.ive_invitaciones
  WHERE token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
    AND used_at IS NULL AND revoked_at IS NULL AND expires_at > now()
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'El enlace no es valido, expiro o fue reemplazado por uno nuevo';
  END IF;

  SELECT estado_operativo INTO v_estado FROM public.solicitudes_alta
  WHERE id = v_invitacion.solicitud_alta_id FOR UPDATE;
  IF v_estado NOT IN ('IVE_PENDIENTE', 'INFORMACION_COMPLEMENTARIA') THEN
    RAISE EXCEPTION 'Este expediente ya no recibe cambios del formulario (estado %)', v_estado;
  END IF;

  PERFORM public.validar_datos_ive_d6(p_datos);

  UPDATE public.ive_invitaciones SET used_at = now() WHERE id = v_invitacion.id;
  UPDATE public.solicitudes_alta
  SET ive_data = p_datos,
      ive_form_version = COALESCE(NULLIF(p_datos->>'versionFormulario', ''), 'FIDELIS-D6-2026.1'),
      ive_completed_at = now(),
      estado_operativo = 'EXPEDIENTE_RECIBIDO'
  WHERE id = v_invitacion.solicitud_alta_id;
  INSERT INTO public.solicitud_revisiones (solicitud_alta_id, estado_anterior, estado_nuevo, comentario, creado_por)
  VALUES (v_invitacion.solicitud_alta_id, v_estado, 'EXPEDIENTE_RECIBIDO', 'Formulario IVE completado por el afianzado', NULL);
  RETURN v_invitacion.solicitud_alta_id;
END;
$$;

-- Las funciones auxiliares no las llama nadie sin sesion.
REVOKE EXECUTE ON FUNCTION public.d6_marca_crear_solicitud_alta(
  INTEGER, TEXT, TEXT, NUMERIC, TEXT, TEXT, public.tipo_persona, DATE, DATE, TEXT, INTEGER
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.d6_marca_crear_solicitud_alta(
  INTEGER, TEXT, TEXT, NUMERIC, TEXT, TEXT, public.tipo_persona, DATE, DATE, TEXT, INTEGER
) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.crear_invitacion_ive(UUID, TEXT, INTEGER) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crear_invitacion_ive(UUID, TEXT, INTEGER) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.transicionar_solicitud_alta(UUID, public.d6_solicitud_status, TEXT, NUMERIC, TEXT) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.emitir_fianza_d6(UUID, BIGINT, DATE, DATE, NUMERIC, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.completar_ive_invitacion(TEXT, JSONB) TO anon, authenticated;

-- ============================================================================
-- 6. Marcas: Honda y Suzuki son competidoras y no pueden compartir grupo
-- ============================================================================
INSERT INTO public.grupos_beneficiarios (codigo, nombre, descripcion) VALUES
  ('GRP-HONDA', 'Honda', 'Agencia y Fabrica Honda'),
  ('GRP-SUZUKI', 'Suzuki', 'Suzuki, S.A. (todos sus codigos de beneficiario)')
ON CONFLICT (codigo) DO UPDATE SET nombre = EXCLUDED.nombre, descripcion = EXCLUDED.descripcion;

INSERT INTO public.grupo_beneficiario_rel (grupo_id, beneficiario_id)
SELECT g.id, b.id
FROM public.beneficiarios b
JOIN public.grupos_beneficiarios g
  ON (g.codigo = 'GRP-HONDA' AND b.nombre ILIKE '%HONDA%')
  OR (g.codigo = 'GRP-SUZUKI' AND b.nombre ILIKE '%SUZUKI%')
ON CONFLICT (grupo_id, beneficiario_id) DO NOTHING;

-- Quien tenia el grupo mezclado conserva acceso solo si un admin lo reasigna.
DELETE FROM public.user_grupos
WHERE grupo_id = (SELECT id FROM public.grupos_beneficiarios WHERE codigo = 'GRP-HONDA-SUZUKI');
DELETE FROM public.grupos_beneficiarios WHERE codigo = 'GRP-HONDA-SUZUKI';

UPDATE public.grupos_beneficiarios SET nombre = 'Central Americana / Motopremium (ADMOSA)'
WHERE codigo = 'GRP-CENTRAL-MOTOPREMIUM';
UPDATE public.grupos_beneficiarios SET nombre = 'Indy Motos' WHERE codigo = 'GRP-INDY-MOTOS';
UPDATE public.grupos_beneficiarios SET nombre = 'Grupo UMA (Unidades Moviles)' WHERE codigo = 'GRP-UNIDADES-MOVILES';
