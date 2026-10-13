-- Nombres de requisitos con ortografia correcta: los ve el afianzado en el portal.
UPDATE public.ive_requisitos_d6 SET nombre = 'RTU actualizado (constancia de inscripción en la SAT)' WHERE version = 'FIDELIS-D6-2026.2' AND categoria = 'RTU' AND tipo_persona = 'INDIVIDUAL';
UPDATE public.ive_requisitos_d6 SET nombre = 'Recibo de agua, luz o teléfono de la dirección declarada', ayuda = 'Puede estar a nombre de otra persona si la dirección coincide.' WHERE version = 'FIDELIS-D6-2026.2' AND categoria = 'RECIBO_SERVICIO';
UPDATE public.ive_requisitos_d6 SET nombre = 'Estados de cuenta bancarios de los últimos 3 meses', ayuda = 'Los tres meses más recientes, con el nombre del titular visible.' WHERE version = 'FIDELIS-D6-2026.2' AND categoria = 'ESTADO_CUENTA' AND tipo_persona = 'INDIVIDUAL';
UPDATE public.ive_requisitos_d6 SET nombre = 'Estados de cuenta bancarios de los últimos 3 meses' WHERE version = 'FIDELIS-D6-2026.2' AND categoria = 'ESTADO_CUENTA' AND tipo_persona = 'JURIDICA';
UPDATE public.ive_requisitos_d6 SET nombre = 'Resolución de crédito de la marca', ayuda = 'Nota de resolución o solicitud de distribución aprobada por la marca.' WHERE version = 'FIDELIS-D6-2026.2' AND categoria = 'APROBACION_FIANZA';
UPDATE public.ive_requisitos_d6 SET ayuda = 'Solo si su RTU indica contador registrado o régimen sobre utilidades.' WHERE version = 'FIDELIS-D6-2026.2' AND categoria = 'ESTADOS_FINANCIEROS' AND tipo_persona = 'INDIVIDUAL';
UPDATE public.ive_requisitos_d6 SET nombre = 'Estados financieros del último cierre' WHERE version = 'FIDELIS-D6-2026.2' AND categoria = 'ESTADOS_FINANCIEROS' AND tipo_persona = 'JURIDICA';
UPDATE public.ive_requisitos_d6 SET nombre = 'Documento accesorio de contragarantía', ayuda = 'Requerido cuando el monto o la exposición total supera Q300,000.' WHERE version = 'FIDELIS-D6-2026.2' AND categoria = 'DOCUMENTO_ACCESORIO';
UPDATE public.ive_requisitos_d6 SET nombre = 'Escritura de constitución y modificaciones' WHERE version = 'FIDELIS-D6-2026.2' AND categoria = 'ESCRITURA_CONSTITUCION';
UPDATE public.ive_requisitos_d6 SET nombre = 'Formulario IVE de persona jurídica' WHERE version = 'FIDELIS-D6-2026.2' AND categoria = 'IVE_ASS_02';
