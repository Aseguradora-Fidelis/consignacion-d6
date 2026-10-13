# Diagnóstico de preparación: Fianzas de consignación D-6

Fecha: 8 de octubre de 2026. Versión revisada: rama `producto-operativo`, commit `384ead1` (incluye la migración 035).

Cómo se hizo: seis auditores especializados revisaron la app en paralelo contra la base local. Los ataques y las escrituras se probaron dentro de transacciones que se revirtieron. Nada se probó contra un proyecto hospedado ni contra Oracle.

## Resultado

**No está lista para producción con marcas reales. Nota global: 5/10.**

El camino feliz funciona y la base técnica es seria. Todas las tablas tienen RLS y el encabezado de marca no se puede falsificar. Pasan las 166 pruebas SQL y las 33 de dominio, y las 111 emisiones del CSV cuadran al centavo. Lo que falta está en el control: quién puede leer y cambiar qué, qué queda registrado y qué pasa con el dinero cuando algo se sale del camino feliz.

| Área | Nota | Lo que la sostiene | Lo que la baja |
| :--- | :---: | :--- | :--- |
| Supabase | 7 | RLS en 33 de 33 tablas, Storage privado, Oracle en solo lectura | Sin SMTP ni respaldos. Migraciones 028 a 035 nunca aplicadas en limpio |
| Recorrido del usuario | 6 | El expediente compartido funciona de punta a punta | Ningún aviso sale de la app. El distribuidor no ve nada después de enviar |
| UX | 6 | Borrador en el servidor, teclados y autocompletado correctos | El distribuidor queda atrapado si un DPI o NIT está mal |
| UI | 6 | Contraste AA en todos los textos, nada se sale de pantalla en 20 capturas | Verde detrás de texto, objetivos táctiles de 34 px, sin modo oscuro |
| Ciberseguridad | 5 | Token de 256 bits con hash, Storage y roles resistieron | La marca lee y reescribe el IVE enviado |
| Seguridad de la información | 4 | Pagos solo por RPC, separación UMA y ADMOSA probada | Escritura directa sin RPC, sin cuatro ojos, bitácora incompleta |
| Trazabilidad de datos | 4 | `numeric(15,2)` y cálculo correcto de emisiones | Estados de cuenta editables sin rastro, doble cobro, prima sin validar |

## Bloqueantes

Ordenados por riesgo. "Probado" significa que se reprodujo contra la base local.

| # | Bloqueante | Evidencia | Corrección |
| :---: | :--- | :--- | :--- |
| 1 | La marca puede generar un enlace nuevo con el expediente ya enviado. Con él lee el IVE completo (DPI, ingresos, PEP, firma) y lo puede reescribir. La bitácora lo atribuye al distribuidor | Probado. `035_documentos_pendientes.sql:174,189,86`. Ingresos cambiados de 20000 a 1 | La marca solo regenera enlaces en BORRADOR o IVE_PENDIENTE. El portal no devuelve `ive_data` después del envío. Cambios posteriores quedan como versión nueva |
| 2 | Con solo un NIT, la marca obtiene precargado el IVE anterior del cliente | Probado. `035:58` | Quitar la precarga o pedir antes DPI y un código de un solo uso |
| 3 | Un anónimo deduce la exposición total del cliente con todas las marcas, competencia incluida | Probado. 26 llamadas a `d6_requiere_documento_accesorio` dieron el valor real. 40 funciones son ejecutables por anon | Revocar EXECUTE a PUBLIC y anon salvo las funciones `portal_*` |
| 4 | Comercial, Suscripción y Cobros escriben directo en `solicitudes_alta`, `fianzas` y `estados_cuenta_d6` sin pasar por RPC | Probado. Estado enviado rebajado en Q1,000 sin fila en la bitácora. Derechos en -5.00. `020:275,293,384,394` | Quitar las políticas UPDATE y FOR ALL y dejar solo las RPC. Trigger de auditoría en estados de cuenta |
| 5 | La prima no se valida en el servidor. La pantalla deja editar prima, derechos e IVA por separado sin registrar el ajuste | `030:208-303`, `AltaDetalle.jsx:531,581` | Recalcular en `emitir_fianza_d6` y exigir motivo para cualquier ajuste |
| 6 | Una fianza se puede cobrar en dos meses si una carga de Oracle cambia su fecha de emisión. El cuadre no avisa | Probado. Total de Q2,721.60 a Q5,443.20, 0 alertas. `030:785-794` | Unicidad de `fianza_id` entre estados de cuenta |
| 7 | La base corre en UTC. Lo emitido después de las 18:00 de Guatemala queda con fecha del día siguiente, y el cierre de mes se corre | `show timezone` = UTC, uso de `CURRENT_DATE` | Fechas de negocio en `America/Guatemala` |
| 8 | Ningún aviso sale de la app. Sin SMTP propio no se puede invitar a UMA ni a ADMOSA ni recuperar contraseñas | `admin-usuarios/index.ts:60`, `Ingresar.jsx:40`. Avisos solo en la tabla `notificaciones` | SMTP (Resend u otro) y correos para rechazo, aprobación y estado de cuenta |
| 9 | Borrados en cascada destruyen expediente, pagos y decisiones. El plan gratis no trae respaldos y Storage no entra en ellos | `002_tables.sql:20,175,193`, `020:278,296` | Baja lógica, `RESTRICT` y `pg_dump` más copia del bucket programados. Conservación de 5 años |
| 10 | Las migraciones 028 a 035 se aplicaron a mano. Nadie ha comprobado que las 35 corran sobre un proyecto vacío | `schema_migrations` llega a 027 | `supabase db reset` en limpio y después `npm run test:db` |
| 11 | El historial de git tiene nombres reales de clientes y unos 610 registros con NIT | Commits `f7f9b3f` y `4aa0258`. Hoy no hay remoto | Repo nuevo o historial reescrito antes de cualquier remoto |
| 12 | En el teléfono, un DPI o NIT inválido no marca error en su parte y deja "Enviar a Fidelis" deshabilitado sin decir qué corregir | Probado en pantalla. `FormularioExpediente.jsx:253,362` | Validar al salir del campo y nombrar el error en cada parte |
| 13 | No hay hosting definido. `dist/` apunta a `127.0.0.1` y no hay CSP, HSTS ni `Referrer-Policy` con el token en `?t=` | `index.html`, `vite.config.js` | Elegir hosting con IT, cabeceras y recompilación con el entorno de producción |

## Decisiones que no son técnicas

Estas preguntas frenan las correcciones. Para cada una va una recomendación.

| Pregunta | Por qué importa | Recomendación |
| :--- | :--- | :--- |
| ¿Correo obligatorio, o correo o celular? | La memoria del 08-10 dice "correo o celular" (034). La 035 vuelve a exigir correo y cita una "decisión del 2026-10-08". Las altas creadas solo con celular ya no pueden recibir un enlace | Correo o celular, y el enlace por WhatsApp cuando no hay correo |
| ¿Puede la marca ver el borrador IVE del distribuidor? | La decisión del expediente compartido (033) choca con "la marca no lee el IVE" y con el aviso del portal | La marca llena y ve solo lo que ella aporta. PEP, ingresos y DPI quedan solo del distribuidor. Confirmar con Cumplimiento |
| ¿Acepta la IVE un IVE-IR-01 o IVE-IR-02 con firma electrónica simple? | La firma es una imagen dibujada sin evidencia (hash, IP, hora del servidor). Hoy además se precarga la firma de una solicitud anterior | Confirmar con Cumplimiento. Mientras tanto, no precargar la firma y guardar la evidencia |
| ¿Quién puede aprobar y emitir el mismo caso? | Hoy una sola persona de Suscripción solicita, revisa, aprueba y emite | Quien aprueba no emite sobre un monto a definir con Suscripción |
| ¿Cómo se facturan los endosos? | 257 de 275 endosos con prima traen derechos e IVA en 0 en el export. Solo 7 de 269 cuadran | Validar con Cobros antes del primer estado de cuenta con endosos |

## Orden propuesto

| Fase | Contenido | Cierra |
| :--- | :--- | :--- |
| 1. Control de datos | Bloqueantes 1 a 7 y 11. Cuatro ojos y auditoría de roles, documentos y tarifas | Seguridad, cumplimiento y trazabilidad |
| 2. Operación | Bloqueantes 8 a 10 y 13. Bitácora que no crezca en cada carga de Oracle: hoy serían unos 600 MB al año, contra 500 MB del plan | Supabase y despliegue |
| 3. Experiencia | Bloqueante 12. Estado del expediente después de enviar, Renovar, Recordar con el mismo enlace, vocabulario hacia la marca, accesibilidad y prueba e2e actualizada (hoy busca textos que ya no existen) | Recorrido, UX y UI |

## Criterio para un piloto con una marca

La app puede salir a piloto con una sola marca cuando se cumpla todo esto:

1. Las fases 1 y 2 están cerradas, y se reprodujeron como prueba SQL los ataques de los bloqueantes 1 a 6.
2. Las 35 migraciones corren en limpio sobre un proyecto vacío y pasan todas las pruebas.
3. Hay un respaldo restaurado con éxito al menos una vez.
4. Cumplimiento respondió las preguntas de la tabla anterior.
5. Un distribuidor real completó el portal en su teléfono sin ayuda.

## Límites de este diagnóstico

- Nada se probó contra Supabase hospedado: rate limits, correo, respaldos y región salen de lo que se sabe del plan gratis.
- No hubo acceso a Oracle, y la consulta que reproduce `d6-consignacion.csv` sigue sin validarse.
- Lo legal no es asesoría legal. Debe confirmarlo Cumplimiento.
- Durante la auditoría otra sesión hizo commit de la 035 (`384ead1`). La primera corrida de pruebas SQL falló por ese cruce y la segunda pasó completa.
- En la base local quedó la solicitud de prueba "ANA LUCIA AUDITORIA" (UMA, Q120,000), creada para probar el portal.
- El `.env` local, que no está versionado, apunta a un Supabase hospedado con `VITE_ENABLE_DEMO_MODE=true`.
