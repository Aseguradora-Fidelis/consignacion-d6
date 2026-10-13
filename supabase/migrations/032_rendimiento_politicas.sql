-- 032: rendimiento de la seguridad por marca.
-- Desde la 031 cada verificacion de permisos lee el encabezado de la marca en pantalla y la
-- tabla de roles. Llamada fila por fila, la cartera de una marca tardaba 3 segundos y el
-- tablero llegaba al limite de 8 segundos (error 57014). Envolver las funciones en un SELECT
-- hace que Postgres las evalue una sola vez por consulta. No cambia quien ve que.

DO $$
DECLARE
  p RECORD;
  v_using TEXT;
  v_check TEXT;
  v_sql TEXT;
BEGIN
  FOR p IN
    SELECT tablename, policyname, qual, with_check FROM pg_policies
    WHERE schemaname = 'public'
      AND (COALESCE(qual, '') || COALESCE(with_check, '')) ~ '(d6_es_personal_aseguradora|d6_puede_ver_beneficiario|d6_beneficiario_es_mio|has_d6_role)\('
      AND (COALESCE(qual, '') || COALESCE(with_check, '')) !~ 'SELECT\s+(public\.)?(d6_es_personal_aseguradora|has_d6_role|g\.beneficiario_id)'
  LOOP
    v_using := p.qual;
    v_check := p.with_check;
    FOR i IN 1..2 LOOP
      IF (CASE i WHEN 1 THEN v_using ELSE v_check END) IS NULL THEN CONTINUE; END IF;
      v_sql := CASE i WHEN 1 THEN v_using ELSE v_check END;
      v_sql := regexp_replace(v_sql, 'd6_es_personal_aseguradora\(\)', '(SELECT public.d6_es_personal_aseguradora())', 'g');
      v_sql := regexp_replace(v_sql, 'd6_puede_ver_beneficiario\(([^()]+)\)',
        '((SELECT public.d6_es_personal_aseguradora()) OR (\1) IN (SELECT g.beneficiario_id FROM public.get_user_beneficiario_ids() g))', 'g');
      v_sql := regexp_replace(v_sql, 'd6_beneficiario_es_mio\(([^()]+)\)',
        '((\1) IN (SELECT g.beneficiario_id FROM public.get_user_beneficiario_ids() g))', 'g');
      v_sql := regexp_replace(v_sql, 'has_d6_role\((ARRAY\[[^\]]*\])\)', '(SELECT public.has_d6_role(\1))', 'g');
      IF i = 1 THEN v_using := v_sql; ELSE v_check := v_sql; END IF;
    END LOOP;
    EXECUTE format('ALTER POLICY %I ON public.%I%s%s', p.policyname, p.tablename,
      CASE WHEN v_using IS NOT NULL THEN format(' USING (%s)', v_using) ELSE '' END,
      CASE WHEN v_check IS NOT NULL THEN format(' WITH CHECK (%s)', v_check) ELSE '' END);
  END LOOP;
END;
$$;

-- La vista de la cartera calculaba "es personal" en cada fila.
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
CROSS JOIN (SELECT public.d6_es_personal_aseguradora() AS es) p
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
