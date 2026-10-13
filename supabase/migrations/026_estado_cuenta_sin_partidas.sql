-- Un mes sin emisiones para una marca no deja un estado de cuenta vacio en borrador.
CREATE OR REPLACE FUNCTION public.d6_generar_estado_cuenta(p_grupo_id UUID, p_periodo DATE)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_periodo DATE := date_trunc('month', p_periodo)::date;
  v_grupo public.grupos_beneficiarios%ROWTYPE;
  v_regla public.reglas_cobro_d6%ROWTYPE;
  v_id UUID;
  v_estado TEXT;
  v_vence DATE;
  v_total NUMERIC(15,2);
BEGIN
  IF NOT public.has_d6_role(ARRAY['admin', 'coordinacion_comercial', 'cobros']::public.d6_role[]) THEN
    RAISE EXCEPTION 'Solo Comercializacion o Cobros generan estados de cuenta';
  END IF;
  SELECT * INTO v_grupo FROM public.grupos_beneficiarios WHERE id = p_grupo_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Marca no encontrada'; END IF;
  IF v_periodo >= date_trunc('month', CURRENT_DATE)::date THEN
    RAISE EXCEPTION 'Solo se generan meses cerrados. El mes en curso se cobra el mes siguiente.';
  END IF;

  SELECT * INTO v_regla FROM public.reglas_cobro_d6
  WHERE codigo_marca = COALESCE(v_grupo.codigo_regla_cobro, 'GENERAL') AND activa;
  IF NOT FOUND THEN
    SELECT * INTO v_regla FROM public.reglas_cobro_d6 WHERE codigo_marca = 'GENERAL';
  END IF;
  v_vence := CASE v_regla.vencimiento
    WHEN 'ANTES_DE_ENTREGA' THEN CURRENT_DATE
    ELSE (v_periodo + INTERVAL '2 months - 1 day')::date
  END;

  SELECT id, estado INTO v_id, v_estado FROM public.estados_cuenta_d6 WHERE grupo_id = p_grupo_id AND periodo = v_periodo;
  IF v_id IS NOT NULL AND v_estado <> 'BORRADOR' THEN
    RAISE EXCEPTION 'El estado de cuenta de ese mes ya fue enviado y no se puede regenerar';
  END IF;
  IF v_id IS NULL THEN
    INSERT INTO public.estados_cuenta_d6 (grupo_id, periodo, fecha_vencimiento, total, estado, numero, generado_por)
    VALUES (p_grupo_id, v_periodo, v_vence, 0, 'BORRADOR',
            'EC-' || to_char(v_periodo, 'YYYYMM') || '-' || upper(substr(replace(v_grupo.codigo, 'GRP-', ''), 1, 12)), auth.uid())
    RETURNING id INTO v_id;
  ELSE
    DELETE FROM public.estado_cuenta_items_d6 WHERE estado_cuenta_id = v_id;
    UPDATE public.estados_cuenta_d6 SET fecha_vencimiento = v_vence, generado_por = auth.uid() WHERE id = v_id;
  END IF;

  INSERT INTO public.estado_cuenta_items_d6 (estado_cuenta_id, fianza_id, concepto, prima, derechos, iva, otros, monto)
  SELECT v_id, f.id,
         CASE WHEN f.endoso = 0 THEN 'Emision' ELSE 'Endoso ' || f.endoso END,
         f.prima, f.derechos, COALESCE(f.iva, 0), COALESCE(f.otros, 0),
         f.prima + f.derechos + COALESCE(f.iva, 0) + COALESCE(f.otros, 0)
  FROM public.fianzas f
  JOIN public.grupo_beneficiario_rel r ON r.beneficiario_id = f.beneficiario_id AND r.grupo_id = p_grupo_id
  WHERE f.fecha_emision >= v_periodo AND f.fecha_emision < (v_periodo + INTERVAL '1 month')
    AND COALESCE(f.operational_status::text, '') <> 'ANULADA'
    AND f.prima + f.derechos + COALESCE(f.iva, 0) + COALESCE(f.otros, 0) > 0;

  SELECT COALESCE(SUM(monto), 0) INTO v_total FROM public.estado_cuenta_items_d6 WHERE estado_cuenta_id = v_id;
  -- Un mes sin emisiones no genera estado de cuenta: solo seria ruido en la bandeja.
  IF v_total = 0 THEN
    DELETE FROM public.estados_cuenta_d6 WHERE id = v_id;
    RETURN NULL;
  END IF;
  UPDATE public.estados_cuenta_d6 SET total = v_total WHERE id = v_id;
  RETURN v_id;
END;
$$;


-- Textos de reglas de cobro con ortografia correcta (se muestran en Administracion).
UPDATE public.reglas_cobro_d6 SET nombre = 'Cuotas, vence el último día del mes siguiente' WHERE codigo_marca = 'ADMOSA';
UPDATE public.reglas_cobro_d6 SET nombre = 'Contado, la póliza se entrega pagada' WHERE codigo_marca = 'GRUPO_UMA';
UPDATE public.reglas_cobro_d6 SET nombre = 'General, vence el último día del mes siguiente' WHERE codigo_marca = 'GENERAL';
