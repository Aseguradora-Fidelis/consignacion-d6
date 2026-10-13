-- 031: separacion estricta entre marcas y modo reunion.
-- UMA y ADMOSA son competidoras: una marca nunca ve nada de otra. Solo el personal de Fidelis
-- ve todas. Para reuniones con un cliente el personal elige una marca y la base de datos le
-- responde exactamente como a esa marca: lo filtra la seguridad de Postgres, no la pantalla.
--
-- La marca elegida llega en el encabezado HTTP x-d6-marca (id del grupo). Solo cuenta si quien
-- consulta es personal. Con la marca elegida el personal deja de ser personal para todas las
-- politicas y funciones: no ve tableros internos, ni perfiles, ni datos de otras marcas.

-- ============================================================================
-- Rol real, sin modo reunion. Solo para decidir si el encabezado aplica.

CREATE OR REPLACE FUNCTION public.d6_rol_real(p_roles public.d6_role[])
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT auth.uid() IS NOT NULL AND (
    EXISTS (SELECT 1 FROM public.user_role_assignments WHERE user_id = auth.uid() AND role = ANY (p_roles))
    OR public.get_user_role(auth.uid()) = 'admin'
  );
$$;

CREATE OR REPLACE FUNCTION public.d6_es_personal_real()
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT public.d6_rol_real(ARRAY['admin', 'comercial', 'suscripcion', 'coordinacion_comercial',
    'cobros', 'contabilidad', 'consulta']::public.d6_role[]);
$$;

-- Marca en pantalla. Un encabezado invalido no muestra nada.
CREATE OR REPLACE FUNCTION public.d6_marca_en_vista()
RETURNS UUID
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v TEXT;
BEGIN
  v := NULLIF(current_setting('request.headers', true), '')::json->>'x-d6-marca';
  IF NULLIF(btrim(COALESCE(v, '')), '') IS NULL THEN RETURN NULL; END IF;
  IF NOT public.d6_es_personal_real() THEN RETURN NULL; END IF;
  RETURN v::uuid;
EXCEPTION WHEN OTHERS THEN
  RETURN '00000000-0000-0000-0000-000000000000'::uuid;
END;
$$;

-- Con una marca en pantalla, ningun rol interno aplica.
CREATE OR REPLACE FUNCTION public.has_d6_role(p_roles public.d6_role[])
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT public.d6_rol_real(p_roles) AND public.d6_marca_en_vista() IS NULL;
$$;

-- Grupos (marcas) de quien consulta: los suyos, o la marca en pantalla.
CREATE OR REPLACE FUNCTION public.d6_mis_grupos()
RETURNS SETOF UUID
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_vista UUID := public.d6_marca_en_vista();
BEGIN
  IF v_vista IS NOT NULL THEN
    RETURN NEXT v_vista;
    RETURN;
  END IF;
  RETURN QUERY SELECT ug.grupo_id FROM public.user_grupos ug WHERE ug.user_id = auth.uid();
END;
$$;
REVOKE EXECUTE ON FUNCTION public.d6_mis_grupos() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.d6_mis_grupos() TO authenticated;

CREATE OR REPLACE FUNCTION public.get_user_beneficiario_ids(p_user_id UUID DEFAULT auth.uid())
RETURNS TABLE(beneficiario_id UUID)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF p_user_id IS NULL THEN RETURN; END IF;
  IF p_user_id IS DISTINCT FROM auth.uid() AND NOT public.d6_es_personal_aseguradora() THEN RETURN; END IF;
  IF p_user_id = auth.uid() THEN
    RETURN QUERY
    SELECT DISTINCT gbr.beneficiario_id FROM public.grupo_beneficiario_rel gbr
    WHERE gbr.grupo_id IN (SELECT public.d6_mis_grupos());
    RETURN;
  END IF;
  RETURN QUERY
  SELECT DISTINCT gbr.beneficiario_id
  FROM public.user_grupos ug
  JOIN public.grupo_beneficiario_rel gbr ON gbr.grupo_id = ug.grupo_id
  WHERE ug.user_id = p_user_id;
END;
$$;

-- Lista de marcas para el selector del personal. No depende del modo reunion.
CREATE OR REPLACE FUNCTION public.d6_marcas_para_vista()
RETURNS TABLE(id UUID, codigo TEXT, nombre TEXT)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NOT public.d6_es_personal_real() THEN RETURN; END IF;
  RETURN QUERY SELECT g.id, g.codigo, g.nombre FROM public.grupos_beneficiarios g
  WHERE g.codigo <> 'GRP-GENERAL' ORDER BY g.nombre;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.d6_marcas_para_vista() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.d6_marcas_para_vista() TO authenticated;

-- ============================================================================
-- Politicas que leian user_grupos directo pasan por d6_mis_grupos.

DROP POLICY IF EXISTS "condiciones: personal y la propia marca ven" ON public.condiciones_marca_d6;
CREATE POLICY "condiciones: personal y la propia marca ven" ON public.condiciones_marca_d6 FOR SELECT
  USING (public.d6_es_personal_aseguradora() OR grupo_id IN (SELECT public.d6_mis_grupos()));

DROP POLICY IF EXISTS "comunicaciones: personal ve" ON public.comunicaciones_d6;
CREATE POLICY "comunicaciones: personal ve" ON public.comunicaciones_d6 FOR SELECT
  USING (public.d6_es_personal_aseguradora() OR (visible_marca AND grupo_id IN (SELECT public.d6_mis_grupos())));

DROP POLICY IF EXISTS "grupos: personal o miembros ven" ON public.grupos_beneficiarios;
CREATE POLICY "grupos: personal o miembros ven" ON public.grupos_beneficiarios FOR SELECT
  USING (public.d6_es_personal_aseguradora() OR id IN (SELECT public.d6_mis_grupos()));

DROP POLICY IF EXISTS "grupo_rel: personal o miembros ven" ON public.grupo_beneficiario_rel;
CREATE POLICY "grupo_rel: personal o miembros ven" ON public.grupo_beneficiario_rel FOR SELECT
  USING (public.d6_es_personal_aseguradora() OR grupo_id IN (SELECT public.d6_mis_grupos()));

DROP POLICY IF EXISTS "estados_cuenta: personal o la propia marca ven" ON public.estados_cuenta_d6;
CREATE POLICY "estados_cuenta: personal o la propia marca ven" ON public.estados_cuenta_d6 FOR SELECT
  USING (public.d6_es_personal_aseguradora() OR grupo_id IN (SELECT public.d6_mis_grupos())
         OR public.d6_beneficiario_es_mio(beneficiario_id));

-- Las notificaciones del personal hablan de todas las marcas: no se muestran en una reunion.
DO $$
DECLARE
  p RECORD;
BEGIN
  FOR p IN SELECT policyname, qual FROM pg_policies
           WHERE schemaname = 'public' AND tablename = 'notificaciones' AND cmd = 'SELECT'
  LOOP
    EXECUTE format('ALTER POLICY %I ON public.notificaciones USING ((%s) AND public.d6_marca_en_vista() IS NULL)',
      p.policyname, p.qual);
  END LOOP;
END;
$$;

-- ============================================================================
-- Un usuario de marca pertenece a una sola marca.

CREATE OR REPLACE FUNCTION public.d6_una_marca_por_usuario()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.user_grupos ug WHERE ug.user_id = NEW.user_id AND ug.grupo_id <> NEW.grupo_id) THEN
    RAISE EXCEPTION 'Un usuario de marca solo puede pertenecer a una marca. Cree un usuario distinto para cada marca.';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_una_marca_por_usuario ON public.user_grupos;
CREATE TRIGGER trg_una_marca_por_usuario BEFORE INSERT OR UPDATE ON public.user_grupos
  FOR EACH ROW EXECUTE FUNCTION public.d6_una_marca_por_usuario();

-- ============================================================================
-- El documento accesorio depende de lo que el afianzado tiene con TODAS las marcas. Si la marca
-- lo viera, sabria que su distribuidor tiene fianzas con la competencia. Solo lo ve Fidelis.

CREATE OR REPLACE VIEW public.v_fianzas
WITH (security_invoker = true)
AS
SELECT
  f.id, f.fianza, f.endoso, f.clase,
  f.cliente_id, c.codigo_contacto AS cliente_codigo, c.nombre AS cliente_nombre, c.nit AS cliente_nit,
  f.beneficiario_id, b.codigo_contacto AS beneficiario_codigo, b.nombre AS beneficiario_nombre,
  g.id AS marca_id, g.nombre AS marca_nombre,
  f.fecha_emision, f.vigencia_desde, f.vigencia_hasta, f.fecha_cancelacion, f.fecha_anulacion,
  f.status_raw, f.cod_estado_poliza, f.operational_status,
  CASE
    WHEN f.operational_status = 'ANULADA' OR f.status = 'ANULADA' THEN 'ANULADA'
    WHEN f.operational_status = 'CANCELADA' OR f.status = 'CANCELADA' OR f.status_raw = 'C' THEN 'CANCELADA'
    WHEN f.operational_status = 'PENDIENTE_ANULACION' THEN 'EN_BAJA'
    WHEN f.vigencia_hasta < CURRENT_DATE THEN 'VENCIDA'
    WHEN f.vigencia_hasta <= CURRENT_DATE + 60 THEN 'POR_RENOVAR'
    ELSE 'VIGENTE'
  END AS estado,
  f.monto_afianzado,
  CASE WHEN COALESCE(f.monto_afianzado, 0) = 0 THEN COALESCE(f.contrato_valor, 0) ELSE f.monto_afianzado END AS monto_original,
  f.prima, f.derechos, f.iva, f.prima_anual,
  f.contrato_numero, f.contrato_fecha, f.contrato_valor, f.lote_fiso, f.dte_numero,
  f.pago_confirmado_at,
  (COALESCE(rc.entrega_condicionada_pago, false) AND f.pago_confirmado_at IS NULL
     AND f.operational_status = 'VIGENTE') AS entrega_pendiente_pago,
  f.created_at, f.updated_at,
  CASE
    WHEN f.operational_status = 'PENDIENTE_ANULACION' THEN 'CANCELA'
    WHEN (f.operational_status IN ('CANCELADA', 'ANULADA') OR f.status_raw = 'C')
         AND COALESCE(f.fecha_cancelacion, f.fecha_anulacion) >= (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date
      THEN 'CANCELADA'
    WHEN f.fecha_emision >= (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date
         AND f.operational_status IN ('VIGENTE', 'POR_RENOVAR') THEN 'NUEVA'
  END AS movimiento,
  CASE WHEN p.es THEN f.requiere_accesorio ELSE false END AS requiere_accesorio,
  CASE WHEN p.es THEN f.accesorio_estado ELSE 'NO_APLICA' END AS accesorio_estado,
  CASE WHEN p.es THEN f.accesorio_nota END AS accesorio_nota,
  CASE WHEN p.es THEN f.accesorio_at END AS accesorio_at,
  f.entrega_estado, f.entregada_at, f.entregada_a,
  CASE WHEN p.es THEN f.entrega_nota END AS entrega_nota,
  f.reemplaza_fianza_id
FROM public.fianzas f
CROSS JOIN LATERAL (SELECT public.d6_es_personal_aseguradora() AS es) p
JOIN public.clientes c ON c.id = f.cliente_id
JOIN public.beneficiarios b ON b.id = f.beneficiario_id
LEFT JOIN LATERAL (
  SELECT gb.id, gb.nombre, gb.codigo_regla_cobro FROM public.grupo_beneficiario_rel r
  JOIN public.grupos_beneficiarios gb ON gb.id = r.grupo_id
  WHERE r.beneficiario_id = b.id AND gb.codigo <> 'GRP-GENERAL'
  ORDER BY gb.codigo LIMIT 1
) g ON true
LEFT JOIN public.reglas_cobro_d6 rc ON rc.codigo_marca = g.codigo_regla_cobro
WHERE f.operational_status <> 'REEMPLAZADA_POR_ENDOSO';

-- ============================================================================
-- Un incremento solo puede apuntar a una fianza de la misma marca.

CREATE OR REPLACE FUNCTION public.d6_vincular_fianza_anterior(p_solicitud_id UUID, p_fianza_id UUID, p_tipo TEXT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_sol public.solicitudes_alta%ROWTYPE;
  v_f public.fianzas%ROWTYPE;
BEGIN
  IF p_tipo NOT IN ('INCREMENTO', 'RENOVACION') THEN RAISE EXCEPTION 'Tipo de solicitud no valido'; END IF;
  SELECT * INTO v_sol FROM public.solicitudes_alta WHERE id = p_solicitud_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Solicitud no encontrada'; END IF;
  SELECT * INTO v_f FROM public.fianzas WHERE id = p_fianza_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Fianza no encontrada'; END IF;
  IF NOT public.has_d6_role(ARRAY['admin', 'comercial', 'suscripcion']::public.d6_role[])
     AND NOT (public.d6_beneficiario_es_mio(v_f.beneficiario_id) AND v_sol.creado_por = auth.uid()) THEN
    RAISE EXCEPTION 'No puede vincular esta fianza';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.grupo_beneficiario_rel a
    JOIN public.grupo_beneficiario_rel b ON b.grupo_id = a.grupo_id
    JOIN public.grupos_beneficiarios g ON g.id = a.grupo_id AND g.codigo <> 'GRP-GENERAL'
    WHERE a.beneficiario_id = v_sol.beneficiario_id AND b.beneficiario_id = v_f.beneficiario_id
  ) THEN
    RAISE EXCEPTION 'La fianza es de otra marca. Un incremento solo se pide sobre una fianza de la misma marca.';
  END IF;
  IF v_sol.estado_operativo IN ('EMITIDA', 'NO_ELEGIBLE', 'CANCELADA') THEN
    RAISE EXCEPTION 'La solicitud ya esta cerrada';
  END IF;
  UPDATE public.solicitudes_alta SET
    tipo_solicitud = p_tipo, fianza_anterior_id = p_fianza_id, cliente_id = v_f.cliente_id
  WHERE id = p_solicitud_id;
END;
$$;

-- ============================================================================
-- Portal: el formulario se precarga solo con lo que el afianzado lleno para la MISMA marca.
-- El enlace lo comparte la marca; con datos de otra solicitud veria lo que se le dio a la competencia.

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
  IF v_sol.ive_borrador IS NULL AND v_sol.ive_data IS NULL AND v_sol.cliente_id IS NOT NULL THEN
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
    'marca', (SELECT nombre FROM public.beneficiarios WHERE id = v_sol.beneficiario_id),
    'afianzado', v_sol.cliente_nombre_tmp,
    'tipo_persona', v_sol.tipo_persona,
    'tipo_solicitud', v_sol.tipo_solicitud,
    'monto_solicitado', v_sol.monto_solicitado,
    'expira', v_inv.expires_at,
    'comentario', CASE WHEN v_sol.estado_operativo = 'INFORMACION_COMPLEMENTARIA' THEN v_sol.resolucion_comentario END,
    'faltantes', v_sol.faltantes,
    'borrador', COALESCE(v_sol.ive_borrador, v_sol.ive_data, v_previo),
    'precargado', v_previo IS NOT NULL,
    'requisitos', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'categoria', r.categoria, 'nombre', r.nombre, 'ayuda', r.ayuda, 'obligatorio', r.obligatorio,
        'documentos', COALESCE((
          SELECT jsonb_agg(jsonb_build_object(
            'id', d.id, 'nombre_archivo', d.nombre_archivo, 'estado', d.estado_revision,
            'comentario', d.comentario_revision, 'subido', d.created_at) ORDER BY d.created_at)
          FROM public.documentos d
          WHERE d.solicitud_alta_id = v_sol.id AND d.categoria = r.categoria AND NOT d.carga_pendiente
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

-- Nombre sencillo: es el formulario IVE, sin codigos.
UPDATE public.ive_requisitos_d6 SET nombre = 'Formulario IVE' WHERE categoria IN ('IVE_ASS_01', 'IVE_ASS_02');
