import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { calcularPrima, diasEntre } from '../src/domain/primas.js';

// Parser minimo de CSV con comillas y saltos de linea dentro de campos (trampa #6 de AI MEMORY/db).
function leerCsv(texto) {
  const filas = [];
  let fila = [];
  let campo = '';
  let comillas = false;
  for (let i = 0; i < texto.length; i += 1) {
    const c = texto[i];
    if (comillas) {
      if (c === '"' && texto[i + 1] === '"') { campo += '"'; i += 1; }
      else if (c === '"') comillas = false;
      else campo += c;
    } else if (c === '"') comillas = true;
    else if (c === ',') { fila.push(campo); campo = ''; }
    else if (c === '\n' || c === '\r') {
      if (c === '\r' && texto[i + 1] === '\n') i += 1;
      fila.push(campo); filas.push(fila); fila = []; campo = '';
    } else campo += c;
  }
  if (campo || fila.length) { fila.push(campo); filas.push(fila); }
  const [cabecera, ...datos] = filas.filter((f) => f.length > 1);
  return datos.map((f) => Object.fromEntries(cabecera.map((h, i) => [h, f[i]])));
}

test('prima, derechos e IVA de una fianza anual al 2 %', () => {
  const r = calcularPrima(250000, { tarifa: 0.02 });
  assert.equal(r.prima, 5000);
  assert.equal(r.derechos, 400);
  assert.equal(r.iva, 648);
  assert.equal(r.total, 6048);
});

test('UMA usa 2.25 %', () => {
  assert.equal(calcularPrima(100000, { tarifa: 0.0225 }).prima, 2250);
});

test('una vigencia distinta a un año se prorratea por día', () => {
  const r = calcularPrima(100000, { tarifa: 0.02, dias: 180 });
  assert.equal(r.prima, Math.round(2000 * (180 / 365) * 100) / 100);
});

test('un año calendario cuenta como vigencia anual', () => {
  assert.equal(diasEntre('2026-07-02', '2027-07-01'), 365);
  assert.equal(calcularPrima(100000, { dias: diasEntre('2028-01-01', '2028-12-31') }).prima, 2000);
});

const RUTA_CSV = new URL('../../d6-consignacion.csv', import.meta.url);

test('el cálculo reproduce las emisiones del CSV de Oracle', { skip: !existsSync(RUTA_CSV) && 'sin d6-consignacion.csv' }, () => {
  const filas = leerCsv(readFileSync(RUTA_CSV, 'utf8'));
  assert.equal(filas.length, 610, 'el export tiene 610 polizas');
  // Emisiones nuevas vigentes con tarifa anual exacta de 2 % o 2.25 %.
  const muestra = filas.filter((f) => f.ENDOSO === '0' && f.STATUS === 'V' && Number(f.MONTO_AFIANZADO) > 0);
  let comparadas = 0;
  for (const f of muestra) {
    const monto = Number(f.MONTO_AFIANZADO);
    const tarifa = Number(f.PRIMA_ANUAL) / monto;
    if (![0.02, 0.0225].some((t) => Math.abs(t - tarifa) < 1e-9)) continue;
    const r = calcularPrima(monto, { tarifa, otros: Number(f.OTROS || 0) });
    assert.equal(r.prima, Number(f.PRIMA_ANUAL), `prima fianza ${f.FIANZA}`);
    assert.equal(r.derechos, Number(f.DERECHOS), `derechos fianza ${f.FIANZA}`);
    assert.ok(Math.abs(r.iva - Number(f.IVA)) <= 0.01, `IVA fianza ${f.FIANZA}: ${r.iva} vs ${f.IVA}`);
    comparadas += 1;
  }
  assert.ok(comparadas >= 50, `se compararon ${comparadas} emisiones`);
});
