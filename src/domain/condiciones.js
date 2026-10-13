// Condiciones por marca: el anexo del procedimiento en palabras. Solo de consulta.
import { pct, q } from '../lib/format';

export const FORMA_PAGO = {
  MES_SIGUIENTE: 'Cuotas, vencen el último día del mes siguiente',
  ANTICIPADO: 'Pago anticipado por toda la vigencia',
};
export const INCREMENTO = {
  NUEVA_POLIZA: 'Fianza nueva que reemplaza a la anterior',
  MODIFICACION: 'Modificación de la misma fianza (endoso)',
};

export function resumenCondiciones(c) {
  if (!c) return [];
  return [
    ['Contrato', `${c.plazo_contrato_anios} años, fianza de ${c.vigencia_fianza_meses} meses que se renueva`],
    ['Tarifa', c.grupo?.tarifa_prima ? `${pct(c.grupo.tarifa_prima, 2)} del monto, más 8 % de derechos e IVA` : null],
    ['Forma de pago', `${FORMA_PAGO[c.forma_pago]}${c.cuotas > 1 ? `, hasta ${c.cuotas} cuotas` : ''}${c.medio_pago ? ` con ${c.medio_pago.toLowerCase()}` : ''}`],
    ['Incrementos', INCREMENTO[c.incremento]],
    ['Monto sugerido para un distribuidor nuevo', c.monto_sugerido ? q(c.monto_sugerido) : null],
  ].filter(([, valor]) => valor);
}
