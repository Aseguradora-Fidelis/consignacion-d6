import test from 'node:test';
import assert from 'node:assert/strict';
import { leerReferencia, montoBase } from '../src/domain/referenciaDistribuidor.js';

const marca = { nombre: 'ADMOSA', mediana: 200000, p90: 400000, distribuidores: 219 };
const base = {
  tipo_solicitud: 'NUEVA', monto_solicitado: 0, monto_anterior: null, exposicion_total: 0, exposicion_marca: 0,
  maximo_historico: null, marca, perfil: null, vinculados: [], historial_d6: { afianzados: 507, con_reclamo: 2 },
};

test('de 200 a 300 mil se lee como crecimiento razonable', () => {
  const r = leerReferencia({ ...base, monto_solicitado: 300000, exposicion_marca: 200000, exposicion_total: 200000 });
  assert.equal(r.lineas[0].tono, 'ok');
  assert.match(r.lineas[0].texto, /1,5 veces|1.5 veces/);
});

test('mas del doble de lo que maneja se marca en rojo', () => {
  const r = leerReferencia({ ...base, monto_solicitado: 500000, exposicion_marca: 200000, exposicion_total: 200000 });
  assert.equal(r.lineas[0].tono, 'critico');
});

test('un incremento se compara contra la fianza que cambia', () => {
  const ref = { ...base, tipo_solicitud: 'INCREMENTO', monto_anterior: 150000, exposicion_marca: 400000, monto_solicitado: 200000 };
  assert.equal(montoBase(ref), 150000);
  assert.equal(leerReferencia(ref).lineas[0].tono, 'ok');
});

test('cliente nuevo por encima del p90 de la marca', () => {
  const r = leerReferencia({ ...base, monto_solicitado: 600000 });
  assert.equal(r.lineas[0].tono, 'atencion');
  assert.match(r.lineas[0].texto, /90 %/);
});

test('el atraso y los vinculados quedan a la vista', () => {
  const r = leerReferencia({
    ...base, monto_solicitado: 100000,
    perfil: { max_dias_atraso: 120, saldo_atrasado: 5000 },
    vinculados: [{ nombre: 'X', exposicion: 200000, motivo: 'Mismo teléfono' }],
  });
  assert.ok(r.lineas.some((l) => /120 días de atraso/.test(l.texto) && l.tono === 'critico'));
  assert.ok(r.lineas.some((l) => /vinculado/.test(l.texto)));
});

test('no sugiere decisiones ni pide documento accesorio', () => {
  const r = leerReferencia({ ...base, monto_solicitado: 350000, exposicion_total: 200000, exposicion_marca: 120000 });
  assert.equal(r.sugerencia, undefined);
  assert.ok(!r.lineas.some((l) => /accesorio/.test(l.texto)));
});

test('pedir mas de lo que aprobo la marca', () => {
  const r = leerReferencia({ ...base, monto_solicitado: 250000, exposicion_marca: 200000, resolucion_marca_monto: 220000 });
  assert.ok(r.lineas.some((l) => /aprobó la marca/.test(l.texto)));
});
