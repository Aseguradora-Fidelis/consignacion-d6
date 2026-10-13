-- IVE operativo y puente Oracle para D-6.
-- Oracle nunca se consulta desde el navegador. El job interno usa una cuenta de solo lectura.

ALTER TYPE public.doc_categoria ADD VALUE IF NOT EXISTS 'IVE_ASS_01';
ALTER TYPE public.doc_categoria ADD VALUE IF NOT EXISTS 'IVE_ASS_02';
ALTER TYPE public.doc_categoria ADD VALUE IF NOT EXISTS 'DPI';
ALTER TYPE public.doc_categoria ADD VALUE IF NOT EXISTS 'RTU';
ALTER TYPE public.doc_categoria ADD VALUE IF NOT EXISTS 'PATENTE_SOCIEDAD';
ALTER TYPE public.doc_categoria ADD VALUE IF NOT EXISTS 'PATENTE_EMPRESA';
ALTER TYPE public.doc_categoria ADD VALUE IF NOT EXISTS 'ESCRITURA_CONSTITUCION';
ALTER TYPE public.doc_categoria ADD VALUE IF NOT EXISTS 'NOMBRAMIENTO_REPRESENTANTE';
ALTER TYPE public.doc_categoria ADD VALUE IF NOT EXISTS 'DOCUMENTO_ACCESORIO';

ALTER TABLE public.solicitudes_alta
  ADD COLUMN IF NOT EXISTS ive_form_version TEXT,
  ADD COLUMN IF NOT EXISTS ive_completed_at TIMESTAMPTZ;

CREATE TABLE IF NOT EXISTS public.ive_requisitos_d6 (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  version TEXT NOT NULL,
  tipo_persona public.tipo_persona NOT NULL,
  categoria public.doc_categoria NOT NULL,
  nombre TEXT NOT NULL,
  obligatorio BOOLEAN NOT NULL DEFAULT true,
  requiere_umbral_exposicion BOOLEAN NOT NULL DEFAULT false,
  activo BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (version, tipo_persona, categoria)
);

CREATE OR REPLACE FUNCTION public.validar_datos_ive_d6(p_datos JSONB)
RETURNS VOID
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public
AS $$
DECLARE
  v_tipo TEXT := COALESCE(p_datos->>'tipoIve', '');
  v_campo TEXT;
  v_requeridos TEXT[];
BEGIN
  IF v_tipo IN ('IVE-IR-01', 'IVE-ASS-01') THEN
    v_requeridos := ARRAY['primerNombre', 'primerApellido', 'dpi', 'nit', 'telefono', 'correo', 'direccion', 'municipio', 'departamento', 'nacionalidad', 'profesion', 'lugarTrabajo', 'cargoTrabajo', 'ingresosMensuales', 'egresosMensuales', 'estadoCivil', 'refNombre1', 'refTelefono1'];
  ELSIF v_tipo IN ('IVE-IR-02', 'IVE-ASS-02') THEN
    v_requeridos := ARRAY['razonSocial', 'nitEntidad', 'actividadEconomica', 'paisConstitucion', 'escrituraNumero', 'escrituraFecha', 'notarioConstitucion', 'patenteSociedad', 'patenteEmpresa', 'registroMercantil', 'direccionSede', 'telefonoEmpresa', 'correoEmpresa', 'repNombreCompleto', 'repDpi', 'repNit', 'repCargo', 'repNombramientoNotario', 'repNombramientoFecha'];
  ELSE
    RAISE EXCEPTION 'Tipo de formulario IVE no reconocido';
  END IF;

  FOREACH v_campo IN ARRAY v_requeridos LOOP
    IF NULLIF(BTRIM(COALESCE(p_datos->>v_campo, '')), '') IS NULL THEN
      RAISE EXCEPTION 'Falta el campo IVE requerido: %', v_campo;
    END IF;
  END LOOP;

  IF COALESCE((p_datos->>'declaracionVeracidad')::BOOLEAN, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'Debe aceptar la declaración de veracidad';
  END IF;
  IF NULLIF(BTRIM(COALESCE(p_datos->>'firmaImagen', '')), '') IS NULL THEN
    RAISE EXCEPTION 'Debe capturar la firma del solicitante';
  END IF;
  IF p_datos->>'esPEP' = 'SI' AND NULLIF(BTRIM(COALESCE(p_datos->>'pepDetalle', '')), '') IS NULL THEN
    RAISE EXCEPTION 'Falta detalle de condición PEP';
  END IF;
  IF p_datos->>'parientePEP' = 'SI' AND NULLIF(BTRIM(COALESCE(p_datos->>'parientePepDetalle', '')), '') IS NULL THEN
    RAISE EXCEPTION 'Falta detalle de parentesco PEP';
  END IF;
  IF p_datos->>'asociadoPEP' = 'SI' AND NULLIF(BTRIM(COALESCE(p_datos->>'asociadoPepDetalle', '')), '') IS NULL THEN
    RAISE EXCEPTION 'Falta detalle de asociación PEP';
  END IF;
  IF p_datos->>'repEsPEP' = 'SI' AND NULLIF(BTRIM(COALESCE(p_datos->>'repPepDetalle', '')), '') IS NULL THEN
    RAISE EXCEPTION 'Falta detalle PEP del representante legal';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.completar_ive_invitacion(p_token TEXT, p_datos JSONB)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_invitacion public.ive_invitaciones%ROWTYPE;
BEGIN
  PERFORM public.validar_datos_ive_d6(p_datos);
  SELECT * INTO v_invitacion FROM public.ive_invitaciones
  WHERE token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
    AND used_at IS NULL AND revoked_at IS NULL AND expires_at > now()
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'La invitación no es válida, expiró o fue revocada'; END IF;
  UPDATE public.ive_invitaciones SET used_at = now() WHERE id = v_invitacion.id;
  UPDATE public.solicitudes_alta
  SET ive_data = p_datos,
      ive_form_version = COALESCE(NULLIF(p_datos->>'versionFormulario', ''), 'FIDELIS-D6-2026.1'),
      ive_completed_at = now(),
      estado_operativo = 'EXPEDIENTE_RECIBIDO'
  WHERE id = v_invitacion.solicitud_alta_id;
  RETURN v_invitacion.solicitud_alta_id;
END;
$$;

CREATE TABLE IF NOT EXISTS public.oracle_sync_runs_d6 (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  fuente TEXT NOT NULL CHECK (fuente IN ('CIE_TRASLADO_MES', 'VW_SALDO_FACTURA', 'MG_CONTACTOS_IVE')),
  ventana_desde DATE,
  ventana_hasta DATE,
  estado TEXT NOT NULL CHECK (estado IN ('INICIADO', 'COMPLETO', 'FALLIDO')),
  filas_leidas INTEGER NOT NULL DEFAULT 0,
  filas_aplicadas INTEGER NOT NULL DEFAULT 0,
  checksum TEXT,
  error_resumido TEXT,
  ejecutado_en TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.oracle_d6_staging (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  sync_run_id UUID REFERENCES public.oracle_sync_runs_d6(id) ON DELETE SET NULL,
  fuente TEXT NOT NULL,
  source_key TEXT NOT NULL,
  periodo DATE,
  payload JSONB NOT NULL,
  source_updated_at TIMESTAMPTZ,
  imported_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (fuente, source_key)
);

ALTER TABLE public.ive_requisitos_d6 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.oracle_sync_runs_d6 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.oracle_d6_staging ENABLE ROW LEVEL SECURITY;

CREATE POLICY "D6 personal consulta requisitos IVE" ON public.ive_requisitos_d6 FOR SELECT USING (public.d6_es_personal_aseguradora());
CREATE POLICY "D6 personal consulta sincronizaciones Oracle" ON public.oracle_sync_runs_d6 FOR SELECT USING (public.d6_es_personal_aseguradora());
CREATE POLICY "D6 personal consulta staging Oracle" ON public.oracle_d6_staging FOR SELECT USING (public.d6_es_personal_aseguradora());

CREATE INDEX IF NOT EXISTS idx_oracle_d6_staging_periodo ON public.oracle_d6_staging (fuente, periodo DESC);
CREATE INDEX IF NOT EXISTS idx_oracle_d6_staging_fianza ON public.oracle_d6_staging ((payload->>'fianza'));

COMMENT ON TABLE public.oracle_d6_staging IS 'Zona privada de integración. Jamás se expone a UMA, ADMOSA ni al navegador.';
COMMENT ON FUNCTION public.validar_datos_ive_d6(JSONB) IS 'Valida integridad operativa del formulario D-6. La homologación normativa vigente requiere aprobación de Cumplimiento.';
