-- 042: decisiones del 2026-10-09.
--   1. Sin segundo paso (MFA). Se retira: era demasiado para el uso de la app.
--   2. La marca edita la solicitud de su distribuidor hasta que Suscripcion decida, tambien
--      despues del envio. Cada cambio queda registrado campo por campo: quien, cuando, antes y despues.
--   3. Quien entra por el enlace del IVE solo puede llenar su solicitud y subir sus documentos.
--      No hay "usuario anonimo" con otras funciones: sin acceso a tablas, vistas ni secuencias,
--      y por la API solo las 6 funciones del portal, todas atadas a la solicitud de su enlace.

-- ============================================================================
-- 1. Sin segundo paso
-- ============================================================================
CREATE OR REPLACE FUNCTION public.d6_rol_real(p_roles public.d6_role[])
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT auth.uid() IS NOT NULL
     AND EXISTS (SELECT 1 FROM public.user_profiles WHERE id = auth.uid() AND activo)
     AND EXISTS (SELECT 1 FROM public.user_role_assignments WHERE user_id = auth.uid() AND role = ANY (p_roles));
$$;
DROP FUNCTION IF EXISTS public.d6_reiniciar_segundo_factor(UUID);

-- ============================================================================
-- 2. La marca edita la solicitud de su distribuidor, con registro
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.alta_cambios_d6 (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  solicitud_alta_id UUID NOT NULL REFERENCES public.solicitudes_alta(id) ON DELETE RESTRICT,
  campo TEXT NOT NULL,
  antes JSONB,
  despues JSONB,
  etapa TEXT NOT NULL CHECK (etapa IN ('BORRADOR', 'ENVIADA')),
  origen TEXT NOT NULL CHECK (origen IN ('MARCA', 'FIDELIS')),
  hecho_por UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  hecho_por_email TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.alta_cambios_d6 IS 'Cambios de la marca o de Fidelis a los datos IVE de una solicitud. No se edita ni se borra.';
CREATE INDEX IF NOT EXISTS idx_alta_cambios_solicitud ON public.alta_cambios_d6 (solicitud_alta_id, created_at DESC);
ALTER TABLE public.alta_cambios_d6 ENABLE ROW LEVEL SECURITY;
-- La marca no lee solicitudes_alta (trae el IVE): el chequeo va en una funcion definer.
CREATE OR REPLACE FUNCTION public.d6_puede_ver_solicitud(p_solicitud_id UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT EXISTS (SELECT 1 FROM public.solicitudes_alta sa
                 WHERE sa.id = p_solicitud_id AND public.d6_puede_ver_beneficiario(sa.beneficiario_id));
$$;
REVOKE EXECUTE ON FUNCTION public.d6_puede_ver_solicitud(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.d6_puede_ver_solicitud(UUID) TO authenticated;
DROP POLICY IF EXISTS "alta_cambios: quien ve la solicitud" ON public.alta_cambios_d6;
CREATE POLICY "alta_cambios: quien ve la solicitud" ON public.alta_cambios_d6 FOR SELECT TO authenticated
  USING (public.d6_puede_ver_solicitud(solicitud_alta_id));
REVOKE ALL ON public.alta_cambios_d6 FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.alta_cambios_d6 FROM authenticated;
GRANT SELECT ON public.alta_cambios_d6 TO authenticated;
DROP TRIGGER IF EXISTS trg_alta_cambios_inmutable ON public.alta_cambios_d6;
CREATE TRIGGER trg_alta_cambios_inmutable BEFORE UPDATE OR DELETE ON public.alta_cambios_d6
  FOR EACH ROW EXECUTE FUNCTION public.d6_bitacora_inmutable();

-- Editable por la marca (o por Fidelis) hasta que Suscripcion decide.
CREATE OR REPLACE FUNCTION public.d6_alta_editable(p_sol public.solicitudes_alta)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT p_sol.estado_operativo IN ('BORRADOR', 'IVE_PENDIENTE', 'INFORMACION_COMPLEMENTARIA', 'EXPEDIENTE_RECIBIDO', 'EN_REVISION')
    AND (public.has_d6_role(ARRAY['admin', 'comercial', 'suscripcion']::public.d6_role[])
         OR public.d6_beneficiario_es_mio(p_sol.beneficiario_id));
$$;
REVOKE EXECUTE ON FUNCTION public.d6_alta_editable(public.solicitudes_alta) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.d6_alta_guardar_borrador(p_solicitud_id UUID, p_cambios JSONB)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_sol public.solicitudes_alta;
  v_cambios JSONB := public.d6_sin_firma(p_cambios);
  v_enviada BOOLEAN;
  v_antes JSONB;
  v_despues JSONB;
  v_campo TEXT;
  v_origen TEXT := CASE WHEN public.d6_es_personal_aseguradora() THEN 'FIDELIS' ELSE 'MARCA' END;
  v_email TEXT := (SELECT email FROM public.user_profiles WHERE id = auth.uid());
BEGIN
  SELECT * INTO v_sol FROM public.solicitudes_alta WHERE id = p_solicitud_id FOR UPDATE;
  IF NOT FOUND OR NOT public.d6_alta_editable(v_sol) THEN
    RAISE EXCEPTION 'Esta solicitud ya no se puede editar';
  END IF;
  IF pg_column_size(p_cambios) > 512000 THEN RAISE EXCEPTION 'Los datos son demasiado grandes'; END IF;

  -- Ya enviada: se edita el formulario enviado. Antes del envio: el borrador compartido.
  v_enviada := v_sol.ive_data IS NOT NULL AND v_sol.estado_operativo IN ('EXPEDIENTE_RECIBIDO', 'EN_REVISION');
  v_antes := CASE WHEN v_enviada THEN v_sol.ive_data ELSE COALESCE(v_sol.ive_borrador, '{}'::jsonb) END;
  v_despues := v_antes || v_cambios;
  IF v_despues = v_antes THEN RETURN; END IF;

  IF v_enviada THEN
    -- Un formulario enviado no queda incompleto por una edicion.
    PERFORM public.validar_datos_ive_d6(v_despues);
    UPDATE public.solicitudes_alta SET ive_data = v_despues WHERE id = p_solicitud_id;
  ELSE
    UPDATE public.solicitudes_alta SET ive_borrador = v_despues WHERE id = p_solicitud_id;
  END IF;

  FOR v_campo IN SELECT jsonb_object_keys(v_cambios) LOOP
    IF v_antes -> v_campo IS DISTINCT FROM v_despues -> v_campo THEN
      INSERT INTO public.alta_cambios_d6 (solicitud_alta_id, campo, antes, despues, etapa, origen, hecho_por, hecho_por_email)
      VALUES (p_solicitud_id, v_campo, v_antes -> v_campo, v_despues -> v_campo,
              CASE WHEN v_enviada THEN 'ENVIADA' ELSE 'BORRADOR' END, v_origen, auth.uid(), v_email);
    END IF;
  END LOOP;
END;
$$;

-- Lo que la marca ve y edita: el formulario enviado o el borrador, sin firma ni declaracion.
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
    'recibe_documentos', public.d6_alta_recibe_documentos(v_sol),
    'enviado', v_sol.ive_completed_at IS NOT NULL,
    'borrador', CASE WHEN v_editable
                     THEN public.d6_sin_firma(COALESCE(v_sol.ive_data, '{}'::jsonb) || COALESCE(v_sol.ive_borrador, '{}'::jsonb)) END,
    'cambios', (SELECT count(*) FROM public.alta_cambios_d6 c WHERE c.solicitud_alta_id = v_sol.id),
    'cambios_despues_del_envio', (SELECT count(*) FROM public.alta_cambios_d6 c WHERE c.solicitud_alta_id = v_sol.id AND c.etapa = 'ENVIADA'),
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

-- El registro de cambios de una solicitud, para la marca y para Suscripcion.
CREATE OR REPLACE FUNCTION public.d6_alta_cambios(p_solicitud_id UUID)
RETURNS TABLE(fecha TIMESTAMPTZ, quien TEXT, origen TEXT, etapa TEXT, campo TEXT, antes JSONB, despues JSONB)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public
AS $$
  SELECT c.created_at, c.hecho_por_email, c.origen, c.etapa, c.campo, c.antes, c.despues
  FROM public.alta_cambios_d6 c
  WHERE c.solicitud_alta_id = p_solicitud_id
  ORDER BY c.created_at DESC, c.campo;
$$;
REVOKE EXECUTE ON FUNCTION public.d6_alta_cambios(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.d6_alta_cambios(UUID) TO authenticated;

-- ============================================================================
-- 3. El enlace del IVE solo sirve para llenar la solicitud
-- ============================================================================
-- Sin seguimiento ni otra funcion: el enlace llena y envia su solicitud, nada mas.
DROP FUNCTION IF EXISTS public.portal_ive_seguimiento(TEXT);
DROP FUNCTION IF EXISTS public.d6_estado_para_distribuidor(public.d6_solicitud_status);

-- Ninguna tabla, vista ni secuencia para anon. Hoy RLS ya lo frenaba: ahora ni siquiera hay permiso.
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON TABLES FROM anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON SEQUENCES FROM anon;

-- El chequeo de la ruta reservada que usa Storage sale del esquema que publica la API.
CREATE SCHEMA IF NOT EXISTS d6_privado;
REVOKE ALL ON SCHEMA d6_privado FROM PUBLIC;
GRANT USAGE ON SCHEMA d6_privado TO anon, authenticated, service_role;
CREATE OR REPLACE FUNCTION d6_privado.ruta_reservada(p_name TEXT)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.documentos d
    WHERE d.file_path = p_name AND d.carga_pendiente AND d.carga_expira > now()
  );
$$;
REVOKE EXECUTE ON FUNCTION d6_privado.ruta_reservada(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION d6_privado.ruta_reservada(TEXT) TO anon, authenticated;

-- Politicas de Storage: el portal solo inserta en su ruta reservada. Todo lo demas es solo
-- para usuarios con sesion, y ya no se evalua para quien llega por el enlace.
DROP POLICY IF EXISTS "expedientes: afianzado sube a ruta reservada" ON storage.objects;
CREATE POLICY "expedientes: afianzado sube a ruta reservada" ON storage.objects FOR INSERT
  TO anon, authenticated
  WITH CHECK (bucket_id = 'expedientes' AND split_part(name, '/', 1) = 'altas' AND d6_privado.ruta_reservada(name));

DROP POLICY IF EXISTS "expedientes: personal ve archivos" ON storage.objects;
CREATE POLICY "expedientes: personal ve archivos" ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'expedientes' AND public.d6_es_personal_aseguradora());
DROP POLICY IF EXISTS "expedientes: personal carga archivos" ON storage.objects;
CREATE POLICY "expedientes: personal carga archivos" ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'expedientes'
    AND public.has_d6_role(ARRAY['admin', 'comercial', 'suscripcion', 'cobros', 'contabilidad']::public.d6_role[]));
DROP POLICY IF EXISTS "expedientes: marca descarga archivos autorizados" ON storage.objects;
CREATE POLICY "expedientes: marca descarga archivos autorizados" ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'expedientes' AND EXISTS (
    SELECT 1 FROM public.documentos d WHERE d.file_path = storage.objects.name AND public.d6_puede_ver_documento(d.id)));
DROP POLICY IF EXISTS "expedientes: marca carga cartas de sus bajas" ON storage.objects;
CREATE POLICY "expedientes: marca carga cartas de sus bajas" ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'expedientes' AND split_part(name, '/', 1) = 'bajas'
    AND split_part(name, '/', 2) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    AND public.d6_baja_es_mia(split_part(name, '/', 2)::uuid));
DROP POLICY IF EXISTS "expedientes: marca carga evidencia de sus reclamos" ON storage.objects;
CREATE POLICY "expedientes: marca carga evidencia de sus reclamos" ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'expedientes' AND split_part(name, '/', 1) = 'reclamos'
    AND split_part(name, '/', 2) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    AND public.d6_reclamo_es_mio(split_part(name, '/', 2)::uuid));

-- La version publica del chequeo ya no se usa.
DROP FUNCTION IF EXISTS public.d6_ruta_reservada(TEXT);

-- Para anon, de todas las funciones de public solo quedan las 6 del portal. Las politicas de
-- las tablas tampoco se evaluan para anon: no tiene permiso sobre ninguna tabla.
DO $$
DECLARE
  r RECORD;
  v_portal TEXT[] := ARRAY['portal_ive_contexto', 'portal_ive_guardar_borrador', 'portal_ive_preparar_carga',
                           'portal_ive_confirmar_carga', 'portal_ive_quitar_documento', 'completar_ive_invitacion'];
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS firma, p.proname FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f'
      AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon', r.firma);
    IF r.proname = ANY (v_portal) THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO anon', r.firma);
    END IF;
  END LOOP;
END $$;
