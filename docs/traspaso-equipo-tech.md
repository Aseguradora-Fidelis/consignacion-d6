# Traspaso al equipo de tech (2026-11-03)

Desde hoy el proyecto queda a cargo de tech. Qué es, cómo está y qué falta lo explica el `README.md`. Aquí va solo lo que conviene saber antes de decidir cómo seguir.

## Estado al traspaso

- **Código:** este repositorio. Arranca sin historial: el historial anterior tenía datos reales de clientes y no se publica.
- **Pruebas:** 257 SQL (`npm run test:db`), 25 de la app (`npm test`) y 6 recorridos en navegador (`npm run test:e2e`). Todas en verde al 2026-10-23.
- **Demo local:** corre con `supabase start`, `npm run dev` y los usuarios de `supabase/seed.sql`. La base local de la demo tiene la cartera y las facturas reales de FISO al 2026-11-03, pero esos datos no están en el repositorio. Se cargan con `integrations/oracle/` desde la red interna.
- **Producción:**
  - **Supabase** (`ygjglgdoojkqfbljomdt`, plan gratis): pausado por inactividad. No se puede reactivar porque la cuenta dueña ya tiene 2 proyectos gratis activos. Tiene datos reales: 660 fianzas y 8,031 facturas de FISO. Todavía no tiene usuarios.
  - **Vercel** (`fidelis-consignacion.vercel.app`): publicado desde el repositorio anterior, `sfernandez-fidelis/fidelis-consignacion`.

## Seguridad pendiente en el Supabase actual

1. **Llaves antiguas.** El secreto de la llave de firma antigua (HS256) quedó expuesto en un archivo local, que ya se borró. Con él se pueden fabricar accesos totales. Si el proyecto sigue vivo:
   - Cambiar en Vercel `VITE_SUPABASE_ANON_KEY` por la llave `sb_publishable_`.
   - Después apagar las llaves antiguas (anon y service_role) y revocar la llave de firma.
   - Si el proyecto se abandona, borrarlo, porque tiene datos reales.
2. **Variables de Vercel.** La integración de Supabase creó variables que la app no usa: `POSTGRES_*`, `SUPABASE_JWT_SECRET`, `SUPABASE_SERVICE_ROLE_KEY` y `SUPABASE_SECRET_KEY`. Hay que borrarlas.
3. **Acceso directo a la base.** Está abierto a cualquier IP y lo protege solo la contraseña. La app no lo necesita: limitarlo a la red de la oficina.

La revisión de seguridad del 2026-10-23 está en la migración `045_cierre_pentest.sql`, y cada ataque reproducido está en `supabase/tests/pentest.sql`.

## Si se cambia de base de datos (por ejemplo SQLite)

La seguridad de hoy vive en Postgres, no en el navegador ni en un servidor propio. Cambiar de motor significa rehacer en un servidor de aplicación lo siguiente:

- **Aislamiento entre marcas:** RLS en cada tabla. UMA y ADMOSA son competidores y ninguna puede ver datos de la otra.
- **Escritura:** solo por funciones que validan y dejan rastro (`d6_*`, `portal_ive_*`). Ninguna tabla de negocio admite escritura directa.
- **Portal del distribuidor:** funciona sin cuenta. Lo resuelve un token de 256 bits guardado como hash, que solo da acceso a las 6 funciones del portal y a la ruta de Storage reservada para su solicitud.
- **Bitácoras:** `audit_log` y `alta_cambios_d6` no se pueden modificar ni borrar.
- **Auth y archivos:** usuarios, contraseñas, recuperación de contraseña y el bucket `expedientes`.

Las pruebas de `supabase/tests/` describen cada una de estas reglas y sirven como especificación para la nueva versión, aunque estén escritas en SQL de Postgres.

## Reglas que no cambian con el motor

- **Oracle `main_fusa`:** solo lectura. Las cargas abren una transacción `READ ONLY` y rechazan lo que no sea `SELECT`.
- **FISO es la fuente de verdad.** La app no decide, no emite y no cobra: muestra lo que FISO trae y ordena el expediente del cliente.
- **Datos en el repositorio:** nunca subir datos reales de clientes ni la lista de contactos.
- **Pendientes de negocio:** ver el final del `README.md`. Entre ellos, los beneficiarios 58534, 10235 y 202289 siguen sin marca, y falta la cuenta bancaria de cobro.
