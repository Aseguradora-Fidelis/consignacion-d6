import test from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import {
  DERIVADOS, REQUERIDOS_SERVIDOR, SECCIONES_INDIVIDUAL, SECCIONES_JURIDICA, datosIniciales, derivar, pendientesPorSeccion,
  prellenadoDesdeMarca, rangoIve, validarFormulario,
} from '../src/domain/formularioIve.js';

const requeridosEn = (secciones) => new Set(secciones.flatMap((s) => s.campos.filter((c) => c.requerido && !c.cuando).map((c) => c.id)));

// Lee la lista del servidor directamente de la migracion para que no se desincronicen.
function requeridosSql(tipo) {
  const carpeta = new URL('../supabase/migrations/', import.meta.url);
  const sql = readdirSync(carpeta).sort().reverse().map((f) => readFileSync(new URL(f, carpeta), 'utf8'))
    .find((s) => s.includes('FUNCTION public.validar_datos_ive_d6'));
  const marcador = tipo === 'INDIVIDUAL' ? "IN ('IVE-IR-01', 'IVE-ASS-01')" : "IN ('IVE-IR-02', 'IVE-ASS-02')";
  const bloque = sql.slice(sql.indexOf(marcador));
  const lista = bloque.match(/ARRAY\[([^\]]+)\]/)[1];
  return lista.match(/'([^']+)'/g).map((s) => s.replace(/'/g, ''));
}

for (const tipo of ['INDIVIDUAL', 'JURIDICA']) {
  test(`el formulario ${tipo} pide todo lo que exige el servidor`, () => {
    const formulario = requeridosEn(tipo === 'INDIVIDUAL' ? SECCIONES_INDIVIDUAL : SECCIONES_JURIDICA);
    assert.deepEqual(REQUERIDOS_SERVIDOR[tipo].sort(), requeridosSql(tipo).sort());
    for (const campo of requeridosSql(tipo)) {
      if (tipo === 'INDIVIDUAL' && DERIVADOS.includes(campo)) continue;
      assert.ok(formulario.has(campo), `falta ${campo} como obligatorio en el portal`);
    }
  });
}

test('un formulario vacío muestra errores en cada obligatorio', () => {
  const errores = validarFormulario('INDIVIDUAL', datosIniciales('INDIVIDUAL'));
  for (const campo of ['primerNombre', 'dpi', 'telefono', 'correo', 'esPEP', 'declaracionVeracidad']) {
    assert.ok(errores[campo], `sin error para ${campo}`);
  }
  // Sin firma dibujada: basta la declaración de veracidad.
  assert.equal(errores.firmaImagen, undefined);
});

test('el detalle PEP solo se exige si responde que sí', () => {
  const base = datosIniciales('INDIVIDUAL');
  assert.equal(validarFormulario('INDIVIDUAL', { ...base, esPEP: 'NO' }).pepDetalle, undefined);
  assert.ok(validarFormulario('INDIVIDUAL', { ...base, esPEP: 'SI' }).pepDetalle);
});

test('valida formato de DPI y correo', () => {
  const errores = validarFormulario('INDIVIDUAL', { ...datosIniciales('INDIVIDUAL'), dpi: '123', correo: 'no-es-correo' });
  assert.match(errores.dpi, /13/);
  assert.ok(errores.correo);
});

test('los datos iniciales llevan el tipo de formulario correcto', () => {
  assert.equal(datosIniciales('JURIDICA').tipoIve, 'IVE-ASS-02');
  assert.equal(datosIniciales('INDIVIDUAL', { primerNombre: 'ANA' }).primerNombre, 'ANA');
});

test('persona individual pide cada dato una vez y conserva vivienda y PEP estandar', () => {
  const campos = SECCIONES_INDIVIDUAL.flatMap((s) => s.campos);
  const ids = campos.map((c) => c.id);
  assert.equal(new Set(ids).size, ids.length, 'hay campos repetidos');
  assert.equal(SECCIONES_INDIVIDUAL.length, 5);
  const porId = Object.fromEntries(campos.map((c) => [c.id, c]));
  assert.match(porId.esPEP.label, /Persona Expuesta Políticamente \(PEP\)/);
  assert.match(porId.contratistaEstado.label, /Contratista o Proveedor del Estado \(CPE\)/);
  for (const id of ['tipoVivienda', 'tiempoResidir', 'pagoVivienda', 'poseeVehiculo', 'prestamos', 'tiendas']) assert.ok(porId[id], `falta ${id}`);
  for (const id of ['ingresosMensuales', 'egresosMensuales', 'empresaNombre', 'tipoGestion', 'lugarFirma']) assert.equal(porId[id], undefined, `${id} se pregunta dos veces`);
});

test('los datos deducidos llenan lo que exige el servidor', () => {
  const d = derivar('INDIVIDUAL', { fuenteIngresos: 'NEGOCIO_PROPIO', lugarTrabajo: 'Moto Partes', salarioActual: '30000', otrosIngresos: '25000', gastosMensuales: '9000' });
  assert.equal(d.cargoTrabajo, 'Propietario');
  assert.equal(d.ingresosMensuales, '50,000.01 a 100,000.00');
  assert.equal(d.egresosMensuales, '3,000.01 a 10,000.00');
  assert.equal(d.empresaNombre, 'Moto Partes');
  assert.equal(rangoIve(3000), '0.00 a 3,000.00');
});

test('lo que escribe la marca llega al formulario una sola vez', () => {
  const p = prellenadoDesdeMarca({ tipoPersona: 'INDIVIDUAL', nombres: 'Luis Eduardo', apellidos: 'Pérez López', dpi: '1234567890101', nit: '1234567', telefono: '55554444', correo: 'a@b.test' });
  assert.deepEqual(p, { primerNombre: 'Luis', segundoNombre: 'Eduardo', primerApellido: 'Pérez', segundoApellido: 'López', dpi: '1234567890101', nit: '1234567', telefono: '55554444', correo: 'a@b.test' });
  const faltan = pendientesPorSeccion('INDIVIDUAL', { ...datosIniciales('INDIVIDUAL'), ...p });
  assert.ok(!faltan[0].faltan.some((x) => ['primerNombre', 'dpi', 'nit', 'telefono', 'correo'].includes(x.id)));
});
