// Cada pagina que queda abre sin errores para la marca y para el personal, y el personal no
// tiene acciones que cambien un caso. Usuarios de prueba: supabase/seed.sql.
import { expect, test } from '@playwright/test';

const CLAVE = 'Prueba2026local';

async function ingresar(page, correo) {
  await page.goto('/ingresar');
  await page.getByLabel('Correo electrónico').fill(correo);
  await page.getByLabel('Contraseña').fill(CLAVE);
  await page.getByRole('button', { name: 'Ingresar', exact: true }).click();
  await expect(page.getByRole('complementary', { name: 'Navegación principal' })).toBeVisible({ timeout: 30_000 });
}

async function sinErrores(page, ruta) {
  await page.goto(ruta);
  await page.waitForLoadState('networkidle');
  await expect(page.getByText('No se pudo cargar la información'), ruta).toHaveCount(0);
  await expect(page.getByText('Esta pantalla tuvo un problema'), ruta).toHaveCount(0);
  await expect(page.getByText('No tiene acceso a esta sección'), ruta).toHaveCount(0);
}

const PAGINAS_MARCA = ['/', '/cartera', '/distribuidores', '/altas', '/bajas', '/reclamos', '/pagos', '/condiciones', '/glosario'];
const PAGINAS_PERSONAL = [...PAGINAS_MARCA, '/afianzados', '/cuadre'];

test('la marca recorre sus paginas y abre un mes de sus pagos', async ({ page }) => {
  await ingresar(page, 'marca@uma.test');
  for (const ruta of PAGINAS_MARCA) await sinErrores(page, ruta);
  await page.goto('/pagos?estado=');
  await expect(page.getByRole('heading', { name: 'Pagos a Fidelis' })).toBeVisible();
  const mes = page.locator('table a.principal-celda').first();
  if (await mes.count()) {
    await mes.click();
    await expect(page.getByRole('heading', { name: /Facturación de/ })).toBeVisible();
    await expect(page.getByText(/Saldo según FISO al|Todavía no llega el saldo/)).toBeVisible();
    await expect(page.getByText('No se pudo cargar la información')).toHaveCount(0);
  }
  await expect(page.getByRole('button', { name: /Generar|Enviar a la marca/ })).toHaveCount(0);
});

for (const correo of ['suscripcion@fidelis.test', 'cobros@fidelis.test', 'comercializacion@fidelis.test', 'admin@fidelis.test']) {
  test(`${correo} solo consulta`, async ({ page }) => {
    await ingresar(page, correo);
    for (const ruta of PAGINAS_PERSONAL) await sinErrores(page, ruta);
    for (const accion of [/Solicitar alta/, /Generar estados de cuenta/, /Pedir baja/, /Reportar incumplimiento/, /^Aprobar$/, /^Rechazar$/, /Cerrar baja/, /Editar/]) {
      await expect(page.getByRole('button', { name: accion })).toHaveCount(0);
      await expect(page.getByRole('link', { name: accion })).toHaveCount(0);
    }
    await page.goto('/pagos?estado=');
    const mes = page.locator('table a.principal-celda').first();
    if (await mes.count()) {
      await mes.click();
      await expect(page.getByRole('heading', { name: /Facturación de/ })).toBeVisible();
      await expect(page.getByText('No se pudo cargar la información')).toHaveCount(0);
    }
    await page.goto('/cartera?estado=ACTIVAS');
    const fianza = page.locator('table a.principal-celda').first();
    if (await fianza.count()) {
      await fianza.click();
      await expect(page.getByRole('heading', { name: /Fianza / })).toBeVisible();
      await expect(page.getByRole('button', { name: /Pedir baja|Reportar incumplimiento|Registrar entrega|accesorio/i })).toHaveCount(0);
      await expect(page.getByRole('link', { name: 'Renovar' })).toHaveCount(0);
    }
    if (correo === 'admin@fidelis.test') await sinErrores(page, '/admin');
  });
}
