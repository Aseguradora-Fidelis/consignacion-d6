// Calculo de prima D-6 observado en d6-consignacion.csv (610 polizas):
//   prima = tarifa de la marca x monto afianzado (2 % general, 2.25 % UMA)
//   derechos = 8 % de la prima
//   IVA = 12 % de (prima + derechos + otros)
export const TARIFA_GENERAL = 0.02;
export const DERECHOS = 0.08;
export const IVA = 0.12;

const redondear = (n) => Math.round((Number(n) + Number.EPSILON) * 100) / 100;

export function diasEntre(desde, hasta) {
  if (!desde || !hasta) return 365;
  const a = new Date(`${desde}T00:00:00`);
  const b = new Date(`${hasta}T00:00:00`);
  return Math.round((b - a) / 86_400_000) + 1;
}

export function calcularPrima(monto, { tarifa = TARIFA_GENERAL, otros = 0, dias = 365 } = {}) {
  const base = Number(monto || 0) * Number(tarifa || TARIFA_GENERAL);
  // Una vigencia de un ano paga la tarifa anual. Otras vigencias se prorratean por dia.
  const factor = dias >= 364 && dias <= 366 ? 1 : Number(dias || 365) / 365;
  const prima = redondear(base * factor);
  const derechos = redondear(prima * DERECHOS);
  const otrosR = redondear(otros);
  const iva = redondear((prima + derechos + otrosR) * IVA);
  return { prima, derechos, iva, otros: otrosR, total: redondear(prima + derechos + iva + otrosR) };
}
