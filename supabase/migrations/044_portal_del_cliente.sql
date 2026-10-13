-- 044: la app es el portal del cliente (decision del 2026-10-13).
-- El equipo de Fidelis no trabaja en la app. El cliente llena su informacion, la comparte con
-- sus distribuidores y ve en que va cada caso. Fidelis recibe todo ordenado en un solo lugar
-- y solo lo consulta. Las decisiones viven en FISO y la app las refleja:
--   * Estados automaticos: el distribuidor llena, se recibe, faltan documentos (calculado con
--     la lista de requisitos) y se emite cuando la fianza aparece en FISO. La app reconoce sola
--     la fianza por el NIT del distribuidor, la marca y la fecha (175 de 175 distribuidores D-6
--     de 2026 tienen NIT en los contactos de FISO).
--   * Sin revision de documentos, decisiones, analisis ni vinculo manual.
--   * Sin documento accesorio ni entrega fisica.
--   * Estado de cuenta automatico: la marca ve sus facturas de FISO por mes con su saldo. El
--     correo lo manda FISO, no la app.
--   * Bajas y reclamos los inicia la marca. La baja aparece procesada cuando FISO cancela.

-- ============================================================================
-- 1. Lo que hacia el equipo en la app, fuera
-- ============================================================================
DROP FUNCTION IF EXISTS public.transicionar_solicitud_alta(UUID, public.d6_solicitud_status, TEXT, NUMERIC, TEXT, JSONB, TEXT);
DROP FUNCTION IF EXISTS public.d6_revisar_documento(UUID, TEXT, TEXT);
DROP FUNCTION IF EXISTS public.d6_guardar_analisis(UUID, JSONB);
DROP FUNCTION IF EXISTS public.d6_vincular_emision_fiso(UUID, BIGINT);
DROP FUNCTION IF EXISTS public.d6_candidatos_emision(UUID);
DROP FUNCTION IF EXISTS public.d6_registrar_accesorio(UUID, TEXT, TEXT);
DROP FUNCTION IF EXISTS public.d6_registrar_entrega(UUID, TEXT, TEXT);
DROP FUNCTION IF EXISTS public.d6_resolver_baja(UUID, BOOLEAN, TEXT);
DROP FUNCTION IF EXISTS public.d6_cerrar_baja(UUID);
DROP FUNCTION IF EXISTS public.d6_anulaciones_mes(DATE);
DROP FUNCTION IF EXISTS public.d6_marcar_anulaciones_enviadas(DATE);
DROP FUNCTION IF EXISTS public.d6_avanzar_reclamo(UUID, public.d6_reclamo_estado, TEXT, NUMERIC, BOOLEAN);
DROP FUNCTION IF EXISTS public.d6_generar_estado_cuenta(UUID, DATE);
DROP FUNCTION IF EXISTS public.d6_enviar_estado_cuenta(UUID);
DROP FUNCTION IF EXISTS public.d6_transiciones_alta();
DROP FUNCTION IF EXISTS public.d6_fecha_aprobacion(UUID);

-- Condiciones por marca y bitacora de llamadas: eran trabajo del equipo. Quedan solo de lectura.
DROP POLICY IF EXISTS "condiciones: suscripcion edita" ON public.condiciones_marca_d6;
DROP POLICY IF EXISTS "comunicaciones: personal registra" ON public.comunicaciones_d6;
DROP POLICY IF EXISTS "comunicaciones: admin borra" ON public.comunicaciones_d6;

-- Sin correos desde la app: los avisos de cobro los manda FISO y ya no hay decisiones aqui.
DROP TRIGGER IF EXISTS trg_correo_por_revision ON public.solicitud_revisiones;
DROP TRIGGER IF EXISTS trg_correo_por_rechazo ON public.documentos;
DROP TRIGGER IF EXISTS trg_correo_por_estado_cuenta ON public.estados_cuenta_d6;
DROP FUNCTION IF EXISTS public.d6_correo_por_revision();
DROP FUNCTION IF EXISTS public.d6_correo_por_rechazo();
DROP FUNCTION IF EXISTS public.d6_correo_por_estado_cuenta();
DROP FUNCTION IF EXISTS public.d6_correos_por_enviar(INTEGER);
DROP FUNCTION IF EXISTS public.d6_correo_resultado(UUID, BOOLEAN, TEXT, TEXT);
DROP FUNCTION IF EXISTS public.d6_encolar_correo(TEXT[], TEXT[], TEXT, TEXT, TEXT, UUID, UUID);
DROP FUNCTION IF EXISTS public.d6_correos_de_marca(UUID);
DROP FUNCTION IF EXISTS public.d6_correos_de_rol(public.d6_role);
DROP TABLE IF EXISTS public.correos_salida_d6;

-- Sin documento accesorio: ya no se pide como documento.
UPDATE public.ive_requisitos_d6 SET activo = false WHERE categoria = 'DOCUMENTO_ACCESORIO';

-- ============================================================================
-- 2. Estados automaticos
-- ============================================================================
-- La marca y el distribuidor corrigen hasta que FISO emite.
CREATE OR REPLACE FUNCTION public.d6_alta_editable(p_sol public.solicitudes_alta)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT p_sol.estado_operativo IN ('BORRADOR', 'IVE_PENDIENTE', 'EXPEDIENTE_RECIBIDO')
    AND (public.has_d6_role(ARRAY['admin']::public.d6_role[]) OR public.d6_beneficiario_es_mio(p_sol.beneficiario_id));
$$;
REVOKE EXECUTE ON FUNCTION public.d6_alta_editable(public.solicitudes_alta) FROM PUBLIC, anon, authenticated;

-- El enlace recibe documentos hasta que FISO emite.
CREATE OR REPLACE FUNCTION public.d6_estado_actualizable(p_estado public.d6_solicitud_status)
RETURNS BOOLEAN LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
  SELECT p_estado IN ('IVE_PENDIENTE', 'EXPEDIENTE_RECIBIDO');
$$;
CREATE OR REPLACE FUNCTION public.d6_solo_documentos(p_estado public.d6_solicitud_status)
RETURNS BOOLEAN LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
  SELECT p_estado = 'EXPEDIENTE_RECIBIDO';
$$;

-- Cada documento que llega recalcula lo que falta: no hay nadie que lo revise.
CREATE OR REPLACE FUNCTION public.d6_recalcular_faltantes()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NEW.solicitud_alta_id IS NOT NULL AND NOT NEW.carga_pendiente THEN
    UPDATE public.solicitudes_alta SET
      faltantes = COALESCE((SELECT jsonb_agg(categoria) FROM public.d6_documentos_faltantes(NEW.solicitud_alta_id, false)), '[]'::jsonb)
    WHERE id = NEW.solicitud_alta_id AND estado_operativo <> 'EMITIDA';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_recalcular_faltantes ON public.documentos;
CREATE TRIGGER trg_recalcular_faltantes AFTER INSERT OR UPDATE OF carga_pendiente, estado_revision ON public.documentos
  FOR EACH ROW EXECUTE FUNCTION public.d6_recalcular_faltantes();

-- Avisos dentro de la app: a la marca cuando llega el formulario o FISO emite, y al equipo
-- cuando llega un expediente (lo consulta, no lo trabaja aqui).
CREATE OR REPLACE FUNCTION public.d6_notificar_estado_alta()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_texto TEXT;
BEGIN
  IF OLD.estado_operativo IS NOT DISTINCT FROM NEW.estado_operativo THEN
    RETURN NEW;
  END IF;
  v_texto := CASE NEW.estado_operativo
    WHEN 'EXPEDIENTE_RECIBIDO' THEN 'El distribuidor envio su solicitud'
    WHEN 'EMITIDA' THEN 'Fianza emitida en FISO'
    ELSE NULL END;
  IF v_texto IS NULL THEN RETURN NEW; END IF;
  INSERT INTO public.notificaciones (user_id, titulo, mensaje, link)
  SELECT DISTINCT u.user_id, 'Solicitud ' || NEW.numero_solicitud,
         v_texto || ': ' || COALESCE(NEW.cliente_nombre_tmp, 'distribuidor'), '/altas/' || NEW.id
  FROM (
    SELECT NEW.creado_por AS user_id WHERE NEW.creado_por IS NOT NULL
    UNION
    SELECT ug.user_id FROM public.user_grupos ug
    JOIN public.grupo_beneficiario_rel r ON r.grupo_id = ug.grupo_id
    WHERE r.beneficiario_id = NEW.beneficiario_id
  ) u
  WHERE u.user_id IS DISTINCT FROM auth.uid();
  IF NEW.estado_operativo = 'EXPEDIENTE_RECIBIDO' THEN
    INSERT INTO public.notificaciones (user_id, titulo, mensaje, link)
    SELECT DISTINCT ura.user_id, 'Solicitud recibida', NEW.numero_solicitud || ': ' || COALESCE(NEW.cliente_nombre_tmp, ''),
           '/altas/' || NEW.id
    FROM public.user_role_assignments ura WHERE ura.role = 'suscripcion';
  END IF;
  RETURN NEW;
END;
$$;

-- ============================================================================
-- 3. La fianza emitida en FISO se reconoce sola
-- ============================================================================
-- Al cargar la cartera: el NIT de cada distribuidor llega de los contactos de FISO.
CREATE OR REPLACE FUNCTION public.d6_aplicar_nits_fiso(p_run_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_n INTEGER;
BEGIN
  WITH src AS (
    SELECT DISTINCT ON ((s.payload->>'COD_CONTACTO_CLIENTE')::int)
      (s.payload->>'COD_CONTACTO_CLIENTE')::int AS codigo, NULLIF(btrim(s.payload->>'NIT_CLIENTE'), '') AS nit
    FROM public.oracle_d6_staging s
    WHERE s.sync_run_id = p_run_id AND s.fuente = 'CARTERA_D6' AND NULLIF(btrim(s.payload->>'NIT_CLIENTE'), '') IS NOT NULL
  ), up AS (
    UPDATE public.clientes c SET nit = src.nit FROM src
    WHERE c.codigo_contacto = src.codigo AND c.nit IS DISTINCT FROM src.nit
    RETURNING 1
  )
  SELECT count(*) INTO v_n FROM up;
  RETURN v_n;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.d6_aplicar_nits_fiso(UUID) FROM PUBLIC, anon, authenticated;

-- NIT que el distribuidor o la marca escribieron en la solicitud.
CREATE OR REPLACE FUNCTION public.d6_nit_de_solicitud(p_sol public.solicitudes_alta)
RETURNS TEXT
LANGUAGE sql STABLE SET search_path = public
AS $$
  SELECT public.d6_normalizar_nit(COALESCE(
    NULLIF(p_sol.ive_data->>'nit', ''), NULLIF(p_sol.ive_data->>'nitEntidad', ''),
    NULLIF(p_sol.ive_borrador->>'nit', ''), NULLIF(p_sol.ive_borrador->>'nitEntidad', ''),
    p_sol.cliente_nit_tmp));
$$;
REVOKE EXECUTE ON FUNCTION public.d6_nit_de_solicitud(public.solicitudes_alta) FROM PUBLIC, anon, authenticated;

-- Una solicitud queda emitida cuando FISO trae una fianza con el mismo NIT del distribuidor,
-- la misma marca, emitida desde que se pidio el alta y sin otra solicitud vinculada.
-- Si hay varias, la de monto mas cercano al solicitado y luego la mas antigua.
CREATE OR REPLACE FUNCTION public.d6_vincular_emisiones_fiso()
RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_sol public.solicitudes_alta%ROWTYPE;
  v_f public.fianzas%ROWTYPE;
  v_app public.clientes%ROWTYPE;
  v_nit TEXT;
  v_n INTEGER := 0;
BEGIN
  FOR v_sol IN
    SELECT * FROM public.solicitudes_alta
    WHERE estado_operativo IN ('BORRADOR', 'IVE_PENDIENTE', 'EXPEDIENTE_RECIBIDO') AND fianza_emitida_id IS NULL
    ORDER BY created_at
    FOR UPDATE
  LOOP
    v_nit := public.d6_nit_de_solicitud(v_sol);
    CONTINUE WHEN v_nit IS NULL;
    SELECT f.* INTO v_f
    FROM public.fianzas f
    JOIN public.clientes c ON c.id = f.cliente_id
    WHERE f.beneficiario_id = v_sol.beneficiario_id
      AND public.d6_normalizar_nit(c.nit) = v_nit
      AND f.fecha_emision >= v_sol.created_at::date
      AND f.operational_status NOT IN ('REEMPLAZADA_POR_ENDOSO', 'ANULADA', 'CANCELADA')
      AND NOT EXISTS (SELECT 1 FROM public.solicitudes_alta s WHERE s.fianza_emitida_id = f.id)
    ORDER BY abs(f.monto_afianzado - v_sol.monto_solicitado), f.fecha_emision, f.endoso DESC
    LIMIT 1;
    CONTINUE WHEN NOT FOUND;

    -- Lo que la marca escribio del distribuidor se conserva en el contacto de FISO.
    IF v_sol.cliente_id IS DISTINCT FROM v_f.cliente_id AND v_sol.cliente_id IS NOT NULL THEN
      SELECT * INTO v_app FROM public.clientes WHERE id = v_sol.cliente_id;
      UPDATE public.clientes SET email = COALESCE(email, v_app.email), telefono = COALESCE(telefono, v_app.telefono)
      WHERE id = v_f.cliente_id;
    END IF;

    UPDATE public.solicitudes_alta SET
      estado_operativo = 'EMITIDA', estado = 'APROBADA', fianza_emitida_id = v_f.id, cliente_id = v_f.cliente_id,
      monto_aprobado = v_f.monto_afianzado, contrato_numero = v_f.contrato_numero, contrato_fecha = v_f.contrato_fecha,
      contrato_valor = v_f.contrato_valor, vigencia_desde = v_f.vigencia_desde, vigencia_hasta = v_f.vigencia_hasta,
      emitida_en = now()
    WHERE id = v_sol.id;
    INSERT INTO public.solicitud_revisiones (solicitud_alta_id, estado_anterior, estado_nuevo, comentario, monto_aprobado, creado_por)
    VALUES (v_sol.id, v_sol.estado_operativo, 'EMITIDA',
            'Fianza ' || v_f.fianza || ' emitida en FISO el ' || to_char(v_f.fecha_emision, 'DD/MM/YYYY'), v_f.monto_afianzado, NULL);
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.d6_vincular_emisiones_fiso() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.d6_vincular_emisiones_fiso() TO service_role;

-- La carga de cartera aplica la cartera, los NIT y reconoce las emisiones en un solo paso.
CREATE OR REPLACE FUNCTION public.d6_aplicar_cartera_fiso(p_run_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_resumen JSONB;
BEGIN
  v_resumen := public.d6_aplicar_cartera_oracle(p_run_id);
  v_resumen := v_resumen || jsonb_build_object(
    'nits_actualizados', public.d6_aplicar_nits_fiso(p_run_id),
    'solicitudes_emitidas', public.d6_vincular_emisiones_fiso());
  UPDATE public.oracle_sync_runs_d6 SET resumen = v_resumen WHERE id = p_run_id;
  RETURN v_resumen;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.d6_aplicar_cartera_fiso(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.d6_aplicar_cartera_fiso(UUID) TO service_role;

-- ============================================================================
-- 4. Cuenta de la marca: sus facturas de FISO por mes
-- ============================================================================
-- Vencimiento segun la regla de la marca: contado vence al facturar, el resto el ultimo dia
-- del mes siguiente (procedimiento v01). La marca no lee las reglas: va en una funcion definer.
CREATE OR REPLACE FUNCTION public.d6_vence_periodo(p_grupo_id UUID, p_periodo DATE)
RETURNS DATE
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT CASE WHEN r.vencimiento = 'ANTES_DE_ENTREGA' THEN (p_periodo + INTERVAL '1 month - 1 day')::date
              ELSE (p_periodo + INTERVAL '2 months - 1 day')::date END
  FROM public.grupos_beneficiarios g
  LEFT JOIN public.reglas_cobro_d6 r ON r.codigo_marca = COALESCE(g.codigo_regla_cobro, 'GENERAL') AND r.activa
  WHERE g.id = p_grupo_id;
$$;
REVOKE EXECUTE ON FUNCTION public.d6_vence_periodo(UUID, DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.d6_vence_periodo(UUID, DATE) TO authenticated;

CREATE OR REPLACE VIEW public.v_cuenta_marca
WITH (security_invoker = true)
AS
SELECT g.id AS marca_id, g.nombre AS marca_nombre,
  date_trunc('month', ff.fecha_emision)::date AS periodo,
  count(*) AS facturas,
  sum(ff.total) AS total,
  sum(ff.total - ff.saldo) AS pagado,
  sum(ff.saldo) AS saldo,
  public.d6_vence_periodo(g.id, date_trunc('month', ff.fecha_emision)::date) AS vence,
  CASE WHEN sum(ff.saldo) <= 0 THEN 'PAGADO'
       WHEN sum(ff.saldo) < sum(ff.total) THEN 'PARCIAL'
       WHEN public.d6_vence_periodo(g.id, date_trunc('month', ff.fecha_emision)::date) < CURRENT_DATE THEN 'VENCIDO'
       ELSE 'PENDIENTE' END AS estado,
  GREATEST(CURRENT_DATE - public.d6_vence_periodo(g.id, date_trunc('month', ff.fecha_emision)::date), 0)
    * (sum(ff.saldo) > 0)::int AS dias_vencido,
  date_trunc('month', ff.fecha_emision)::date = date_trunc('month', CURRENT_DATE)::date AS mes_en_curso,
  max(ff.actualizada_at) AS saldo_fiso_al
FROM public.facturas_fiso_d6 ff
JOIN public.grupo_beneficiario_rel r ON r.beneficiario_id = ff.beneficiario_id
JOIN public.grupos_beneficiarios g ON g.id = r.grupo_id AND g.codigo <> 'GRP-GENERAL'
WHERE ff.fecha_anulacion IS NULL
GROUP BY g.id, g.nombre, date_trunc('month', ff.fecha_emision);
GRANT SELECT ON public.v_cuenta_marca TO authenticated;
REVOKE ALL ON public.v_cuenta_marca FROM anon;

-- ============================================================================
-- 5. Cuadre: solo de consulta, con lo que sigue teniendo sentido
-- ============================================================================
CREATE OR REPLACE FUNCTION public.d6_cuadre_fiso()
RETURNS TABLE(tipo TEXT, fianza BIGINT, fianza_id UUID, cliente_id UUID, afianzado TEXT, marca TEXT, detalle TEXT)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NOT public.d6_es_personal_aseguradora() THEN
    RAISE EXCEPTION 'No tiene permiso para ver el cuadre';
  END IF;
  RETURN QUERY
  WITH app AS (
    SELECT DISTINCT ON (vf.fianza) vf.* FROM public.v_fianzas vf ORDER BY vf.fianza, vf.endoso DESC
  )
  -- La marca pidio la baja y su fecha ya paso, pero FISO todavia no la cancela.
  SELECT 'BAJA_PENDIENTE_EN_FISO'::text, a.fianza, a.id, a.cliente_id, a.cliente_nombre, a.marca_nombre,
         'Baja pedida por la marca con efecto al ' || to_char(b.fecha_efectiva, 'DD/MM/YYYY') || '. En FISO sigue vigente.'
  FROM app a
  JOIN public.solicitudes_baja b ON b.fianza_id = a.id
  WHERE b.fecha_efectiva <= CURRENT_DATE AND a.estado NOT IN ('CANCELADA', 'ANULADA')
  UNION ALL
  -- Una solicitud recibida hace mas de 30 dias sin fianza en FISO.
  SELECT 'RECIBIDA_SIN_EMISION', NULL::bigint, NULL::uuid, sa.cliente_id, sa.cliente_nombre_tmp,
         (SELECT g.nombre FROM public.grupos_beneficiarios g WHERE g.id = public.d6_grupo_de_beneficiario(sa.beneficiario_id)),
         'Solicitud ' || sa.numero_solicitud || ' recibida el ' || to_char(sa.ive_completed_at, 'DD/MM/YYYY')
           || ' sin fianza emitida en FISO.'
  FROM public.solicitudes_alta sa
  WHERE sa.estado_operativo = 'EXPEDIENTE_RECIBIDO' AND sa.ive_completed_at < now() - INTERVAL '30 days'
  UNION ALL
  SELECT 'CODIGO_DUPLICADO', NULL::bigint, NULL::uuid, c.id, c.nombre, NULL::text,
         'Mismo nombre que el codigo ' || string_agg(DISTINCT c2.codigo_contacto::text, ', ') || '. Codigo de este: ' || c.codigo_contacto
  FROM public.clientes c
  JOIN public.clientes c2 ON c2.id <> c.id AND public.d6_normalizar(c2.nombre) = public.d6_normalizar(c.nombre)
  WHERE EXISTS (SELECT 1 FROM public.fianzas f WHERE f.cliente_id = c.id)
    AND EXISTS (SELECT 1 FROM public.fianzas f WHERE f.cliente_id = c2.id)
  GROUP BY c.id, c.nombre, c.codigo_contacto
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
