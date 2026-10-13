-- 043: FISO es la fuente de verdad (decision del 2026-10-13).
-- La app es el portal de los clientes, el archivo del expediente y el seguimiento de los casos.
-- Lo que se trabaja internamente en FISO no se vuelve a capturar aqui:
--   * Emision: Suscripcion emite en FISO y en la app solo vincula el numero de fianza.
--     Vigencia, prima, derechos, IVA y contrato llegan con la carga de Oracle.
--   * Pagos: Cobros los aplica en FISO (caja, lote, DTE). La app ya no registra pagos ni
--     concilia: el saldo de cada factura llega con la carga de facturas de FISO.
-- Se quedan en la app porque FISO no los registra (cruce del 2026-10-13):
--   * La decision de Suscripcion y la revision de documentos (USUARIO_AUTORIZACION vacio).
--   * El documento accesorio (0 registros D-6 en FIA_CONTRAGARANTIA).
--   * La entrega fisica: FECHA_ENTREGA de FISO coincide con la emision en 106 de 195 y es
--     anterior a ella en 77, asi que no refleja la entrega.
--   * Los reclamos de las marcas (0 D-6 en FIA_RECLAMOS).

-- ============================================================================
-- 1. Emision: vincular la fianza de FISO
-- ============================================================================
ALTER TABLE public.solicitudes_alta
  ADD COLUMN IF NOT EXISTS fianza_emitida_id UUID REFERENCES public.fianzas(id) ON DELETE RESTRICT;
CREATE UNIQUE INDEX IF NOT EXISTS uq_solicitud_fianza_emitida ON public.solicitudes_alta (fianza_emitida_id)
  WHERE fianza_emitida_id IS NOT NULL;

DROP FUNCTION IF EXISTS public.emitir_fianza_d6(UUID, BIGINT, DATE, DATE, TEXT, DATE, TEXT);
DROP TRIGGER IF EXISTS trg_anular_reemplazada ON public.fianzas;
DROP FUNCTION IF EXISTS public.d6_anular_reemplazada();
DROP TRIGGER IF EXISTS trg_01_fianzas_montos_fiso ON public.fianzas;
DROP FUNCTION IF EXISTS public.d6_montos_de_fiso();
DROP FUNCTION IF EXISTS public.d6_calcular_prima(NUMERIC, NUMERIC, DATE, DATE);
DROP FUNCTION IF EXISTS public.d6_tarifa_beneficiario(UUID);

-- Fecha en que Suscripcion aprobo, para buscar la fianza que se emitio despues en FISO.
CREATE OR REPLACE FUNCTION public.d6_fecha_aprobacion(p_solicitud_id UUID)
RETURNS DATE
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT max(r.created_at)::date FROM public.solicitud_revisiones r
  WHERE r.solicitud_alta_id = p_solicitud_id AND r.estado_nuevo IN ('APROBADA_TOTAL', 'APROBADA_PARCIAL');
$$;
REVOKE EXECUTE ON FUNCTION public.d6_fecha_aprobacion(UUID) FROM PUBLIC, anon, authenticated;

-- Fianzas de FISO que pueden corresponder a una solicitud aprobada: misma marca (beneficiario),
-- emitidas desde una semana antes de la aprobacion y sin otra solicitud vinculada.
CREATE OR REPLACE FUNCTION public.d6_candidatos_emision(p_solicitud_id UUID)
RETURNS TABLE(fianza BIGINT, endoso INTEGER, distribuidor TEXT, monto NUMERIC, fecha_emision DATE,
              vigencia_hasta DATE, mismo_monto BOOLEAN, mismo_distribuidor BOOLEAN)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_sol public.solicitudes_alta;
  v_desde DATE;
BEGIN
  IF NOT public.has_d6_role(ARRAY['admin', 'suscripcion']::public.d6_role[]) THEN
    RAISE EXCEPTION 'Solo Suscripcion vincula emisiones';
  END IF;
  SELECT * INTO v_sol FROM public.solicitudes_alta WHERE id = p_solicitud_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Solicitud no encontrada'; END IF;
  v_desde := COALESCE(public.d6_fecha_aprobacion(p_solicitud_id), v_sol.created_at::date) - 7;
  RETURN QUERY
  SELECT f.fianza, f.endoso, c.nombre, f.monto_afianzado, f.fecha_emision, f.vigencia_hasta,
         f.monto_afianzado = COALESCE(v_sol.monto_aprobado, v_sol.monto_solicitado),
         (f.cliente_id = v_sol.cliente_id
          OR public.d6_normalizar(c.nombre) = public.d6_normalizar(v_sol.cliente_nombre_tmp)
          OR (public.d6_normalizar_nit(c.nit) IS NOT NULL AND public.d6_normalizar_nit(c.nit) = public.d6_normalizar_nit(v_sol.cliente_nit_tmp)))
  FROM public.fianzas f
  JOIN public.clientes c ON c.id = f.cliente_id
  WHERE f.beneficiario_id = v_sol.beneficiario_id
    AND f.montos_fuente = 'FISO'
    AND f.fecha_emision >= v_desde
    AND f.operational_status NOT IN ('REEMPLAZADA_POR_ENDOSO', 'ANULADA', 'CANCELADA')
    AND NOT EXISTS (SELECT 1 FROM public.solicitudes_alta s WHERE s.fianza_emitida_id = f.id)
  ORDER BY 8 DESC, 7 DESC, f.fecha_emision DESC
  LIMIT 20;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.d6_candidatos_emision(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.d6_candidatos_emision(UUID) TO authenticated;

CREATE OR REPLACE FUNCTION public.d6_vincular_emision_fiso(p_solicitud_id UUID, p_fianza BIGINT)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_sol public.solicitudes_alta%ROWTYPE;
  v_f public.fianzas%ROWTYPE;
  v_app public.clientes%ROWTYPE;
  v_exposicion NUMERIC := 0;
  v_req BOOLEAN;
BEGIN
  IF NOT public.has_d6_role(ARRAY['admin', 'suscripcion']::public.d6_role[]) THEN
    RAISE EXCEPTION 'Solo Suscripcion vincula emisiones';
  END IF;
  SELECT * INTO v_sol FROM public.solicitudes_alta WHERE id = p_solicitud_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Solicitud no encontrada'; END IF;
  IF v_sol.estado_operativo NOT IN ('APROBADA_TOTAL', 'APROBADA_PARCIAL') THEN
    RAISE EXCEPTION 'Solo se vincula una solicitud aprobada';
  END IF;

  SELECT * INTO v_f FROM public.fianzas
  WHERE fianza = p_fianza AND montos_fuente = 'FISO' AND operational_status <> 'REEMPLAZADA_POR_ENDOSO'
  ORDER BY endoso DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'La fianza % todavia no aparece en la carga de FISO. Vinculela despues de la proxima carga.', p_fianza;
  END IF;
  IF v_f.beneficiario_id <> v_sol.beneficiario_id THEN
    RAISE EXCEPTION 'La fianza % es de otro beneficiario. Revise el numero.', p_fianza;
  END IF;
  IF EXISTS (SELECT 1 FROM public.solicitudes_alta WHERE fianza_emitida_id = v_f.id AND id <> p_solicitud_id) THEN
    RAISE EXCEPTION 'La fianza % ya esta vinculada a otra solicitud', p_fianza;
  END IF;

  -- El distribuidor que la app creo al pedir el alta pasa a ser el de FISO: se conservan
  -- el NIT, el correo y el celular que la marca escribio.
  IF v_sol.cliente_id IS DISTINCT FROM v_f.cliente_id THEN
    SELECT * INTO v_app FROM public.clientes WHERE id = v_sol.cliente_id;
    UPDATE public.clientes SET
      nit = COALESCE(nit, v_app.nit), email = COALESCE(email, v_app.email), telefono = COALESCE(telefono, v_app.telefono)
    WHERE id = v_f.cliente_id;
  END IF;

  SELECT COALESCE(sum(monto_afianzado), 0) INTO v_exposicion FROM public.fianzas
  WHERE cliente_id = v_f.cliente_id AND fianza <> v_f.fianza
    AND operational_status IN ('VIGENTE', 'POR_RENOVAR', 'PENDIENTE_ANULACION') AND vigencia_hasta >= CURRENT_DATE;
  v_req := v_f.monto_afianzado > 300000 OR v_f.monto_afianzado + v_exposicion > 300000 OR v_sol.requiere_documento_accesorio;

  -- La entrega fisica y el documento accesorio se controlan en la app (FISO no los registra).
  UPDATE public.fianzas SET
    requiere_accesorio = v_req,
    accesorio_estado = CASE WHEN v_req AND accesorio_estado = 'NO_APLICA' THEN 'PENDIENTE' ELSE accesorio_estado END,
    entrega_estado = 'PENDIENTE'
  WHERE id = v_f.id;

  UPDATE public.solicitudes_alta SET
    estado_operativo = 'EMITIDA', estado = 'APROBADA', fianza_emitida_id = v_f.id, cliente_id = v_f.cliente_id,
    contrato_numero = v_f.contrato_numero, contrato_fecha = v_f.contrato_fecha, contrato_valor = v_f.contrato_valor,
    vigencia_desde = v_f.vigencia_desde, vigencia_hasta = v_f.vigencia_hasta,
    emitida_en = now(), revisado_por = auth.uid(), requiere_documento_accesorio = v_req
  WHERE id = p_solicitud_id;
  INSERT INTO public.solicitud_revisiones (solicitud_alta_id, estado_anterior, estado_nuevo, comentario, monto_aprobado, creado_por)
  VALUES (p_solicitud_id, v_sol.estado_operativo, 'EMITIDA',
          'Fianza ' || v_f.fianza || ' emitida en FISO el ' || to_char(v_f.fecha_emision, 'DD/MM/YYYY'),
          v_f.monto_afianzado, auth.uid());
  RETURN v_f.id;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.d6_vincular_emision_fiso(UUID, BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.d6_vincular_emision_fiso(UUID, BIGINT) TO authenticated;

-- La vista de la marca encuentra la fianza emitida por el vinculo, no por coincidencias.
CREATE OR REPLACE VIEW public.v_solicitudes_alta_marca
WITH (security_barrier = true)
AS
SELECT sa.id, sa.numero_solicitud, sa.beneficiario_id,
  b.codigo_contacto AS beneficiario_codigo, b.nombre AS beneficiario_nombre,
  COALESCE(sa.cliente_nombre_tmp, c.nombre) AS afianzado_nombre,
  sa.cliente_email_tmp AS afianzado_email,
  sa.tipo_persona, sa.monto_solicitado, sa.monto_aprobado, sa.estado_operativo,
  CASE WHEN sa.estado_operativo IN ('INFORMACION_COMPLEMENTARIA', 'SUSPENDIDA', 'NO_ELEGIBLE') THEN sa.resolucion_comentario END AS motivo,
  sa.faltantes, sa.resolucion_marca_numero,
  sa.ive_completed_at IS NOT NULL AS ive_completado,
  inv.expires_at AS enlace_expira,
  f.fianza AS fianza_emitida,
  sa.emitida_en, sa.created_at, sa.updated_at,
  sa.cliente_telefono_tmp AS afianzado_telefono
FROM public.solicitudes_alta sa
JOIN public.beneficiarios b ON b.id = sa.beneficiario_id
LEFT JOIN public.clientes c ON c.id = sa.cliente_id
LEFT JOIN LATERAL (
  SELECT i.expires_at FROM public.ive_invitaciones i
  WHERE i.solicitud_alta_id = sa.id AND i.used_at IS NULL AND i.revoked_at IS NULL
  ORDER BY i.created_at DESC LIMIT 1) inv ON true
LEFT JOIN public.fianzas f ON f.id = sa.fianza_emitida_id
WHERE public.d6_puede_ver_beneficiario(sa.beneficiario_id);

-- ============================================================================
-- 2. Pagos: se aplican en FISO, la app solo muestra el saldo
-- ============================================================================
DROP FUNCTION IF EXISTS public.d6_registrar_pago(UUID, NUMERIC, DATE, TEXT, TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS public.d6_conciliar_pago(UUID, BOOLEAN, NUMERIC, TEXT, UUID);
DROP FUNCTION IF EXISTS public.d6_registrar_lote_fiso(UUID, TEXT, TEXT);
DROP FUNCTION IF EXISTS public.d6_actualizar_saldo_estado_cuenta(UUID);
-- Las tablas de pagos y conciliacion quedan como historial, sin escritura.
DROP POLICY IF EXISTS "propuestas: contabilidad administra" ON public.conciliacion_propuestas_d6;
DROP POLICY IF EXISTS "propuestas: personal ve" ON public.conciliacion_propuestas_d6;
CREATE POLICY "propuestas: personal ve" ON public.conciliacion_propuestas_d6 FOR SELECT TO authenticated
  USING ((SELECT public.d6_es_personal_aseguradora()));
DROP POLICY IF EXISTS "importaciones: contabilidad y comercializacion administran" ON public.importaciones_d6;
DROP POLICY IF EXISTS "importaciones: personal ve" ON public.importaciones_d6;
CREATE POLICY "importaciones: personal ve" ON public.importaciones_d6 FOR SELECT TO authenticated
  USING ((SELECT public.d6_es_personal_aseguradora()));

-- El estado de pago de cada estado de cuenta sale del saldo de sus facturas en FISO.
CREATE OR REPLACE VIEW public.v_estados_cuenta
WITH (security_invoker = true)
AS
SELECT
  ec.id, ec.numero, ec.grupo_id, g.nombre AS marca_nombre, ec.periodo, ec.fecha_vencimiento,
  ec.total,
  CASE WHEN ec.estado = 'BORRADOR' THEN 'BORRADOR'
       WHEN COALESCE(s.saldo, ec.total) <= 0 THEN 'PAGADO'
       WHEN COALESCE(s.saldo, ec.total) < ec.total THEN 'PARCIAL'
       ELSE 'ENVIADO' END AS estado,
  ec.enviado_at, ec.lote_fiso, ec.dte_numeros, ec.created_at,
  (SELECT count(*) FROM public.estado_cuenta_items_d6 i WHERE i.estado_cuenta_id = ec.id) AS partidas,
  GREATEST(ec.total - COALESCE(s.saldo, ec.total), 0) AS pagado,
  0::numeric AS en_verificacion,
  GREATEST(COALESCE(s.saldo, ec.total), 0) AS saldo,
  CASE WHEN ec.estado <> 'BORRADOR' AND COALESCE(s.saldo, ec.total) > 0 AND ec.fecha_vencimiento < CURRENT_DATE
       THEN CURRENT_DATE - ec.fecha_vencimiento ELSE 0 END AS dias_vencido,
  CASE
    WHEN ec.estado = 'BORRADOR' THEN 'BORRADOR'
    WHEN COALESCE(s.saldo, ec.total) <= 0 THEN 'PAGADO'
    WHEN ec.fecha_vencimiento >= CURRENT_DATE THEN 'AL_DIA'
    WHEN CURRENT_DATE - ec.fecha_vencimiento <= 30 THEN '1_30'
    WHEN CURRENT_DATE - ec.fecha_vencimiento <= 60 THEN '31_60'
    WHEN CURRENT_DATE - ec.fecha_vencimiento <= 90 THEN '61_90'
    ELSE '90_MAS'
  END AS antiguedad,
  0::numeric AS saldo_a_favor,
  s.actualizado AS saldo_fiso_al
FROM public.estados_cuenta_d6 ec
JOIN public.grupos_beneficiarios g ON g.id = ec.grupo_id
LEFT JOIN LATERAL (
  -- Saldo vivo de FISO. Una partida sin factura (estados de cuenta anteriores) cuenta completa.
  SELECT sum(CASE WHEN ff.correlativo_cobro IS NULL THEN i.monto
                  WHEN ff.fecha_anulacion IS NOT NULL THEN 0
                  ELSE ff.saldo END) AS saldo,
         max(ff.actualizada_at) AS actualizado
  FROM public.estado_cuenta_items_d6 i
  LEFT JOIN public.facturas_fiso_d6 ff ON ff.correlativo_cobro = i.factura_correlativo
  WHERE i.estado_cuenta_id = ec.id
) s ON true;
GRANT SELECT ON public.v_estados_cuenta TO authenticated;

-- ============================================================================
-- 3. Cuadre: la emision ya no se escribe a mano
-- ============================================================================
-- "Emitida sin FISO" ya no puede pasar. Su lugar lo toma una solicitud aprobada hace mas de
-- 30 dias sin fianza vinculada: o no se emitio en FISO o falta vincularla.
CREATE OR REPLACE FUNCTION public.d6_cuadre_fiso()
RETURNS TABLE(tipo TEXT, fianza BIGINT, fianza_id UUID, cliente_id UUID, afianzado TEXT, marca TEXT, detalle TEXT)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NOT public.has_d6_role(ARRAY['admin', 'suscripcion', 'cobros', 'coordinacion_comercial', 'contabilidad']::public.d6_role[]) THEN
    RAISE EXCEPTION 'No tiene permiso para ver el cuadre';
  END IF;
  RETURN QUERY
  WITH fiso AS (
    SELECT DISTINCT ON ((s.payload->>'FIANZA')::bigint)
      (s.payload->>'FIANZA')::bigint AS fianza, (s.payload->>'ENDOSO')::int AS endoso,
      s.payload->>'STATUS' AS status, NULLIF(s.payload->>'FECHA_CANCELACION', '')::date AS cancelacion,
      NULLIF(s.payload->>'FECHA_ANULACION', '')::date AS anulacion
    FROM public.oracle_d6_staging s
    WHERE s.fuente = 'CARTERA_D6'
      AND s.sync_run_id = (SELECT r.id FROM public.oracle_sync_runs_d6 r
                           WHERE r.fuente = 'CARTERA_D6' AND r.estado = 'COMPLETO' ORDER BY r.ejecutado_en DESC LIMIT 1)
    ORDER BY (s.payload->>'FIANZA')::bigint, (s.payload->>'ENDOSO')::int DESC
  ),
  app AS (
    SELECT DISTINCT ON (vf.fianza) vf.* FROM public.v_fianzas vf ORDER BY vf.fianza, vf.endoso DESC
  )
  SELECT 'POR_ANULAR_EN_FISO'::text, a.fianza, a.id, a.cliente_id, a.cliente_nombre, a.marca_nombre,
         'Baja aprobada con efecto al ' || to_char(a.fecha_cancelacion, 'DD/MM/YYYY') || '. En FISO sigue vigente.'
  FROM app a JOIN fiso f ON f.fianza = a.fianza
  WHERE a.estado IN ('EN_BAJA', 'CANCELADA') AND a.fecha_cancelacion <= CURRENT_DATE
    AND COALESCE(f.status, '') <> 'C' AND f.cancelacion IS NULL AND f.anulacion IS NULL
  UNION ALL
  SELECT 'CANCELADA_SIN_SOLICITUD', a.fianza, a.id, a.cliente_id, a.cliente_nombre, a.marca_nombre,
         'Cancelada en FISO el ' || to_char(COALESCE(f.cancelacion, f.anulacion), 'DD/MM/YYYY') || ' sin solicitud de baja registrada.'
  FROM app a JOIN fiso f ON f.fianza = a.fianza
  WHERE (f.status = 'C' OR f.cancelacion IS NOT NULL OR f.anulacion IS NOT NULL)
    AND COALESCE(f.cancelacion, f.anulacion) >= CURRENT_DATE - 365
    AND NOT EXISTS (SELECT 1 FROM public.solicitudes_baja b
                    JOIN public.fianzas fz ON fz.id = b.fianza_id WHERE fz.fianza = a.fianza)
  UNION ALL
  SELECT 'APROBADA_SIN_EMISION', NULL::bigint, NULL::uuid, sa.cliente_id, sa.cliente_nombre_tmp,
         (SELECT g.nombre FROM public.grupos_beneficiarios g WHERE g.id = public.d6_grupo_de_beneficiario(sa.beneficiario_id)),
         'Solicitud ' || sa.numero_solicitud || ' aprobada el ' || to_char(public.d6_fecha_aprobacion(sa.id), 'DD/MM/YYYY')
           || ' sin fianza de FISO vinculada.'
  FROM public.solicitudes_alta sa
  WHERE sa.estado_operativo IN ('APROBADA_TOTAL', 'APROBADA_PARCIAL')
    AND public.d6_fecha_aprobacion(sa.id) < CURRENT_DATE - 30
  UNION ALL
  SELECT 'CODIGO_DUPLICADO', NULL::bigint, NULL::uuid, c.id, c.nombre, NULL::text,
         'Mismo nombre que el codigo ' || string_agg(DISTINCT c2.codigo_contacto::text, ', ') || '. Codigo de este: ' || c.codigo_contacto
  FROM public.clientes c
  JOIN public.clientes c2 ON c2.id <> c.id AND public.d6_normalizar(c2.nombre) = public.d6_normalizar(c.nombre)
  WHERE EXISTS (SELECT 1 FROM public.fianzas f WHERE f.cliente_id = c.id)
    AND EXISTS (SELECT 1 FROM public.fianzas f WHERE f.cliente_id = c2.id)
  GROUP BY c.id, c.nombre, c.codigo_contacto
  UNION ALL
  SELECT 'ESTADO_CUENTA_DESCUADRADO', NULL::bigint, NULL::uuid, NULL::uuid, NULL::text, g.nombre,
         'Estado de cuenta ' || ec.numero || ': Q' || to_char(ec.total, 'FM999,999,990.00') || ' contra Q'
           || to_char(COALESCE(x.total, 0), 'FM999,999,990.00') || ' facturados en FISO.'
  FROM public.estados_cuenta_d6 ec
  JOIN public.grupos_beneficiarios g ON g.id = ec.grupo_id
  LEFT JOIN LATERAL (
    SELECT sum(ff.total) AS total FROM public.facturas_fiso_d6 ff
    JOIN public.grupo_beneficiario_rel r ON r.beneficiario_id = ff.beneficiario_id AND r.grupo_id = ec.grupo_id
    WHERE ff.fecha_emision >= ec.periodo AND ff.fecha_emision < (ec.periodo + INTERVAL '1 month')::date
      AND ff.fecha_anulacion IS NULL) x ON true
  WHERE ec.total IS DISTINCT FROM COALESCE(x.total, 0)
  UNION ALL
  SELECT 'FACTURA_SIN_MARCA', ff.fianza, ff.fianza_id, NULL::uuid, NULL::text, NULL::text,
         'Cobro ' || ff.correlativo_cobro || ' del ' || to_char(ff.fecha_emision, 'DD/MM/YYYY')
           || ' por Q' || to_char(ff.total, 'FM999,999,990.00') || '. Asigne el beneficiario a una marca.'
  FROM public.facturas_fiso_d6 ff
  WHERE ff.fecha_anulacion IS NULL AND ff.fecha_emision >= CURRENT_DATE - 365
    AND NOT EXISTS (SELECT 1 FROM public.grupo_beneficiario_rel r
                    JOIN public.grupos_beneficiarios g ON g.id = r.grupo_id AND g.codigo <> 'GRP-GENERAL'
                    WHERE r.beneficiario_id = ff.beneficiario_id);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.d6_cuadre_fiso() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.d6_cuadre_fiso() TO authenticated;
