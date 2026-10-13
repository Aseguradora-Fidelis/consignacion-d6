-- 041: avisos por correo y seguimiento del distribuidor (auditoria del 2026-10-08).
--   * Antes ningun aviso salia de la app: todo quedaba en la campana. Ahora las decisiones
--     de Suscripcion, los documentos rechazados y los estados de cuenta enviados dejan un
--     correo en una bandeja de salida. La funcion enviar-correos los manda con Resend.
--     Sin RESEND_API_KEY la bandeja se acumula sin enviar nada.
--   * El estado de cuenta va a la marca con copia a Cobros (procedimiento v01).
--   * El distribuidor puede ver en que va su solicitud con el mismo enlace, ya usado.

-- ============================================================================
-- 1. Bandeja de salida
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.correos_salida_d6 (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  para TEXT[] NOT NULL,
  copia TEXT[] NOT NULL DEFAULT '{}',
  asunto TEXT NOT NULL,
  cuerpo TEXT NOT NULL,
  motivo TEXT NOT NULL,
  solicitud_alta_id UUID REFERENCES public.solicitudes_alta(id) ON DELETE RESTRICT,
  estado_cuenta_id UUID REFERENCES public.estados_cuenta_d6(id) ON DELETE RESTRICT,
  estado TEXT NOT NULL DEFAULT 'PENDIENTE' CHECK (estado IN ('PENDIENTE', 'ENVIADO', 'FALLIDO')),
  intentos INTEGER NOT NULL DEFAULT 0,
  error TEXT,
  proveedor_id TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  enviado_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_correos_pendientes ON public.correos_salida_d6 (created_at) WHERE estado = 'PENDIENTE';
ALTER TABLE public.correos_salida_d6 ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "correos: personal ve" ON public.correos_salida_d6;
CREATE POLICY "correos: personal ve" ON public.correos_salida_d6 FOR SELECT
  USING ((SELECT public.d6_es_personal_aseguradora()));
REVOKE ALL ON public.correos_salida_d6 FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.correos_salida_d6 FROM authenticated;
GRANT SELECT ON public.correos_salida_d6 TO authenticated;

-- Correos de los usuarios activos de una marca.
CREATE OR REPLACE FUNCTION public.d6_correos_de_marca(p_grupo_id UUID)
RETURNS TEXT[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT COALESCE(array_agg(DISTINCT p.email) FILTER (WHERE p.email IS NOT NULL), '{}')
  FROM public.user_grupos ug JOIN public.user_profiles p ON p.id = ug.user_id AND p.activo
  WHERE ug.grupo_id = p_grupo_id;
$$;

CREATE OR REPLACE FUNCTION public.d6_correos_de_rol(p_rol public.d6_role)
RETURNS TEXT[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT COALESCE(array_agg(DISTINCT p.email) FILTER (WHERE p.email IS NOT NULL), '{}')
  FROM public.user_role_assignments a JOIN public.user_profiles p ON p.id = a.user_id AND p.activo
  WHERE a.role = p_rol;
$$;

CREATE OR REPLACE FUNCTION public.d6_grupo_de_beneficiario(p_beneficiario_id UUID)
RETURNS UUID
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT r.grupo_id FROM public.grupo_beneficiario_rel r
  JOIN public.grupos_beneficiarios g ON g.id = r.grupo_id AND g.codigo <> 'GRP-GENERAL'
  WHERE r.beneficiario_id = p_beneficiario_id LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.d6_encolar_correo(
  p_para TEXT[], p_copia TEXT[], p_asunto TEXT, p_cuerpo TEXT, p_motivo TEXT,
  p_solicitud_alta_id UUID DEFAULT NULL, p_estado_cuenta_id UUID DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_para TEXT[] := ARRAY(SELECT DISTINCT x FROM unnest(p_para) x WHERE public.d6_correo_valido(x));
BEGIN
  IF cardinality(v_para) = 0 THEN RETURN; END IF;
  INSERT INTO public.correos_salida_d6 (para, copia, asunto, cuerpo, motivo, solicitud_alta_id, estado_cuenta_id)
  VALUES (v_para, ARRAY(SELECT DISTINCT x FROM unnest(COALESCE(p_copia, '{}')) x WHERE public.d6_correo_valido(x) AND x <> ALL (v_para)),
          left(p_asunto, 200), p_cuerpo, p_motivo, p_solicitud_alta_id, p_estado_cuenta_id);
END;
$$;

-- ============================================================================
-- 2. Que dispara un correo
-- ============================================================================
-- Decisiones de Suscripcion sobre un alta: al distribuidor y a la marca.
CREATE OR REPLACE FUNCTION public.d6_correo_por_revision()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_sol public.solicitudes_alta;
  v_marca TEXT;
  v_texto TEXT;
  v_asunto TEXT;
BEGIN
  IF NEW.estado_nuevo IS NOT DISTINCT FROM NEW.estado_anterior
     OR NEW.estado_nuevo NOT IN ('INFORMACION_COMPLEMENTARIA', 'APROBADA_TOTAL', 'APROBADA_PARCIAL', 'NO_ELEGIBLE', 'SUSPENDIDA', 'EMITIDA') THEN
    RETURN NEW;
  END IF;
  SELECT * INTO v_sol FROM public.solicitudes_alta WHERE id = NEW.solicitud_alta_id;
  SELECT g.nombre INTO v_marca FROM public.grupos_beneficiarios g WHERE g.id = public.d6_grupo_de_beneficiario(v_sol.beneficiario_id);

  v_asunto := 'Fianza de consignación ' || v_sol.numero_solicitud || ': ' || CASE NEW.estado_nuevo
    WHEN 'INFORMACION_COMPLEMENTARIA' THEN 'falta información'
    WHEN 'APROBADA_TOTAL' THEN 'aprobada'
    WHEN 'APROBADA_PARCIAL' THEN 'aprobada por un monto menor'
    WHEN 'NO_ELEGIBLE' THEN 'no aprobada'
    WHEN 'SUSPENDIDA' THEN 'en pausa'
    WHEN 'EMITIDA' THEN 'emitida' END;
  v_texto := 'Solicitud ' || v_sol.numero_solicitud || ' de ' || COALESCE(v_sol.cliente_nombre_tmp, 'el distribuidor')
    || COALESCE(' con ' || v_marca, '') || '.' || E'\n\n' || CASE NEW.estado_nuevo
    WHEN 'INFORMACION_COMPLEMENTARIA' THEN 'Fidelis necesita información adicional: ' || COALESCE(NEW.comentario, '')
         || E'\n\nRecibirá un enlace para subir lo que falta.'
    WHEN 'APROBADA_TOTAL' THEN 'Fidelis aprobó la fianza por Q' || to_char(v_sol.monto_aprobado, 'FM999,999,990.00')
         || '. El siguiente paso es firmar el contrato de consignación.'
    WHEN 'APROBADA_PARCIAL' THEN 'Fidelis aprobó la fianza por Q' || to_char(v_sol.monto_aprobado, 'FM999,999,990.00')
         || ', un monto menor al solicitado. ' || COALESCE(NEW.comentario, '')
    WHEN 'NO_ELEGIBLE' THEN 'Fidelis no aprobó la fianza. ' || COALESCE(NEW.comentario, '')
    WHEN 'SUSPENDIDA' THEN 'La solicitud quedó en pausa. ' || COALESCE(NEW.comentario, '')
    WHEN 'EMITIDA' THEN COALESCE(NEW.comentario, 'La fianza fue emitida') || '.' END
    || E'\n\nFidelis · 2285 7000';

  PERFORM public.d6_encolar_correo(
    ARRAY[v_sol.cliente_email_tmp] || public.d6_correos_de_marca(public.d6_grupo_de_beneficiario(v_sol.beneficiario_id)),
    '{}', v_asunto, v_texto, 'ALTA_' || NEW.estado_nuevo, v_sol.id, NULL);
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_correo_por_revision ON public.solicitud_revisiones;
CREATE TRIGGER trg_correo_por_revision AFTER INSERT ON public.solicitud_revisiones
  FOR EACH ROW EXECUTE FUNCTION public.d6_correo_por_revision();

-- Documento rechazado: a la marca, que acompaña al distribuidor.
CREATE OR REPLACE FUNCTION public.d6_correo_por_rechazo()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_sol public.solicitudes_alta;
  v_nombre TEXT;
BEGIN
  IF NEW.estado_revision <> 'RECHAZADO' OR OLD.estado_revision = 'RECHAZADO' OR NEW.solicitud_alta_id IS NULL
     OR COALESCE(NEW.comentario_revision, '') ~ '^(Reemplazado|Retirado)' THEN
    RETURN NEW;
  END IF;
  SELECT * INTO v_sol FROM public.solicitudes_alta WHERE id = NEW.solicitud_alta_id;
  SELECT r.nombre INTO v_nombre FROM public.ive_requisitos_d6 r
  WHERE r.categoria = NEW.categoria AND r.tipo_persona = v_sol.tipo_persona LIMIT 1;
  PERFORM public.d6_encolar_correo(
    public.d6_correos_de_marca(public.d6_grupo_de_beneficiario(v_sol.beneficiario_id)), '{}',
    'Fianza de consignación ' || v_sol.numero_solicitud || ': documento rechazado',
    'Fidelis rechazó el documento "' || COALESCE(v_nombre, NEW.categoria::text) || '" de '
      || COALESCE(v_sol.cliente_nombre_tmp, 'el distribuidor') || '.' || E'\n\nMotivo: '
      || COALESCE(NEW.comentario_revision, 'sin detalle') || E'\n\nFidelis · 2285 7000',
    'DOCUMENTO_RECHAZADO', v_sol.id, NULL);
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_correo_por_rechazo ON public.documentos;
CREATE TRIGGER trg_correo_por_rechazo AFTER UPDATE OF estado_revision ON public.documentos
  FOR EACH ROW EXECUTE FUNCTION public.d6_correo_por_rechazo();

-- Estado de cuenta enviado: a la marca, con copia a Cobros (procedimiento v01).
CREATE OR REPLACE FUNCTION public.d6_correo_por_estado_cuenta()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NEW.estado <> 'ENVIADO' OR OLD.estado <> 'BORRADOR' THEN
    RETURN NEW;
  END IF;
  PERFORM public.d6_encolar_correo(
    public.d6_correos_de_marca(NEW.grupo_id), public.d6_correos_de_rol('cobros'),
    'Estado de cuenta ' || NEW.numero || ' de Fidelis',
    'Estado de cuenta de fianzas de consignación de ' || to_char(NEW.periodo, 'MM/YYYY') || '.' || E'\n\n'
      || 'Total: Q' || to_char(NEW.total, 'FM999,999,990.00') || E'\n'
      || 'Vence: ' || to_char(NEW.fecha_vencimiento, 'DD/MM/YYYY') || E'\n\n'
      || 'El detalle por factura está en la aplicación, en Cuenta por cobrar.' || E'\n\nFidelis · 2285 7000',
    'ESTADO_CUENTA_ENVIADO', NULL, NEW.id);
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_correo_por_estado_cuenta ON public.estados_cuenta_d6;
CREATE TRIGGER trg_correo_por_estado_cuenta AFTER UPDATE OF estado ON public.estados_cuenta_d6
  FOR EACH ROW EXECUTE FUNCTION public.d6_correo_por_estado_cuenta();

-- Para la funcion enviar-correos (service_role): toma un lote y lo marca al terminar.
CREATE OR REPLACE FUNCTION public.d6_correos_por_enviar(p_limite INTEGER DEFAULT 20)
RETURNS SETOF public.correos_salida_d6
LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$
  UPDATE public.correos_salida_d6 c SET intentos = c.intentos + 1
  WHERE c.id IN (SELECT id FROM public.correos_salida_d6
                 WHERE estado = 'PENDIENTE' AND intentos < 5
                 ORDER BY created_at LIMIT LEAST(GREATEST(p_limite, 1), 100)
                 FOR UPDATE SKIP LOCKED)
  RETURNING c.*;
$$;

CREATE OR REPLACE FUNCTION public.d6_correo_resultado(p_id UUID, p_ok BOOLEAN, p_proveedor_id TEXT DEFAULT NULL, p_error TEXT DEFAULT NULL)
RETURNS VOID
LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$
  UPDATE public.correos_salida_d6 SET
    estado = CASE WHEN p_ok THEN 'ENVIADO' WHEN intentos >= 5 THEN 'FALLIDO' ELSE 'PENDIENTE' END,
    enviado_at = CASE WHEN p_ok THEN now() END,
    proveedor_id = p_proveedor_id, error = left(p_error, 500)
  WHERE id = p_id;
$$;

DO $$
DECLARE f TEXT;
BEGIN
  FOREACH f IN ARRAY ARRAY['d6_correos_de_marca(uuid)', 'd6_correos_de_rol(public.d6_role)', 'd6_grupo_de_beneficiario(uuid)',
    'd6_encolar_correo(text[],text[],text,text,text,uuid,uuid)', 'd6_correos_por_enviar(integer)',
    'd6_correo_resultado(uuid,boolean,text,text)'] LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION public.%s FROM PUBLIC, anon, authenticated', f);
  END LOOP;
END $$;
GRANT EXECUTE ON FUNCTION public.d6_correos_por_enviar(INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION public.d6_correo_resultado(UUID, BOOLEAN, TEXT, TEXT) TO service_role;

-- ============================================================================
-- 3. Seguimiento con el enlace ya usado
-- ============================================================================
-- El enlace usado ya no abre el formulario, pero le dice al distribuidor en que va su
-- solicitud. Solo el estado y el numero, sin datos personales.
CREATE OR REPLACE FUNCTION public.d6_estado_para_distribuidor(p_estado public.d6_solicitud_status)
RETURNS TEXT
LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
  SELECT CASE p_estado
    WHEN 'EXPEDIENTE_RECIBIDO' THEN 'RECIBIDA'
    WHEN 'EN_REVISION' THEN 'EN_REVISION'
    WHEN 'INFORMACION_COMPLEMENTARIA' THEN 'FALTA_INFORMACION'
    WHEN 'APROBADA_TOTAL' THEN 'APROBADA'
    WHEN 'APROBADA_PARCIAL' THEN 'APROBADA_PARCIAL'
    WHEN 'EMITIDA' THEN 'EMITIDA'
    WHEN 'NO_ELEGIBLE' THEN 'NO_APROBADA'
    WHEN 'SUSPENDIDA' THEN 'EN_PAUSA'
    ELSE 'EN_TRAMITE' END;
$$;

CREATE OR REPLACE FUNCTION public.portal_ive_seguimiento(p_token TEXT)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_inv public.ive_invitaciones;
  v_sol public.solicitudes_alta;
BEGIN
  v_inv := public.d6_invitacion_por_token(p_token);
  IF v_inv.id IS NULL THEN RETURN NULL; END IF;
  -- Un enlace sirve de seguimiento hasta 90 dias despues de vencer.
  IF v_inv.expires_at < now() - INTERVAL '90 days' THEN RETURN NULL; END IF;
  SELECT * INTO v_sol FROM public.solicitudes_alta WHERE id = v_inv.solicitud_alta_id;
  RETURN jsonb_build_object(
    'numero_solicitud', v_sol.numero_solicitud,
    'estado', public.d6_estado_para_distribuidor(v_sol.estado_operativo),
    'actualizado', v_sol.updated_at,
    'pendientes', COALESCE((SELECT jsonb_agg(nombre) FROM public.d6_documentos_faltantes(v_sol.id, true)), '[]'::jsonb),
    'comentario', CASE WHEN v_sol.estado_operativo IN ('INFORMACION_COMPLEMENTARIA', 'NO_ELEGIBLE', 'SUSPENDIDA')
                       THEN v_sol.resolucion_comentario END);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.portal_ive_seguimiento(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.portal_ive_seguimiento(TEXT) TO anon, authenticated;
