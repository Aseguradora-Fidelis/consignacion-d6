-- En Supabase, pgcrypto se instala en el esquema extensions. Las RPC IVE deben
-- referenciarlo explícitamente para que el token temporal funcione en local y cloud.

CREATE OR REPLACE FUNCTION public.crear_invitacion_ive(p_solicitud_id UUID, p_destinatario_email TEXT, p_horas INTEGER DEFAULT 72)
RETURNS TABLE(token TEXT, expires_at TIMESTAMPTZ)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_token TEXT := encode(extensions.gen_random_bytes(32), 'hex');
  v_expires_at TIMESTAMPTZ := now() + make_interval(hours => GREATEST(p_horas, 1));
BEGIN
  IF NOT public.has_d6_role(ARRAY['admin', 'comercial', 'suscripcion']::public.d6_role[]) THEN
    RAISE EXCEPTION 'No tiene permiso para crear invitaciones IVE';
  END IF;
  UPDATE public.ive_invitaciones SET revoked_at = now()
    WHERE solicitud_alta_id = p_solicitud_id AND used_at IS NULL AND revoked_at IS NULL;
  INSERT INTO public.ive_invitaciones (solicitud_alta_id, token_hash, destinatario_email, expires_at, created_by)
    VALUES (p_solicitud_id, encode(extensions.digest(v_token, 'sha256'), 'hex'), p_destinatario_email, v_expires_at, auth.uid());
  UPDATE public.solicitudes_alta SET estado_operativo = 'IVE_PENDIENTE' WHERE id = p_solicitud_id;
  RETURN QUERY SELECT v_token, v_expires_at;
END;
$$;

CREATE OR REPLACE FUNCTION public.completar_ive_invitacion(p_token TEXT, p_datos JSONB)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_invitacion public.ive_invitaciones%ROWTYPE;
BEGIN
  SELECT * INTO v_invitacion FROM public.ive_invitaciones
  WHERE token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
    AND used_at IS NULL AND revoked_at IS NULL AND expires_at > now()
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'La invitación no es válida, expiró o fue revocada'; END IF;
  UPDATE public.ive_invitaciones SET used_at = now() WHERE id = v_invitacion.id;
  UPDATE public.solicitudes_alta
    SET ive_data = p_datos, estado_operativo = 'EXPEDIENTE_RECIBIDO'
    WHERE id = v_invitacion.solicitud_alta_id;
  RETURN v_invitacion.solicitud_alta_id;
END;
$$;
