-- Migracion 018: la marca pide el alta de su propia cartera.
-- Revisa la regla de la 010 ("comercial crea altas; las marcas solo consultan").
-- Decision del 2026-09-17: una marca (UMA, ADMOSA, ...) puede PEDIR un alta para un
-- afianzado propio. Sigue sin poder aprobarla, emitirla, cargar documentos al
-- expediente ni ver nada de otra marca. El expediente nace en IVE_PENDIENTE y la
-- resolucion continua en manos de Suscripcion.
--
-- La creacion pasa por una sola RPC SECURITY DEFINER en lugar de abrir politicas de
-- INSERT sobre clientes y solicitudes_alta: asi la barrera de tenant vive en un unico
-- lugar auditable y la marca nunca escribe directo en las tablas.

CREATE OR REPLACE FUNCTION public.d6_marca_crear_solicitud_alta(
  p_beneficiario_codigo INTEGER,
  p_cliente_nombre TEXT,
  p_cliente_email TEXT,
  p_monto NUMERIC,
  p_cliente_nit TEXT DEFAULT NULL,
  p_cliente_telefono TEXT DEFAULT NULL,
  p_tipo_persona public.tipo_persona DEFAULT 'INDIVIDUAL',
  p_vigencia_desde DATE DEFAULT NULL,
  p_vigencia_hasta DATE DEFAULT NULL,
  p_contrato_numero TEXT DEFAULT NULL,
  p_horas_ive INTEGER DEFAULT 72
)
RETURNS TABLE(solicitud_id UUID, numero_solicitud TEXT, ive_token TEXT, ive_expira TIMESTAMPTZ)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_beneficiario public.beneficiarios%ROWTYPE;
  v_cliente public.clientes%ROWTYPE;
  v_solicitud_id UUID;
  v_numero TEXT;
  v_token TEXT := encode(extensions.gen_random_bytes(32), 'hex');
  v_expira TIMESTAMPTZ := now() + make_interval(hours => GREATEST(COALESCE(p_horas_ive, 72), 1));
  v_exposicion NUMERIC(15,2) := 0;
  v_desde DATE := COALESCE(p_vigencia_desde, CURRENT_DATE);
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Debe iniciar sesion para solicitar un alta';
  END IF;
  IF p_cliente_nombre IS NULL OR btrim(p_cliente_nombre) = '' THEN
    RAISE EXCEPTION 'El nombre del afianzado es obligatorio';
  END IF;
  IF p_cliente_email IS NULL OR btrim(p_cliente_email) = '' THEN
    RAISE EXCEPTION 'El correo del afianzado es obligatorio: sin el no hay a quien enviarle la invitacion IVE';
  END IF;
  IF COALESCE(p_monto, 0) <= 0 THEN
    RAISE EXCEPTION 'El monto solicitado debe ser mayor que cero';
  END IF;

  SELECT * INTO v_beneficiario FROM public.beneficiarios WHERE codigo_contacto = p_beneficiario_codigo;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'El beneficiario % no existe', p_beneficiario_codigo;
  END IF;

  -- Barrera de tenant: el personal asegurador pide por cualquier marca; una marca solo por si misma.
  IF NOT public.d6_es_personal_aseguradora()
     AND v_beneficiario.id NOT IN (SELECT beneficiario_id FROM public.get_user_beneficiario_ids(auth.uid())) THEN
    RAISE EXCEPTION 'No puede solicitar altas de una marca que no es la suya';
  END IF;

  SELECT * INTO v_cliente FROM public.clientes
   WHERE (p_cliente_nit IS NOT NULL AND btrim(p_cliente_nit) <> '' AND nit = p_cliente_nit)
      OR ((p_cliente_nit IS NULL OR btrim(p_cliente_nit) = '') AND nombre = p_cliente_nombre)
   ORDER BY created_at LIMIT 1;

  IF NOT FOUND THEN
    -- Los afianzados nacidos en la app viven en un rango propio de codigo_contacto
    -- para no chocar nunca con los codigos que baja Oracle.
    INSERT INTO public.clientes (codigo_contacto, nombre, nit, tipo_persona, telefono, email)
    VALUES (
      (SELECT GREATEST(COALESCE(MAX(codigo_contacto), 900000000), 900000000) + 1
         FROM public.clientes WHERE codigo_contacto >= 900000000),
      btrim(p_cliente_nombre),
      NULLIF(btrim(COALESCE(p_cliente_nit, '')), ''),
      COALESCE(p_tipo_persona, 'INDIVIDUAL'),
      NULLIF(btrim(COALESCE(p_cliente_telefono, '')), ''),
      NULLIF(btrim(p_cliente_email), '')
    )
    RETURNING * INTO v_cliente;
  END IF;

  SELECT COALESCE(SUM(monto_afianzado), 0) INTO v_exposicion
    FROM public.fianzas
   WHERE cliente_id = v_cliente.id
     AND operational_status IN ('VIGENTE', 'POR_RENOVAR', 'PENDIENTE_ANULACION');

  v_numero := 'ALT-' || to_char(now(), 'YYYY') || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));

  INSERT INTO public.solicitudes_alta (
    numero_solicitud, cliente_id, beneficiario_id, monto_solicitado,
    vigencia_desde, vigencia_hasta, contrato_numero, tema_de_fianza,
    estado, estado_operativo, requiere_documento_accesorio, exposicion_vigente, creado_por
  ) VALUES (
    v_numero, v_cliente.id, v_beneficiario.id, p_monto,
    v_desde, COALESCE(p_vigencia_hasta, (v_desde + INTERVAL '1 year')::date),
    NULLIF(btrim(COALESCE(p_contrato_numero, '')), ''), 'Consignacion comercial',
    'BORRADOR', 'IVE_PENDIENTE',
    (p_monto > 300000 OR p_monto + v_exposicion > 300000), v_exposicion, auth.uid()
  )
  RETURNING id INTO v_solicitud_id;

  -- Invitacion IVE del propio expediente. No se reusa crear_invitacion_ive porque
  -- esa exige rol de aseguradora; la barrera aqui ya la impuso el bloque de tenant.
  INSERT INTO public.ive_invitaciones (solicitud_alta_id, token_hash, destinatario_email, expires_at, created_by)
  VALUES (v_solicitud_id, encode(extensions.digest(v_token, 'sha256'), 'hex'), btrim(p_cliente_email), v_expira, auth.uid());

  RETURN QUERY SELECT v_solicitud_id, v_numero, v_token, v_expira;
END;
$$;

REVOKE ALL ON FUNCTION public.d6_marca_crear_solicitud_alta(
  INTEGER, TEXT, TEXT, NUMERIC, TEXT, TEXT, public.tipo_persona, DATE, DATE, TEXT, INTEGER
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.d6_marca_crear_solicitud_alta(
  INTEGER, TEXT, TEXT, NUMERIC, TEXT, TEXT, public.tipo_persona, DATE, DATE, TEXT, INTEGER
) TO authenticated;

COMMENT ON FUNCTION public.d6_marca_crear_solicitud_alta(
  INTEGER, TEXT, TEXT, NUMERIC, TEXT, TEXT, public.tipo_persona, DATE, DATE, TEXT, INTEGER
) IS
  'Unica via por la que una marca crea un expediente de alta. Valida que el beneficiario sea suyo, deja la solicitud en IVE_PENDIENTE y devuelve el token IVE de un solo uso. La marca sigue sin poder aprobar, emitir ni cargar documentos.';

-- La marca que pidio el alta tiene que poder reenviar o revocar el enlace IVE de su
-- propio expediente; si no, queda con una solicitud creada y sin forma de que el
-- afianzado la complete. Se sustituye el chequeo de rol por la barrera de tenant, que
-- ya cubre al personal asegurador (d6_puede_ver_beneficiario lo incluye).
CREATE OR REPLACE FUNCTION public.crear_invitacion_ive(p_solicitud_id UUID, p_destinatario_email TEXT, p_horas INTEGER DEFAULT 72)
RETURNS TABLE(token TEXT, expires_at TIMESTAMPTZ)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_token TEXT := encode(extensions.gen_random_bytes(32), 'hex');
  v_expires_at TIMESTAMPTZ := now() + make_interval(hours => GREATEST(p_horas, 1));
  v_beneficiario_id UUID;
  v_estado public.d6_solicitud_status;
BEGIN
  SELECT beneficiario_id INTO v_beneficiario_id FROM public.solicitudes_alta WHERE id = p_solicitud_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'La solicitud de alta no existe';
  END IF;
  IF NOT public.d6_puede_ver_beneficiario(v_beneficiario_id) THEN
    RAISE EXCEPTION 'No tiene permiso para crear invitaciones IVE de este expediente';
  END IF;
  SELECT estado_operativo INTO v_estado FROM public.solicitudes_alta WHERE id = p_solicitud_id;
  -- Una invitacion solo tiene sentido con el expediente abierto. Sin esto, reenviar el
  -- enlace regresaba a IVE_PENDIENTE un expediente ya resuelto o emitido.
  IF v_estado NOT IN ('BORRADOR', 'IVE_PENDIENTE', 'EXPEDIENTE_RECIBIDO', 'EN_REVISION', 'INFORMACION_COMPLEMENTARIA') THEN
    RAISE EXCEPTION 'El expediente ya esta resuelto (%): no se puede emitir una nueva invitacion IVE', v_estado;
  END IF;
  UPDATE public.ive_invitaciones SET revoked_at = now()
    WHERE solicitud_alta_id = p_solicitud_id AND used_at IS NULL AND revoked_at IS NULL;
  INSERT INTO public.ive_invitaciones (solicitud_alta_id, token_hash, destinatario_email, expires_at, created_by)
    VALUES (p_solicitud_id, encode(extensions.digest(v_token, 'sha256'), 'hex'), p_destinatario_email, v_expires_at, auth.uid());
  UPDATE public.solicitudes_alta SET estado_operativo = 'IVE_PENDIENTE'
    WHERE id = p_solicitud_id AND estado_operativo IN ('BORRADOR', 'IVE_PENDIENTE');
  RETURN QUERY SELECT v_token, v_expires_at;
END;
$$;
