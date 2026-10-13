-- Resumenes para los tableros. Corren con los permisos de quien consulta
-- (SECURITY INVOKER), asi que una marca solo suma su propia cartera.
-- Evitan bajar miles de filas al navegador para contar.

CREATE OR REPLACE FUNCTION public.d6_resumen_cartera(p_marca_id UUID DEFAULT NULL)
RETURNS TABLE(estado TEXT, polizas BIGINT, monto NUMERIC, afianzados BIGINT)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public
AS $$
  SELECT v.estado, count(*), COALESCE(sum(v.monto_afianzado), 0), count(DISTINCT v.cliente_id)
  FROM public.v_fianzas v
  WHERE p_marca_id IS NULL OR v.marca_id = p_marca_id
  GROUP BY v.estado;
$$;

CREATE OR REPLACE FUNCTION public.d6_cartera_por_marca()
RETURNS TABLE(marca_id UUID, marca_nombre TEXT, polizas BIGINT, monto NUMERIC, por_renovar BIGINT)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public
AS $$
  SELECT v.marca_id, COALESCE(v.marca_nombre, 'Sin marca'),
         count(*) FILTER (WHERE v.estado IN ('VIGENTE', 'POR_RENOVAR', 'EN_BAJA')),
         COALESCE(sum(v.monto_afianzado) FILTER (WHERE v.estado IN ('VIGENTE', 'POR_RENOVAR', 'EN_BAJA')), 0),
         count(*) FILTER (WHERE v.estado = 'POR_RENOVAR')
  FROM public.v_fianzas v
  GROUP BY v.marca_id, v.marca_nombre
  ORDER BY 4 DESC;
$$;

CREATE OR REPLACE FUNCTION public.d6_resumen_cobros(p_marca_id UUID DEFAULT NULL)
RETURNS TABLE(antiguedad TEXT, estados BIGINT, saldo NUMERIC, en_verificacion NUMERIC)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public
AS $$
  SELECT e.antiguedad, count(*), COALESCE(sum(e.saldo), 0), COALESCE(sum(e.en_verificacion), 0)
  FROM public.v_estados_cuenta e
  WHERE e.estado <> 'BORRADOR' AND (p_marca_id IS NULL OR e.grupo_id = p_marca_id)
  GROUP BY e.antiguedad;
$$;

REVOKE EXECUTE ON FUNCTION public.d6_resumen_cartera(UUID) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.d6_cartera_por_marca() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.d6_resumen_cobros(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.d6_resumen_cartera(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.d6_cartera_por_marca() TO authenticated;
GRANT EXECUTE ON FUNCTION public.d6_resumen_cobros(UUID) TO authenticated;
