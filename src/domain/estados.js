// Nombres que ve el usuario y tono visual de cada estado. Aqui solo hay presentacion.

// Desde la migracion 044 una solicitud avanza sola: el distribuidor llena, Fidelis la recibe
// y queda emitida cuando la fianza aparece en la carga de FISO.
export const ESTADO_ALTA = {
  BORRADOR: { texto: 'El distribuidor está llenando', tono: 'atencion' },
  IVE_PENDIENTE: { texto: 'El distribuidor está llenando', tono: 'atencion' },
  EXPEDIENTE_RECIBIDO: { texto: 'Recibida por Fidelis', tono: 'activo' },
  EMITIDA: { texto: 'Emitida en FISO', tono: 'ok' },
  // Estados anteriores a la migracion 044. Ya no se producen: se muestran sin acciones.
  EN_REVISION: { texto: 'En revisión (anterior)', tono: 'neutro' },
  INFORMACION_COMPLEMENTARIA: { texto: 'Faltaba información (anterior)', tono: 'neutro' },
  APROBADA_TOTAL: { texto: 'Aprobada (anterior)', tono: 'neutro' },
  APROBADA_PARCIAL: { texto: 'Aprobada por menor monto (anterior)', tono: 'neutro' },
  NO_ELEGIBLE: { texto: 'No elegible (anterior)', tono: 'neutro' },
  SUSPENDIDA: { texto: 'Suspendida (anterior)', tono: 'neutro' },
};

export const ESTADOS_EN_TRAMITE = ['BORRADOR', 'IVE_PENDIENTE', 'EXPEDIENTE_RECIBIDO'];
export const ESTADOS_ANTERIORES = ['EN_REVISION', 'INFORMACION_COMPLEMENTARIA', 'APROBADA_TOTAL', 'APROBADA_PARCIAL', 'NO_ELEGIBLE', 'SUSPENDIDA'];

// Pasos de la linea de tiempo que ve la marca.
export const PASOS_ALTA = [
  { clave: 'IVE_PENDIENTE', texto: 'El distribuidor está llenando' },
  { clave: 'EXPEDIENTE_RECIBIDO', texto: 'Recibida por Fidelis' },
  { clave: 'EMITIDA', texto: 'Emitida en FISO' },
];

// Que esta pasando, dicho para la marca.
export const SIGUIENTE_PASO_MARCA = {
  BORRADOR: 'El distribuidor llena sus datos y sube documentos. Usted puede adelantar parte.',
  IVE_PENDIENTE: 'El distribuidor llena sus datos y sube documentos. Usted puede adelantar parte.',
  EXPEDIENTE_RECIBIDO: 'Fidelis tiene la solicitud. Cuando la fianza se emita en FISO aparece aquí sola.',
  EMITIDA: 'La fianza está emitida en FISO.',
};

export const ESTADO_POLIZA = {
  VIGENTE: { texto: 'Vigente', tono: 'ok' },
  POR_RENOVAR: { texto: 'Vence pronto', tono: 'atencion' },
  VENCIDA: { texto: 'Vencida', tono: 'critico' },
  EN_BAJA: { texto: 'En proceso de baja', tono: 'atencion' },
  CANCELADA: { texto: 'Cancelada', tono: 'neutro' },
  ANULADA: { texto: 'Anulada', tono: 'neutro' },
};

// La baja la pide la marca y queda procesada cuando FISO cancela la fianza.
export const ESTADO_BAJA = {
  PENDIENTE_REVISION: { texto: 'Pedida', tono: 'atencion' },
  APROBADA: { texto: 'Pedida', tono: 'atencion' },
  RECHAZADA: { texto: 'Rechazada (anterior)', tono: 'neutro' },
  CANCELADA: { texto: 'Retirada', tono: 'neutro' },
  BORRADOR: { texto: 'Borrador', tono: 'neutro' },
};

export function procesadaEnFiso(baja) {
  return ['CANCELADA', 'ANULADA'].includes(baja?.fianza?.operational_status);
}

export const TIPO_BAJA = {
  DEVOLUCION_MERCADERIA: 'Devolución de mercadería',
  VENTA_EFECTUADA: 'Liquidación de la venta',
  SUSTITUCION_POLIZA: 'Sustitución por otra fianza',
  VENCIMIENTO_PLAZO: 'Fin del contrato',
  OTRO: 'Otro motivo',
};

// Estado de pago de un mes de la cuenta de la marca (vista v_cuenta_marca).
export const ESTADO_PAGO = {
  PAGADO: { texto: 'Pagado', tono: 'ok' },
  PARCIAL: { texto: 'Pago parcial', tono: 'atencion' },
  PENDIENTE: { texto: 'Pendiente', tono: 'activo' },
  VENCIDO: { texto: 'Vencido', tono: 'critico' },
};

export const TIPO_PERSONA = {
  INDIVIDUAL: 'Persona o comerciante individual',
  JURIDICA: 'Sociedad (persona jurídica)',
};

export const CATEGORIA_DOCUMENTO = {
  IVE_ASS_01: 'Formulario IVE',
  IVE_ASS_02: 'Formulario IVE de persona jurídica',
  DPI: 'DPI',
  RTU: 'RTU',
  PATENTE_EMPRESA: 'Patente de empresa',
  PATENTE_SOCIEDAD: 'Patente de sociedad',
  ESCRITURA_CONSTITUCION: 'Escritura de constitución',
  NOMBRAMIENTO_REPRESENTANTE: 'Nombramiento del representante',
  RECIBO_SERVICIO: 'Recibo de servicio',
  ESTADO_CUENTA: 'Estados de cuenta bancarios',
  ESTADO_PATRIMONIAL: 'Estado patrimonial',
  ESTADOS_FINANCIEROS: 'Estados financieros',
  APROBACION_FIANZA: 'Resolución de la marca',
  CARTA_INVESTIGACION: 'Carta de investigación',
  PAGO_ELECTRONICO: 'Autorización de pago electrónico',
  SOLICITUD_DISTRIBUCION: 'Solicitud de distribución',
  CARTA_BAJA: 'Carta de baja',
  FORMULARIO_FIDELIS: 'Formulario Fidelis',
  DOCUMENTO_LEGAL: 'Documento legal',
  RECIBO_PAGO: 'Comprobante de pago',
  FINIQUITO: 'Finiquito',
  OTRO: 'Otro documento',
};

export function info(mapa, clave) {
  return mapa[clave] || { texto: clave || 'Sin estado', tono: 'neutro' };
}

export const ESTADO_RECLAMO = {
  AVISO: { texto: 'Aviso de incumplimiento', tono: 'atencion' },
  PRESENTADO: { texto: 'Reclamo presentado', tono: 'activo' },
  EN_ANALISIS: { texto: 'En análisis', tono: 'activo' },
  REQUERIMIENTO: { texto: 'Requerido al afianzado', tono: 'atencion' },
  PROCEDENTE: { texto: 'Procedente', tono: 'critico' },
  PROCEDENTE_PARCIAL: { texto: 'Procedente parcial', tono: 'critico' },
  IMPROCEDENTE: { texto: 'Improcedente', tono: 'neutro' },
  PAGADO: { texto: 'Pagado a la marca', tono: 'critico' },
  EN_RECOBRO: { texto: 'En recobro', tono: 'atencion' },
  RECUPERADO: { texto: 'Recuperado', tono: 'ok' },
  CERRADO: { texto: 'Cerrado', tono: 'neutro' },
  DESISTIDO: { texto: 'Desistido', tono: 'neutro' },
};

export const TIPO_RECLAMO = {
  FALTA_PAGO: 'Vendió unidades y no pagó',
  PERDIDA_UNIDADES: 'Pérdida o robo de unidades',
  NO_DEVOLUCION_INVENTARIO: 'No devolvió el inventario',
  OTRO: 'Otro incumplimiento',
};

export const NIVEL_RIESGO = {
  ALTO: { texto: 'Riesgo alto', tono: 'critico' },
  MEDIO: { texto: 'Riesgo medio', tono: 'atencion' },
  BAJO: { texto: 'Riesgo bajo', tono: 'ok' },
};
