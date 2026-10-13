// Recorrido completo del portal del cliente (migracion 044): la marca pide el alta, el
// distribuidor llena y envia por el portal, la marca corrige un dato y lo ve en el registro, la
// fianza llega en la carga de FISO y la app la reconoce sola por el NIT del distribuidor, la marca
// ve la solicitud emitida y Suscripcion solo la consulta.
// Usuarios y contrasena de prueba: supabase/seed.sql.
import { execSync } from 'node:child_process';
import { expect, test } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';

const CLAVE = 'Prueba2026local';
const PDF = Buffer.from('%PDF-1.4\n1 0 obj<</Type/Catalog>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF');
const sufijo = Date.now().toString().slice(-6);
const NOMBRES = 'ANA LUCIA';
const APELLIDOS = `E2E ${sufijo}`;
const AFIANZADO = `${NOMBRES} ${APELLIDOS}`;
const FIANZA = `97${sufijo}`;
// NIT propio de esta corrida: es la llave con la que la app reconoce la fianza de FISO.
const NIT = `88${sufijo}-1`;

async function ingresar(page, correo) {
  await page.goto('/ingresar');
  await page.getByLabel('Correo electrónico').fill(correo);
  await page.getByLabel('Contraseña').fill(CLAVE);
  await page.getByRole('button', { name: 'Ingresar', exact: true }).click();
  await expect(page.getByRole('complementary', { name: 'Navegación principal' })).toBeVisible({ timeout: 30_000 });
}

// Llave de servicio de la base local, solo para simular la carga de FISO. Se toma de
// `npx supabase status -o env` salvo que venga en SUPABASE_SERVICE_ROLE_KEY.
function baseDeServicio() {
  let url = process.env.SUPABASE_URL || 'http://127.0.0.1:55321';
  let llave = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!llave) {
    const env = execSync('npx -y supabase@latest status -o env', { encoding: 'utf8', timeout: 180_000 });
    const valor = (nombre) => env.match(new RegExp(`^${nombre}="?([^"\r\n]+)"?`, 'm'))?.[1];
    llave = valor('SERVICE_ROLE_KEY');
    url = valor('API_URL') || url;
  }
  if (!llave) throw new Error('No se encontro SERVICE_ROLE_KEY en npx supabase status -o env');
  return createClient(url, llave, { auth: { persistSession: false, autoRefreshToken: false } });
}

// Simula la carga diaria de FISO: el contacto del distribuidor trae el NIT que el escribio, llega
// la fianza emitida hoy para la misma marca, y la app reconoce la emision por NIT, marca y fecha.
async function cargarFianzaDeFiso(db, afianzado, numero, nit) {
  const { data: sol, error } = await db.from('solicitudes_alta')
    .select('id,cliente_id,beneficiario_id,monto_solicitado,ive_data')
    .eq('cliente_nombre_tmp', afianzado).single();
  if (error) throw error;
  if (!sol.cliente_id) throw new Error('La solicitud no tiene distribuidor');
  expect(sol.ive_data?.nit).toBe(nit);
  const { error: e1 } = await db.from('clientes').update({ nit }).eq('id', sol.cliente_id);
  if (e1) throw e1;
  // Fecha de hoy en UTC: la emision debe ser del mismo dia o posterior a la solicitud.
  const hoy = new Date().toISOString().slice(0, 10);
  const [a, m, d] = hoy.split('-').map(Number);
  const hasta = new Date(Date.UTC(a + 1, m - 1, d - 1)).toISOString().slice(0, 10);
  const { error: e2 } = await db.from('fianzas').insert({
    fianza: Number(numero), endoso: 0, cliente_id: sol.cliente_id, beneficiario_id: sol.beneficiario_id,
    fecha_emision: hoy, vigencia_desde: hoy, vigencia_hasta: hasta,
    monto_afianzado: Number(sol.monto_solicitado),
    status: 'VIGENTE', operational_status: 'VIGENTE',
    contrato_numero: `Escritura E2E ${numero}`, contrato_fecha: hoy,
  });
  if (e2) throw e2;
  const { data: emitidas, error: e3 } = await db.rpc('d6_vincular_emisiones_fiso');
  if (e3) throw e3;
  expect(emitidas).toBeGreaterThanOrEqual(1);
  const { data: despues } = await db.from('solicitudes_alta').select('estado_operativo').eq('id', sol.id).single();
  expect(despues.estado_operativo).toBe('EMITIDA');
}

async function salir(page) {
  await page.getByRole('button', { name: 'Cerrar sesión' }).click();
  await expect(page).toHaveURL(/ingresar/);
}

let servicio;
test.beforeAll(() => {
  test.setTimeout(200_000);
  servicio = baseDeServicio();
});

test('alta de punta a punta', async ({ page, browser }) => {
  // 1. La marca solicita el alta. Correo y celular del distribuidor son obligatorios.
  await ingresar(page, 'marca@uma.test');
  await page.getByRole('link', { name: 'Altas', exact: true }).click();
  await page.getByRole('link', { name: 'Solicitar alta' }).click();
  await page.getByLabel('Nombres', { exact: true }).fill(NOMBRES);
  await page.getByLabel('Apellidos', { exact: true }).fill(APELLIDOS);
  await page.getByLabel('DPI (CUI)').fill('1234567890123');
  await page.getByLabel('Celular (WhatsApp)').fill('55551111');
  await page.getByLabel('Correo', { exact: true }).fill(`e2e${sufijo}@ejemplo.test`);
  const empresa = page.getByLabel('Empresa de su grupo que entrega la mercadería');
  if (await empresa.count()) await empresa.selectOption({ index: 1 });
  await page.getByLabel('Monto de la fianza (Q)').fill('120000');
  await expect(page.getByText('Costo estimado de la fianza')).toBeVisible();
  await expect(page.getByText(/documento accesorio/i)).toHaveCount(0);
  await page.getByLabel('Número de la carta o nota').fill(`RES-E2E-${sufijo}`);
  await page.getByLabel('Fecha', { exact: true }).fill('2026-10-01');
  await page.getByRole('button', { name: 'Crear solicitud' }).click();
  await expect(page.getByRole('heading', { name: 'Solicitud creada' })).toBeVisible();
  const enlace = await page.getByLabel('Enlace del portal').inputValue();

  // La solicitud aparece con el distribuidor llenando.
  await page.getByRole('button', { name: 'Ver el avance' }).click();
  await expect(page.getByRole('list', { name: 'Avance de la solicitud' })).toBeVisible();
  await expect(page.getByText('El distribuidor está llenando').first()).toBeVisible();
  await salir(page);

  // 2. El distribuidor, sin sesion, completa el portal. Lo que escribio la marca llega precargado.
  const contexto = await browser.newContext({ locale: 'es-GT' });
  const portal = await contexto.newPage();
  await portal.goto(enlace);
  await expect(portal.getByRole('heading', { name: /Su fianza con/ })).toBeVisible();
  const siguiente = () => portal.getByRole('button', { name: 'Siguiente', exact: true }).click();

  // Sus datos
  await expect(portal.getByLabel('Primer nombre', { exact: true })).toHaveValue('ANA');
  await portal.getByLabel('NIT', { exact: true }).fill(NIT);
  await portal.getByLabel('Fecha de nacimiento').fill('1990-01-15');
  await portal.getByLabel('Género').selectOption('F');
  await portal.getByLabel('Estado civil').selectOption('Soltero(a)');
  // Un DPI con formato malo muestra su error al salir del campo, sin esperar al envio.
  await portal.getByLabel('DPI (CUI)').fill('123');
  await portal.getByLabel('DPI (CUI)').blur();
  await expect(portal.getByText('El DPI/CUI debe ser un número de exactamente 13 dígitos.')).toBeVisible();
  await portal.getByLabel('DPI (CUI)').fill('1234567890123');
  await siguiente();

  // Donde vive
  await portal.getByLabel('Dirección de su casa').fill('1a calle 1-11 zona 1');
  await portal.getByLabel('Municipio', { exact: true }).fill('Mixco');
  await portal.getByLabel('Departamento', { exact: true }).selectOption('Guatemala');
  await siguiente();

  // Su negocio e ingresos
  await portal.getByLabel('Nombre de su negocio').fill('Motos Ana');
  await portal.getByLabel('Ingreso mensual aproximado (Q)').fill('20000');
  await portal.getByLabel('Gastos mensuales aproximados (Q)').fill('7000');
  await siguiente();

  // Referencias
  await portal.getByLabel('Nombre de un familiar').fill('Luis E2E');
  await portal.getByLabel('Teléfono', { exact: true }).fill('55552222');
  await siguiente();

  // Preguntas de ley
  for (const pregunta of ['esPEP', 'parientePEP', 'asociadoPEP', 'contratistaEstado', 'actuaTercero']) {
    await portal.locator(`input[name="${pregunta}"][value="NO"]`).check();
  }
  await portal.getByRole('button', { name: 'Ir a documentos' }).click();

  const obligatorios = portal.locator('.doc').filter({ hasNotText: '(si aplica)' });
  const total = await obligatorios.count();
  expect(total).toBeGreaterThanOrEqual(7);
  for (let i = 0; i < total; i += 1) {
    await obligatorios.nth(i).locator('input[type=file]').last().setInputFiles({ name: `doc-${i}.pdf`, mimeType: 'application/pdf', buffer: PDF });
    await expect(obligatorios.nth(i).getByText('Recibido')).toBeVisible();
  }
  await portal.getByRole('button', { name: 'Revisar y enviar' }).last().click();

  // Sin firma dibujada: basta la declaracion de veracidad.
  await expect(portal.getByRole('heading', { name: 'Declaración de veracidad' })).toBeVisible();
  await portal.locator('.check input[type=checkbox]').check();
  await portal.getByRole('button', { name: 'Enviar a Fidelis' }).click();
  await expect(portal.getByRole('heading', { name: 'Solicitud enviada' })).toBeVisible();
  await contexto.close();

  // 3. La marca ve la solicitud recibida por Fidelis y corrige el formulario ya enviado. No puede
  // dejar vacio un obligatorio y cada cambio queda en el registro con su correo.
  await ingresar(page, 'marca@uma.test');
  await page.goto('/altas');
  await page.getByRole('link', { name: AFIANZADO }).click();
  await expect(page.getByText('Recibida por Fidelis').first()).toBeVisible();
  await page.getByRole('link', { name: 'Corregir datos y documentos' }).click();
  await expect(page.getByText('Puede corregir los datos hasta que la fianza se emita en FISO. Cada cambio queda registrado con su nombre.')).toBeVisible();
  await page.getByRole('button', { name: /Referencias/ }).click();
  const familiar = page.getByLabel('Nombre de un familiar');
  await expect(familiar).toHaveValue('Luis E2E');
  await familiar.fill('');
  await expect(page.getByText('Sin guardar. Corrija los datos marcados.')).toBeVisible();
  await expect(page.getByText('Este dato es obligatorio.')).toBeVisible();
  await familiar.fill('Luis Corregido E2E');
  await expect(page.getByText(/^Guardado a las/)).toBeVisible();
  await page.getByRole('link', { name: 'Solicitud', exact: true }).click();
  const registro = page.locator('#registro-cambios');
  const fila = registro.getByRole('row').filter({ hasText: 'Luis Corregido E2E' });
  await expect(fila).toContainText('marca@uma.test');
  await expect(fila).toContainText('Después del envío');
  await expect(fila).toContainText('Luis E2E');

  // 4. Llega la carga de FISO con la fianza emitida y la app la reconoce sola.
  await cargarFianzaDeFiso(servicio, AFIANZADO, FIANZA, NIT);
  await page.reload();
  await expect(page.getByText('Emitida en FISO').first()).toBeVisible();
  await expect(page.getByRole('link', { name: FIANZA })).toBeVisible();
  await expect(page.getByText(`Escritura E2E ${FIANZA}`)).toBeVisible();
  await expect(page.getByRole('link', { name: 'Corregir datos y documentos' })).toHaveCount(0);
  await page.goto(`/cartera?buscar=${FIANZA}&estado=`);
  await expect(page.getByRole('link', { name: FIANZA })).toBeVisible();
  await salir(page);

  // Otra marca no la ve.
  await ingresar(page, 'marca@admosa.test');
  await page.goto(`/cartera?buscar=${FIANZA}&estado=`);
  await expect(page.getByText('No hay fianzas con esos filtros')).toBeVisible();
  await salir(page);

  // 5. Suscripcion consulta el expediente completo y no tiene botones de decision.
  await ingresar(page, 'suscripcion@fidelis.test');
  await page.getByRole('link', { name: 'Solicitudes de alta' }).click();
  await page.getByRole('tab', { name: /Emitidas en FISO/ }).click();
  await page.getByRole('link', { name: AFIANZADO }).click();
  await expect(page.locator('.lateral').getByText('Emitida en FISO')).toBeVisible();
  await expect(page.locator('.lateral').getByRole('link', { name: FIANZA })).toBeVisible();
  await expect(page.getByText('Solo de consulta.', { exact: false })).toBeVisible();
  await expect(page.getByText('Coincide').first()).toBeVisible();
  await expect(page.getByRole('button', { name: /Descargar expediente/ })).toBeVisible();
  await page.getByRole('tab', { name: 'Registro de cambios' }).click();
  await expect(page.getByRole('cell', { name: 'Luis Corregido E2E' })).toBeVisible();
  await page.getByRole('tab', { name: /Documentos/ }).click();
  await expect(page.locator('.doc-archivos').first()).toBeVisible();
  await page.getByRole('tab', { name: 'Formulario IVE' }).click();
  await expect(page.getByText('Aceptó la declaración de veracidad')).toBeVisible();
  for (const accion of [/Aprobar/, /Iniciar revisión/, /Vincular/, /Pedir información/, /Suspender/, /No elegible/, /^Aceptar$/, /^Rechazar$/, /Generar enlace/]) {
    await expect(page.getByRole('button', { name: accion })).toHaveCount(0);
  }
  await expect(page.getByRole('link', { name: /Corregir datos|Capturar datos/ })).toHaveCount(0);
  // El menu no ofrece pedir altas ni trabajar el cierre.
  await expect(page.getByRole('link', { name: 'Solicitar alta' })).toHaveCount(0);
  await expect(page.getByRole('link', { name: 'Cierre del mes' })).toHaveCount(0);
});
