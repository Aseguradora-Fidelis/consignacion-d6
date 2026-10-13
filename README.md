# Fidelis · Consignación D-6

Portal de las fianzas de consignación comercial (clase D-6). El cliente llena su información, la comparte con sus distribuidores y ve en qué va cada caso. Fidelis recibe todo ordenado en un solo lugar y solo lo consulta: **el equipo no trabaja en la app.** Las decisiones, la emisión, la facturación y los pagos viven en FISO y la app los refleja con la carga diaria de Oracle.

| Quién | Qué hace |
| :--- | :--- |
| Marca (UMA, ADMOSA, Honda, Suzuki, Indy) | Pide el alta con su resolución de crédito, comparte el enlace con su distribuidor, corrige la solicitud y sube documentos hasta que se emite, ve su cartera, pide bajas, reporta incumplimientos y ve sus facturas de FISO con su saldo. |
| Distribuidor | Con un enlace personal llena el formulario IVE, sube sus documentos y acepta la declaración de veracidad. No necesita cuenta. |
| Fidelis (todos los roles internos) | Consulta: solicitudes recibidas con su expediente completo, cartera, bajas pedidas, reclamos, cuenta de cada marca y el cuadre con FISO. |
| Administración | Invita usuarios, asigna roles y marcas, ajusta las tarifas de cotización y revisa la bitácora. |

## Cómo está hecho

- **Frontend:** React 19, Vite, React Router y React Query.
- **Backend:** Supabase (Postgres, Auth, Storage y la Edge Function `admin-usuarios`).
- **Permisos:** viven en Postgres. Cada tabla tiene RLS y las tablas de negocio no admiten escritura directa: lo que escribe el cliente pasa por una RPC que valida y deja rastro (`d6_solicitar_alta`, `d6_alta_guardar_borrador`, `crear_invitacion_ive`, `d6_solicitar_baja`, `d6_reportar_incumplimiento` y las del portal). El personal de Fidelis no tiene funciones que cambien un caso.
- **Navegador:** solo decide qué mostrar (`src/auth/permisos.js`).
- **Una marca nunca ve datos de otra.** Corrige la solicitud de su distribuidor hasta que FISO la emite. Cada cambio queda en `alta_cambios_d6` con quién, cuándo, el valor anterior y el nuevo, y no se puede borrar.
- **Portal del distribuidor:** funciona sin sesión y solo sirve para llenar y enviar su solicitud y subir sus documentos. Quien llega por el enlace no tiene permiso sobre ninguna tabla, vista ni secuencia, y por la API solo ejecuta las 6 funciones del portal (las 5 `portal_ive_*` y `completar_ive_invitacion`), todas atadas a la solicitud de su token. En Storage solo inserta en la ruta que su solicitud reservó por 15 minutos (el chequeo vive en el esquema `d6_privado`, que la API no publica). El servidor guarda la hora, la huella SHA-256 del formulario, la IP, el navegador y la versión de la declaración aceptada. Enviado el formulario, el enlace solo recibe documentos.
- **Estados automáticos:** el distribuidor llena, Fidelis recibe (con los documentos que faltan, calculados con la lista de requisitos) y la solicitud queda emitida cuando la carga de FISO trae una fianza con el mismo NIT del distribuidor, la misma marca y emitida desde que se pidió el alta (`d6_vincular_emisiones_fiso`). Vigencia, contrato y montos vienen de FISO.
- **Cuenta de la marca:** `v_cuenta_marca` agrupa por mes las facturas D-6 de FISO de cada marca (cuotas mensuales, contado para UMA) con su saldo de la última carga. Septiembre 2026 cuadra al centavo contra `FAC_FACTURA`. Los avisos de cobro los manda FISO.
- **Bajas y reclamos:** los inicia la marca. Fidelis los procesa en FISO. La baja aparece procesada cuando FISO cancela la fianza, y el cuadre lista las bajas cuya fecha pasó sin cancelación en FISO.
- **Cotización:** al pedir el alta la marca ve una estimación (tarifa de la marca × monto, 2 % general y 2.25 % UMA, derechos 8 % e IVA 12 %). La prima real es la de FISO.
- **Fechas:** en hora de Guatemala (la base corre con `timezone = America/Guatemala`).

## Desarrollo local

Requisitos: Node 20 o superior, Docker Desktop y Python 3 (solo para la integración con Oracle).

```bash
npm install
npx supabase@latest start
npm run db:reset
npx supabase@latest status -o env
```

Copie `API_URL` y `ANON_KEY` a `.env.local`:

```
VITE_SUPABASE_URL=http://127.0.0.1:55321
VITE_SUPABASE_ANON_KEY=...
```

Luego `npm run dev`. Los usuarios de prueba y su contraseña están al inicio de `supabase/seed.sql`. Todos los datos del seed son ficticios.

## Pruebas

| Comando | Qué cubre |
| :--- | :--- |
| `npm test` | Dominio. La cotización se compara contra las emisiones reales de `../d6-consignacion.csv` cuando el archivo está. También: consistencia del expediente y formulario IVE sincronizado con la validación SQL. |
| `npm run test:db` | Más de 200 pruebas SQL contra la base local. Cubren: aislamiento entre marcas, alta de usuarios, flujo completo del expediente, bajas, cobros con facturas de FISO, cruce con Oracle y, en `remediacion.sql`, cada ataque de la auditoría del 2026-10-08. Cada archivo se revierte. |
| `npm run test:e2e` | Playwright. Flujo completo: la marca solicita, el distribuidor completa el portal, la marca corrige un dato, la carga de FISO trae la fianza y la solicitud queda emitida sola, y el personal solo consulta. |

Corra `npm run db:reset` antes de `test:db` si ya usó la base a mano.

## Despliegue

1. Cree el proyecto en Supabase.
2. Aplique las migraciones con `npx supabase db push`. No cargue `seed.sql` en producción.
3. En Auth:
   - Desactive el registro público (Allow new users to sign up). Deje activo el proveedor Email: si se apaga, nadie puede ingresar.
   - Contraseña mínima de 10 caracteres.
   - Defina la URL del sitio.
   - **SMTP propio (obligatorio):** Authentication > Emails > SMTP Settings (por ejemplo Resend: `smtp.resend.com`, puerto 465, usuario `resend`, la llave como contraseña). Solo se usa para invitar usuarios y recuperar contraseñas. Sin esto el correo de Supabase solo llega al equipo del proyecto y no se puede invitar a las marcas.
4. Despliegue `npx supabase functions deploy admin-usuarios` con el secreto `APP_ORIGIN` (URL pública de la app). Sin él la función no invita.
5. Cree el primer administrador desde el panel de Supabase. Asígnele el rol con `insert into user_role_assignments (user_id, role) values ('<id>', 'admin')`.
6. Cargue la cartera y las facturas desde Oracle (ver Integración con Oracle). Luego asigne en Administración los beneficiarios que queden sin marca: sus facturas no aparecen en la cuenta de ninguna marca y el cuadre las lista.
7. Compile con `npm run build` usando `VITE_SUPABASE_URL` y `VITE_SUPABASE_ANON_KEY` del proyecto hospedado. El `dist/` local apunta a `127.0.0.1` y no sirve para publicar.
8. Publique `dist/` con las cabeceras de `public/_headers` (CSP, HSTS, `frame-ancestors 'none'`, `Referrer-Policy: no-referrer`). Netlify y Cloudflare Pages las leen solas. En otro hosting, IT debe replicarlas.
9. Programe el respaldo diario (sección Respaldos) y haga una restauración de prueba antes de abrir a las marcas.

## Respaldos

El plan gratis no trae respaldos descargables y Storage no entra en un volcado de la base. `scripts/respaldo.mjs` deja una carpeta por día con `esquema.sql`, `datos.sql`, los archivos de `expedientes` y un `manifiesto.json` con la huella de cada archivo:

```bash
node scripts/respaldo.mjs
```

Necesita `SUPABASE_DB_URL`, `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` y `RESPALDO_DIR`, una carpeta fuera del repositorio y fuera de `docs/`. Para restaurar en un proyecto vacío: aplique las migraciones, cargue los datos en una sola transacción y suba los archivos de `expedientes/` al bucket del mismo nombre con la misma ruta:

```bash
psql "$SUPABASE_DB_URL" -1 -v ON_ERROR_STOP=1 -f scripts/restaurar_previo.sql -f <respaldo>/datos.sql
```

`restaurar_previo.sql` vacía los catálogos que cargan las migraciones, que el respaldo también trae. Probado el 2026-10-08 en local: migraciones en limpio, restauración y los mismos conteos en fianzas, facturas, clientes, usuarios y bitácora, con todas las pruebas SQL en verde.

## Integración con Oracle

Ver `integrations/oracle/README.md`.

Todo es de solo lectura hacia Oracle: transacción `READ ONLY` y un guard que rechaza lo que no sea `SELECT`. Programe las dos cargas una vez al día en la red interna, primero la cartera y después las facturas.

- `cargar_cartera.py --oracle` lee `FIA_POLIZA` clase D-6 (último endoso de cada fianza) con el NIT del distribuidor (`VW_FUSA_CONTACTOS`) y llama `d6_aplicar_cartera_fiso`: aplica la cartera, actualiza los NIT y deja emitidas las solicitudes cuya fianza ya llegó. Validada el 2026-10-08 contra `d6-consignacion.csv`: de las 492 fianzas cuyo último endoso no cambió desde el export, coinciden códigos, montos, derechos, IVA y fechas, salvo 4 estados y 1 prima que cambiaron después. `--csv` sigue disponible para cargar un export.
  - Normaliza nombres y marca los endosos reemplazados.
  - Reporta los beneficiarios nuevos sin marca y las fianzas emitidas en la app que Oracle aún no trae.
  - Una corrida sin cambios no escribe nada en la bitácora.
- `cargar_facturas.py` lee `FAC_FACTURA` de las fianzas D-6 (desde el 1 de enero del año anterior) y las aplica con `d6_aplicar_facturas_fiso`. La llave es `CORRELATIVO_UNICO_COBRO`: las notas de cobro pendientes (serie FN) no tienen número de factura y una factura anulada se reemite con el mismo número. Marca como pagadas las fianzas cuya factura tiene fecha de pago.

## Pendientes conocidos

- **Cuenta bancaria de cobro:** la marca no ve todavía a qué cuenta pagar. Falta el dato de Cobros.
- **Preguntas abiertas para el negocio:**
  - Qué incluye ADMOSA.
  - Qué significan los estados NV y E de Oracle.
  - Requisitos de copropiedad.
- **Cerradas el 2026-10-08 con el procedimiento v01 y FISO en vivo:** los endosos se cobran según lo que FISO factura, y uno a 60 meses se factura como una prima anual.
- **Decidido el 2026-10-13:** el documento accesorio y la entrega física no se controlan en la app.
