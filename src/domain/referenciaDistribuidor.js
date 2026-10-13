// Lectura de la referencia del distribuidor (RPC d6_referencia_alta), solo para consulta.
// Ordena lo que Fidelis ya sabe del distribuidor: cuanto maneja hoy, con cuantas marcas, su
// historial y sus posibles vinculados. No sugiere ni decide: la decision vive en FISO.

export const CRECIMIENTO_RAZONABLE = 1.5;
export const CRECIMIENTO_MAXIMO = 2;

const n = (v) => Number(v || 0);
const qz = (v) => `Q${Math.round(n(v)).toLocaleString('en-US')}`;
const veces = (r) => r.toLocaleString('es-GT', { maximumFractionDigits: 1 });

// Lo que el afianzado ya maneja con la marca: la fianza que cambia, o su exposicion con la marca,
// o el monto mas alto que haya tenido.
export function montoBase(ref) {
  if (ref.tipo_solicitud !== 'NUEVA' && n(ref.monto_anterior) > 0) return n(ref.monto_anterior);
  if (n(ref.exposicion_marca) > 0) return n(ref.exposicion_marca);
  return n(ref.maximo_historico);
}

export function leerReferencia(ref) {
  if (!ref) return null;
  const lineas = [];
  const solicitado = n(ref.monto_solicitado);
  const base = montoBase(ref);
  const perfil = ref.perfil || {};
  const marca = ref.marca || {};
  const vinculados = ref.vinculados || [];

  if (base > 0) {
    const r = solicitado / base;
    const tono = r <= CRECIMIENTO_RAZONABLE ? 'ok' : r <= CRECIMIENTO_MAXIMO ? 'atencion' : 'critico';
    lineas.push({ tono, texto: `Pide ${qz(solicitado)}. Hoy maneja ${qz(base)}: ${veces(r)} ${veces(r) === '1' ? 'vez' : 'veces'}.` });
  } else if (n(marca.p90) > 0) {
    const sobreP90 = solicitado > n(marca.p90);
    lineas.push({
      tono: sobreP90 ? 'atencion' : 'ok',
      texto: sobreP90
        ? `Cliente nuevo. Pide ${qz(solicitado)}, más que el 90 % de los distribuidores activos de ${marca.nombre} (${qz(marca.p90)}).`
        : `Cliente nuevo. Pide ${qz(solicitado)}, dentro de lo normal en ${marca.nombre} (el 50 % maneja hasta ${qz(marca.mediana)}).`,
    });
  }

  if (n(ref.resolucion_marca_monto) > 0 && solicitado > n(ref.resolucion_marca_monto)) {
    lineas.push({ tono: 'critico', texto: `Pide más de lo que aprobó la marca (${qz(ref.resolucion_marca_monto)}).` });
  }
  if (n(perfil.reclamos) > 0) {
    lineas.push({ tono: 'critico', texto: `Tiene ${perfil.reclamos} reclamo${perfil.reclamos > 1 ? 's' : ''} en su historial con Fidelis.` });
  }
  if (n(perfil.max_dias_atraso) > 60) {
    lineas.push({
      tono: n(perfil.max_dias_atraso) > 90 ? 'critico' : 'atencion',
      texto: `Debe ${qz(perfil.saldo_atrasado)} con ${perfil.max_dias_atraso} días de atraso.`,
    });
  }
  if (perfil.ive_vencido) {
    lineas.push({ tono: 'atencion', texto: 'Su formulario IVE en FISO está vencido. Este expediente lo actualiza.' });
  }
  if (vinculados.length) {
    const suma = vinculados.reduce((t, v) => t + n(v.exposicion), 0);
    lineas.push({
      tono: 'atencion',
      texto: `${vinculados.length} posible${vinculados.length > 1 ? 's' : ''} vinculado${vinculados.length > 1 ? 's' : ''} por teléfono, dirección, patente o apellidos, con ${qz(suma)} afianzados.`,
    });
  }

  const contexto = ref.historial_d6
    ? `En D-6, ${ref.historial_d6.con_reclamo} de ${ref.historial_d6.afianzados} afianzados han tenido un reclamo.`
    : null;

  return { lineas, base, contexto };
}
