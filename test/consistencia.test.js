import test from 'node:test';
import assert from 'node:assert/strict';
import { alertasExpediente, nombresCoinciden, revisarConsistencia } from '../src/domain/consistencia.js';

test('los nombres coinciden aunque falten segundos nombres o tildes', () => {
  assert.equal(nombresCoinciden('JUAN PÉREZ', 'Juan Carlos Perez López'), true);
  assert.equal(nombresCoinciden('JUANA PEREZ', 'JUAN CARLOS PEREZ'), false);
  assert.equal(nombresCoinciden('MARIA  DE  LEON', 'María de León Ruiz'), true);
});

const solicitud = {
  cliente_nombre_tmp: 'JUAN CARLOS PRUEBA',
  cliente_nit_tmp: '7777777-7',
  cliente_email_tmp: 'juan@ejemplo.test',
  monto_solicitado: 120000,
  resolucion_marca_monto: 100000,
  resolucion_marca_fecha: '2026-09-01',
};

test('marca diferencias entre la solicitud y el IVE', () => {
  const filas = revisarConsistencia({
    solicitud,
    ive: { primerNombre: 'JUAN', primerApellido: 'PRUEBA', nit: '7777771-2', correo: 'JUAN@ejemplo.test' },
  });
  const r = Object.fromEntries(filas.map((f) => [f.dato, f.resultado]));
  assert.equal(r['Nombre o razón social'], 'coincide');
  assert.equal(r.NIT, 'difiere');
  assert.equal(r.Correo, 'coincide');
  assert.equal(r['Monto solicitado frente al límite de la marca'], 'difiere');
});

test('sin IVE no hay comparación', () => {
  const filas = revisarConsistencia({ solicitud, ive: null });
  assert.ok(filas.slice(0, 3).every((f) => f.resultado === 'sin_dato'));
});

test('alertas de PEP y resolución vencida', () => {
  const alertas = alertasExpediente({
    solicitud,
    ive: { esPEP: 'SI' },
    hoy: new Date('2026-10-06T00:00:00'),
  });
  const textos = alertas.map((a) => a.texto).join(' | ');
  assert.match(textos, /PEP/);
  assert.match(textos, /venció/);
});
