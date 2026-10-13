// Glosario de D-6. Los mismos terminos se usan en la app y en el portal.

export const TERMINOS = [
  ['Afianzado', 'La persona o empresa que recibe las motos en consignación y a quien Fidelis le emite la fianza. También se le dice fiado o distribuidor. El DPI, el RTU y la patente que se piden son los suyos, no los de la marca.'],
  ['Beneficiario o marca', 'La empresa que entrega las motos en consignación (ADMOSA, UMA, Honda, Suzuki). Si el afianzado no paga o pierde unidades, la marca reclama la fianza.'],
  ['Fianza D-6', 'Garantía de Fidelis a favor de la marca por la mercadería que el afianzado recibe en consignación.'],
  ['Resolución de la marca', 'La carta con la que la marca aprueba el crédito al distribuidor: nota de resolución en ADMOSA, solicitud de distribución en UMA. Da 30 días para firmar el contrato. No es la decisión de Fidelis.'],
  ['Formulario IVE', 'El formulario de conocimiento del cliente que exige la Intendencia de Verificación Especial. IVE-IR-01 para persona individual y IVE-IR-02 para persona jurídica. El afianzado lo llena en el portal.'],
  ['Solicitud de alta', 'La marca la pide y comparte el enlace con su distribuidor. Avanza sola: el distribuidor está llenando, Fidelis la recibe con la lista de lo que falta, y queda emitida cuando la fianza aparece en FISO.'],
  ['Emitida en FISO', 'La app reconoce sola la fianza en la carga diaria de FISO por el NIT del distribuidor, la marca y la fecha. Número, vigencia y contrato vienen de FISO.'],
  ['Exposición', 'Suma de los montos de las fianzas activas de un afianzado con todas las marcas.'],
  ['Posibles vinculados', 'Afianzados que comparten teléfono, dirección, patente o los dos apellidos en el mismo municipio.'],
  ['Incremento', 'Subir el monto de un distribuidor que ya tiene fianza. Según la marca se emite como fianza nueva que reemplaza a la anterior, o como modificación de la misma fianza.'],
  ['Baja', 'La marca pide dejar de cubrir a un distribuidor. Surte efecto al cierre del mes que se elija y ese mes se cobra completo. Aparece procesada cuando FISO cancela la fianza.'],
  ['FISO', 'El sistema de Fidelis y la fuente de verdad. Ahí se emite la fianza, se factura y se aplican los pagos. La app recibe una carga diaria y no vuelve a capturar nada de eso.'],
  ['Pagos a Fidelis', 'Lo que FISO le facturó a la marca cada mes, con lo pagado y el saldo según la última carga de FISO.'],
  ['Cuadre con FISO', 'Comparación entre la app y FISO: bajas pedidas que FISO todavía no cancela, solicitudes recibidas sin fianza emitida, códigos duplicados y facturas sin marca.'],
  ['Aviso de incumplimiento', 'La marca informa que el distribuidor no pagó o perdió unidades, antes de reclamar la fianza. Da tiempo de gestionar el cobro.'],
  ['Reclamo', 'La marca pide formalmente que Fidelis pague. Si procede, Fidelis paga y luego le cobra al afianzado (repetición).'],
];

export const MOVIMIENTO = {
  NUEVA: { texto: 'Nueva', tono: 'ok', ayuda: 'Emitida este mes o el anterior' },
  CANCELA: { texto: 'Cancela', tono: 'atencion', ayuda: 'Baja con fecha futura' },
  CANCELADA: { texto: 'Cancelada', tono: 'critico', ayuda: 'Cancelada en los últimos dos meses' },
};
