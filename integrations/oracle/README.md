# Sincronización Oracle D-6

Este conector reemplaza el Excel de FISO con una extracción interna de solo lectura. No se ejecuta en Vite, Supabase Edge Functions ni el navegador.

Fuente: Oracle `main_fusa.CIE_TRASLADO_MES`, filtro `CLASE = 'D-6'`. Es la fuente canónica de producción mensual según la memoria operativa, sin joins que puedan duplicar fianzas.

## Seguridad

- Cree una cuenta de servicio Oracle exclusiva, con `CREATE SESSION` y `SELECT` únicamente. La contraseña histórica debe rotarse antes de configurarla.
- Guarde los secretos fuera del repositorio, por ejemplo en un `.env` de la carpeta de ejecución protegida.
- El proceso requiere `ORACLE_HOST`, `ORACLE_SID`, `ORACLE_USER`, `ORACLE_PASSWORD`, `SUPABASE_URL` y `SUPABASE_SERVICE_ROLE_KEY`.
- El job escribe únicamente en las tablas privadas `oracle_sync_runs_d6` y `oracle_d6_staging`. Ninguna marca puede leer esas tablas.
- Nunca entregue las credenciales Oracle al frontend ni a usuarios de ADMOSA o UMA.

## Cartera D-6 (clientes, beneficiarios y pólizas)

`cargar_cartera.py` llena el modelo de la app con las columnas del export `d6-consignacion.csv`:

```powershell
$env:SUPABASE_URL="https://<proyecto>.supabase.co"; $env:SUPABASE_SERVICE_ROLE_KEY="<llave de servicio>"
python integrations/oracle/cargar_cartera.py --csv ..\d6-consignacion.csv
```

Escribe en `oracle_d6_staging` (fuente `CARTERA_D6`) y llama `d6_aplicar_cartera_oracle`, que:

- Inserta o actualiza afianzados, beneficiarios, agentes y pólizas por `(fianza, endoso)`.
- Normaliza nombres con dobles espacios.
- Marca los endosos anteriores como reemplazados.
- Respeta las bajas en proceso de la app.
- Devuelve un resumen sin datos personales: beneficiarios sin marca y fianzas emitidas en la app que el export aún no trae.

Se puede correr las veces que haga falta: la segunda corrida actualiza, no duplica.

`--oracle` hace lo mismo leyendo directo de Oracle, pero está bloqueado hasta definir en `SQL_CARTERA_D6` la consulta que reproduce el export y validarla contra él.

## Ejecución

Instale `python-oracledb` en el equipo interno con ruta a Oracle y ejecute:

```powershell
python integrations/oracle/refresh_d6.py --from-year 2025
```

Prográmelo una vez al día en la red interna. La tabla de corridas conserva ventana, conteos, checksum y error resumido. Antes de usarla para cobros, reconcilie cada mes contra el cierre operativo de FISO.

La aplicación conserva la revisión, emisión confirmada, documentos y conciliación como sistema operativo propio. Oracle aporta evidencia de emisión y producción, no reemplaza esas decisiones.
