const moneda = new Intl.NumberFormat('es-GT', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const entero = new Intl.NumberFormat('es-GT', { maximumFractionDigits: 0 });

export function q(valor) {
  if (valor === null || valor === undefined || valor === '' || Number.isNaN(Number(valor))) return 'Q 0.00';
  return `Q ${moneda.format(Number(valor))}`;
}

// Montos grandes en tableros: Q 1.2 M, Q 350 mil.
export function qCorto(valor) {
  const n = Number(valor || 0);
  if (Math.abs(n) >= 1_000_000) return `Q ${(n / 1_000_000).toLocaleString('es-GT', { maximumFractionDigits: 1 })} M`;
  if (Math.abs(n) >= 10_000) return `Q ${entero.format(Math.round(n / 1000))} mil`;
  return q(n);
}

export function numero(valor) {
  return entero.format(Number(valor || 0));
}

export function pct(valor, decimales = 0) {
  return `${(Number(valor || 0) * 100).toLocaleString('es-GT', { maximumFractionDigits: decimales })} %`;
}

// Las fechas de Postgres llegan como YYYY-MM-DD. Se leen como fecha local, sin zona.
export function aFecha(valor) {
  if (!valor) return null;
  if (valor instanceof Date) return valor;
  const solo = /^\d{4}-\d{2}-\d{2}$/.test(valor) ? `${valor}T00:00:00` : valor;
  const d = new Date(solo);
  return Number.isNaN(d.getTime()) ? null : d;
}

export function fecha(valor) {
  const d = aFecha(valor);
  return d ? d.toLocaleDateString('es-GT', { day: '2-digit', month: '2-digit', year: 'numeric' }) : '';
}

export function fechaHora(valor) {
  const d = aFecha(valor);
  if (!d) return '';
  const dia = d.toLocaleDateString('es-GT', { day: '2-digit', month: '2-digit', year: 'numeric' });
  const hora = d.toLocaleTimeString('es-GT', { hour: '2-digit', minute: '2-digit', hour12: false });
  return `${dia} ${hora}`;
}

export function mes(valor) {
  const d = aFecha(valor);
  if (!d) return '';
  const texto = d.toLocaleDateString('es-GT', { month: 'long', year: 'numeric' });
  return texto.charAt(0).toUpperCase() + texto.slice(1);
}

export function hace(valor) {
  const d = aFecha(valor);
  if (!d) return '';
  const dias = Math.floor((Date.now() - d.getTime()) / 86_400_000);
  if (dias <= 0) return 'hoy';
  if (dias === 1) return 'ayer';
  return `hace ${dias} días`;
}

export function diasHasta(valor) {
  const d = aFecha(valor);
  if (!d) return null;
  const hoy = new Date();
  hoy.setHours(0, 0, 0, 0);
  return Math.round((d.getTime() - hoy.getTime()) / 86_400_000);
}

export function hoyISO() {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

export function isoDe(d) {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

// Nombres de Oracle vienen con dobles espacios.
export function nombre(valor) {
  return String(valor || '').replace(/\s+/g, ' ').trim();
}

// Enmascara identificadores en pantallas que no necesitan el dato completo.
export function enmascarar(valor, visibles = 4) {
  const s = String(valor || '');
  if (s.length <= visibles) return s;
  return `${'•'.repeat(Math.min(s.length - visibles, 6))}${s.slice(-visibles)}`;
}

export function tamanoArchivo(bytes) {
  const n = Number(bytes || 0);
  if (n >= 1_048_576) return `${(n / 1_048_576).toFixed(1)} MB`;
  return `${Math.max(1, Math.round(n / 1024))} KB`;
}
