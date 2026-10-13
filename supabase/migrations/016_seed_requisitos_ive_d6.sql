-- Se separa de 015 porque PostgreSQL no permite usar un valor enum recién agregado
-- en la misma transacción de migración.
INSERT INTO public.ive_requisitos_d6 (version, tipo_persona, categoria, nombre)
VALUES
  ('FIDELIS-D6-2026.1', 'INDIVIDUAL', 'IVE_ASS_01', 'Formulario de identificación de aseguradoras'),
  ('FIDELIS-D6-2026.1', 'INDIVIDUAL', 'DPI', 'DPI vigente'),
  ('FIDELIS-D6-2026.1', 'INDIVIDUAL', 'RTU', 'RTU o constancia de NIT'),
  ('FIDELIS-D6-2026.1', 'INDIVIDUAL', 'ESTADO_CUENTA', 'Estados de cuenta de los últimos 3 meses'),
  ('FIDELIS-D6-2026.1', 'INDIVIDUAL', 'FORMULARIO_FIDELIS', 'Solicitud Fidelis D-6 firmada'),
  ('FIDELIS-D6-2026.1', 'INDIVIDUAL', 'APROBACION_FIANZA', 'Resolución de línea de la marca'),
  ('FIDELIS-D6-2026.1', 'INDIVIDUAL', 'DOCUMENTO_ACCESORIO', 'Documento accesorio de contragarantía'),
  ('FIDELIS-D6-2026.1', 'JURIDICA', 'IVE_ASS_02', 'Formulario de identificación de aseguradoras'),
  ('FIDELIS-D6-2026.1', 'JURIDICA', 'RTU', 'RTU o constancia de NIT de la entidad'),
  ('FIDELIS-D6-2026.1', 'JURIDICA', 'PATENTE_SOCIEDAD', 'Patente de comercio de sociedad'),
  ('FIDELIS-D6-2026.1', 'JURIDICA', 'PATENTE_EMPRESA', 'Patente de comercio de empresa'),
  ('FIDELIS-D6-2026.1', 'JURIDICA', 'ESCRITURA_CONSTITUCION', 'Escritura de constitución y modificaciones'),
  ('FIDELIS-D6-2026.1', 'JURIDICA', 'NOMBRAMIENTO_REPRESENTANTE', 'Nombramiento vigente del representante legal'),
  ('FIDELIS-D6-2026.1', 'JURIDICA', 'DPI', 'DPI vigente del representante legal'),
  ('FIDELIS-D6-2026.1', 'JURIDICA', 'ESTADO_CUENTA', 'Estados de cuenta de los últimos 3 meses'),
  ('FIDELIS-D6-2026.1', 'JURIDICA', 'FORMULARIO_FIDELIS', 'Solicitud Fidelis D-6 firmada'),
  ('FIDELIS-D6-2026.1', 'JURIDICA', 'APROBACION_FIANZA', 'Resolución de línea de la marca'),
  ('FIDELIS-D6-2026.1', 'JURIDICA', 'DOCUMENTO_ACCESORIO', 'Documento accesorio de contragarantía')
ON CONFLICT (version, tipo_persona, categoria) DO NOTHING;

UPDATE public.ive_requisitos_d6
SET requiere_umbral_exposicion = true
WHERE version = 'FIDELIS-D6-2026.1' AND categoria = 'DOCUMENTO_ACCESORIO';
