-- Ninguna solicitud pasa a revisión hasta tener los documentos aplicables.
CREATE OR REPLACE FUNCTION public.validar_documentos_ive_d6(p_solicitud_id UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_solicitud public.solicitudes_alta%ROWTYPE;
  v_tipo public.tipo_persona;
  v_requisito public.ive_requisitos_d6%ROWTYPE;
BEGIN
  SELECT * INTO v_solicitud FROM public.solicitudes_alta WHERE id = p_solicitud_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Solicitud no encontrada'; END IF;
  SELECT tipo_persona INTO v_tipo FROM public.clientes WHERE id = v_solicitud.cliente_id;
  FOR v_requisito IN
    SELECT * FROM public.ive_requisitos_d6
    WHERE version = 'FIDELIS-D6-2026.1' AND tipo_persona = v_tipo AND activo AND obligatorio
      AND (NOT requiere_umbral_exposicion OR v_solicitud.requiere_documento_accesorio)
  LOOP
    IF v_requisito.categoria IN ('IVE_ASS_01', 'IVE_ASS_02') AND v_solicitud.ive_data IS NOT NULL THEN
      CONTINUE;
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.documentos d
      WHERE d.solicitud_alta_id = p_solicitud_id
        AND d.categoria = v_requisito.categoria
        AND d.estado_revision <> 'RECHAZADO'
    ) THEN
      RAISE EXCEPTION 'Falta documento obligatorio: %', v_requisito.nombre;
    END IF;
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION public.transicionar_solicitud_alta(
  p_solicitud_id UUID,
  p_estado public.d6_solicitud_status,
  p_comentario TEXT DEFAULT NULL,
  p_monto_aprobado NUMERIC DEFAULT NULL,
  p_condiciones TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_actual public.d6_solicitud_status;
  v_permitida BOOLEAN := false;
BEGIN
  IF NOT public.has_d6_role(ARRAY['admin', 'suscripcion']::public.d6_role[]) THEN RAISE EXCEPTION 'Solo Suscripción puede resolver una solicitud'; END IF;
  SELECT estado_operativo INTO v_actual FROM public.solicitudes_alta WHERE id = p_solicitud_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Solicitud no encontrada'; END IF;
  IF p_estado = 'EMITIDA' THEN RAISE EXCEPTION 'La emisión debe confirmarse con emitir_fianza_d6'; END IF;
  v_permitida := CASE v_actual
    WHEN 'BORRADOR' THEN p_estado IN ('IVE_PENDIENTE', 'SUSPENDIDA')
    WHEN 'IVE_PENDIENTE' THEN p_estado IN ('EXPEDIENTE_RECIBIDO', 'SUSPENDIDA')
    WHEN 'EXPEDIENTE_RECIBIDO' THEN p_estado IN ('EN_REVISION', 'INFORMACION_COMPLEMENTARIA', 'SUSPENDIDA')
    WHEN 'EN_REVISION' THEN p_estado IN ('INFORMACION_COMPLEMENTARIA', 'APROBADA_TOTAL', 'APROBADA_PARCIAL', 'NO_ELEGIBLE', 'SUSPENDIDA')
    WHEN 'INFORMACION_COMPLEMENTARIA' THEN p_estado IN ('EN_REVISION', 'SUSPENDIDA')
    WHEN 'SUSPENDIDA' THEN p_estado IN ('IVE_PENDIENTE', 'EXPEDIENTE_RECIBIDO', 'EN_REVISION')
    ELSE false END;
  IF NOT v_permitida THEN RAISE EXCEPTION 'Transición no permitida: % -> %', v_actual, p_estado; END IF;
  IF p_estado = 'EN_REVISION' THEN PERFORM public.validar_documentos_ive_d6(p_solicitud_id); END IF;
  IF p_estado = 'APROBADA_PARCIAL' AND (p_monto_aprobado IS NULL OR p_monto_aprobado <= 0) THEN RAISE EXCEPTION 'Una aprobación parcial requiere monto aprobado'; END IF;
  IF p_estado IN ('APROBADA_TOTAL', 'APROBADA_PARCIAL') AND p_monto_aprobado IS NOT NULL AND p_monto_aprobado > (SELECT monto_solicitado FROM public.solicitudes_alta WHERE id = p_solicitud_id) THEN RAISE EXCEPTION 'El monto aprobado no puede superar el monto solicitado'; END IF;
  UPDATE public.solicitudes_alta SET estado_operativo = p_estado, monto_aprobado = COALESCE(p_monto_aprobado, monto_aprobado), condiciones_emision = COALESCE(p_condiciones, condiciones_emision), resolucion_comentario = p_comentario, revisado_por = auth.uid() WHERE id = p_solicitud_id;
  INSERT INTO public.solicitud_revisiones (solicitud_alta_id, estado_anterior, estado_nuevo, comentario, monto_aprobado, creado_por) VALUES (p_solicitud_id, v_actual, p_estado, p_comentario, p_monto_aprobado, auth.uid());
END;
$$;
