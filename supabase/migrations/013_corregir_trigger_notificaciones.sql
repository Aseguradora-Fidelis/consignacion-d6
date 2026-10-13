-- Solicitudes de alta y baja tienen columnas de autor distintas. El trigger debe
-- ser genérico para no bloquear cambios de estado ni la emisión de una póliza.

CREATE OR REPLACE FUNCTION public.notify_on_solicitud_status_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_user_id UUID;
  v_msg TEXT;
BEGIN
  IF OLD.estado IS DISTINCT FROM NEW.estado THEN
    v_user_id := NULLIF(
      COALESCE(to_jsonb(NEW)->>'creado_por', to_jsonb(NEW)->>'solicitado_por'),
      ''
    )::UUID;
    v_msg := 'La solicitud ' || NEW.numero_solicitud || ' cambió de estado a: ' || NEW.estado;

    IF v_user_id IS NOT NULL THEN
      INSERT INTO public.notificaciones (user_id, titulo, mensaje, link)
      VALUES (v_user_id, 'Actualización de Solicitud', v_msg, '/solicitudes/' || NEW.id);
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
