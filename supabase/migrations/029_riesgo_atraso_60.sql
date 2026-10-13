-- Ajuste de la regla de mora del perfil: solo cuenta el atraso mayor a 60 dias.
-- Reglas del nivel de riesgo, a la vista y sin puntajes ocultos:
--   ALTO  : reclamo (Oracle o app, no improcedente ni desistido) o mora de mas de 90 dias.
--   MEDIO : IVE vencido o sin fecha, exposicion sobre Q300,000 sin contragarantia,
--           o saldo con mas de 60 dias de atraso.
-- Por que 60 dias: en D-6 las facturas de FISO salen a nombre del afianzado, pero en
-- ADMOSA las paga la marca el ultimo dia del mes siguiente. Hasta 60 dias de atraso es
-- el plazo normal de la marca, no un incumplimiento del distribuidor.
--   BAJO  : nada de lo anterior.
CREATE OR REPLACE VIEW public.v_perfil_afianzados
WITH (security_invoker = true)
AS
WITH pol AS (
  SELECT v.cliente_id,
         min(v.fecha_emision) AS desde,
         count(*) AS polizas_historicas,
         count(*) FILTER (WHERE v.estado IN ('VIGENTE', 'POR_RENOVAR', 'EN_BAJA')) AS polizas_activas,
         count(*) FILTER (WHERE v.estado = 'CANCELADA') AS canceladas,
         count(DISTINCT v.marca_id) FILTER (WHERE v.estado IN ('VIGENTE', 'POR_RENOVAR', 'EN_BAJA')) AS marcas_activas,
         string_agg(DISTINCT v.marca_nombre, ', ') FILTER (WHERE v.estado IN ('VIGENTE', 'POR_RENOVAR', 'EN_BAJA')) AS marcas,
         COALESCE(sum(v.monto_afianzado) FILTER (WHERE v.estado IN ('VIGENTE', 'POR_RENOVAR', 'EN_BAJA')), 0) AS exposicion,
         max(v.monto_original) AS monto_maximo,
         min(v.vigencia_hasta) FILTER (WHERE v.estado IN ('VIGENTE', 'POR_RENOVAR')) AS proximo_vencimiento
  FROM public.v_fianzas v
  GROUP BY v.cliente_id
),
rec AS (
  SELECT cliente_id,
         count(*) FILTER (WHERE estado NOT IN ('IMPROCEDENTE', 'DESISTIDO', 'CERRADO', 'RECUPERADO')) AS reclamos_abiertos,
         count(*) FILTER (WHERE estado NOT IN ('IMPROCEDENTE', 'DESISTIDO')) AS reclamos_app,
         COALESCE(sum(monto_pagado), 0) - COALESCE(sum(monto_recuperado), 0) AS por_recuperar
  FROM public.reclamos_d6 GROUP BY cliente_id
)
SELECT
  c.id AS cliente_id, c.codigo_contacto AS codigo, c.nombre, c.nit, c.tipo_persona,
  pol.desde, pol.polizas_historicas, pol.polizas_activas, pol.canceladas, pol.marcas_activas, pol.marcas,
  pol.exposicion, pol.monto_maximo, pol.proximo_vencimiento,
  o.ive_fecha_renovacion, o.ive_completo, o.ive_verificado,
  COALESCE(o.contragarantia_monto, 0) AS contragarantia_monto, o.contragarantia_tipos,
  o.cumulo, COALESCE(o.saldo, 0) AS saldo, COALESCE(o.saldo_atrasado, 0) AS saldo_atrasado,
  COALESCE(o.saldo_atrasado_90, 0) AS saldo_atrasado_90, COALESCE(o.max_dias_atraso, 0) AS max_dias_atraso,
  COALESCE(o.reclamos, 0) AS reclamos_oracle, COALESCE(o.avisos, 0) AS avisos_oracle,
  COALESCE(rec.reclamos_app, 0) AS reclamos_app, COALESCE(rec.reclamos_abiertos, 0) AS reclamos_abiertos,
  COALESCE(rec.por_recuperar, 0) AS por_recuperar,
  COALESCE(o.otras_fianzas_vigentes, 0) AS otras_fianzas_vigentes, COALESCE(o.otras_fianzas_monto, 0) AS otras_fianzas_monto,
  o.actualizado_at AS perfil_actualizado,
  (o.cliente_codigo IS NOT NULL AND (o.ive_fecha_renovacion IS NULL OR o.ive_fecha_renovacion < CURRENT_DATE)) AS alerta_ive,
  (pol.exposicion > 300000 AND COALESCE(o.contragarantia_monto, 0) = 0) AS alerta_accesorio,
  (COALESCE(o.max_dias_atraso, 0) > 60 AND COALESCE(o.saldo_atrasado, 0) > 0) AS alerta_atraso,
  (COALESCE(o.saldo_atrasado_90, 0) > 0) AS alerta_atraso_90,
  (COALESCE(o.reclamos, 0) + COALESCE(rec.reclamos_app, 0) > 0) AS alerta_reclamo,
  CASE
    WHEN COALESCE(o.reclamos, 0) + COALESCE(rec.reclamos_app, 0) > 0 OR COALESCE(o.saldo_atrasado_90, 0) > 0 THEN 'ALTO'
    WHEN (o.cliente_codigo IS NOT NULL AND (o.ive_fecha_renovacion IS NULL OR o.ive_fecha_renovacion < CURRENT_DATE))
      OR (pol.exposicion > 300000 AND COALESCE(o.contragarantia_monto, 0) = 0)
      OR (COALESCE(o.max_dias_atraso, 0) > 60 AND COALESCE(o.saldo_atrasado, 0) > 0) THEN 'MEDIO'
    ELSE 'BAJO'
  END AS nivel_riesgo
FROM public.clientes c
JOIN pol ON pol.cliente_id = c.id
LEFT JOIN public.perfil_afianzado_oracle o ON o.cliente_codigo = c.codigo_contacto
LEFT JOIN rec ON rec.cliente_id = c.id
WHERE public.d6_es_personal_aseguradora();
GRANT SELECT ON public.v_perfil_afianzados TO authenticated;
REVOKE ALL ON public.v_perfil_afianzados FROM anon;

