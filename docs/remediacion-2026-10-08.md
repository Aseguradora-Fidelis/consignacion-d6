# Remediación de la auditoría del 2026-10-08

Rama `remediacion`, sin commit. Migraciones 036 a 042. Corresponde a `auditoria-readiness-2026-10-08.md`.

## Decisiones aplicadas

| Tema | Decisión | Fuente |
| :--- | :--- | :--- |
| Contacto del distribuidor | Correo y celular obligatorios | Samuel, 08-10 |
| Solicitud del distribuidor | La marca la ve y la edita hasta que Suscripción decide, también después del envío. Cada cambio queda registrado campo por campo | Samuel, 08-10 y 09-10 |
| Enlace del IVE | Solo sirve para llenar y enviar la solicitud y subir sus documentos. Ninguna otra función | Samuel, 09-10 |
| Segundo paso (MFA) | No se usa | Samuel, 09-10 |
| Fuente de verdad | FISO. La app es el portal del cliente y Fidelis solo consulta. Estados automáticos, la emisión se reconoce sola por NIT y marca, la cuenta sale de las facturas de FISO. Sin accesorio, sin entrega y sin correos desde la app | Samuel, 13-10 |
| Firma | Sin firma dibujada. Declaración de veracidad con hora, huella SHA-256, IP, navegador y versión del texto | Samuel, 08-10. El procedimiento v01 pide el cuestionario, no una firma |
| Quién decide y emite | Suscripción, como en FISO, donde `USUARIO_AUTORIZACION` está vacío | Procedimiento v01 y FISO |
| Separación de funciones | Comercialización genera y envía el estado de cuenta. Cobros registra el pago. Contabilidad concilia, y quien registra no concilia | Procedimiento v01 |
| Qué se cobra | Las facturas D-6 de FISO del mes (`FAC_FACTURA`), no un cálculo de la app | FISO en vivo, 08-10 18:47 |
| Documento accesorio | Por cliente, sumando todas las marcas | Export: el 99.8 % de las D-6 tiene un solo agente de Oracle |

## Bloqueantes

| # | Bloqueante | Estado | Cómo se comprobó |
| :---: | :--- | :--- | :--- |
| 1 | La marca reescribía el IVE enviado haciéndose pasar por el distribuidor | Cerrado. Con el enlace, una solicitud enviada solo recibe documentos. La marca edita con su propia sesión, y cada cambio queda con su nombre. La huella de lo que envió el distribuidor se conserva | `remediacion.sql`, ataque reproducido |
| 2 | Precarga del IVE por NIT | Se mantiene dentro de la misma marca, sin firma ni declaración | `remediacion.sql` |
| 3 | Un anónimo deducía la exposición | Cerrado. Quien llega por el enlace no tiene permiso sobre ninguna tabla, vista ni secuencia, y por la API solo ejecuta las 6 funciones del portal, antes 40. Comprobado también por HTTP con la llave pública | `remediacion.sql` y pruebas HTTP del 09-10 |
| 4 | Escritura directa sin RPC | Cerrado en altas, fianzas, clientes, documentos, estados de cuenta, bajas y contratos | `remediacion.sql`, `cobros.sql` |
| 5 | Prima sin validar | Cerrado. La app ya no captura prima: la emisión se vincula con FISO y todo viene de la carga | `flujo_expediente.sql` |
| 6 | Doble cobro | Cerrado. Una factura de FISO no entra en dos estados de cuenta. Septiembre 2026 cuadra al centavo: Q214,318.19 en 5 marcas más Q604.80 de un beneficiario sin marca, que el cuadre señala | Carga real de 8,031 facturas |
| 7 | Base en UTC | Cerrado. La base corre en `America/Guatemala` | `remediacion.sql` |
| 8 | Sin avisos ni correo | Cerrado en la app: decisiones, documentos rechazados y estados de cuenta dejan correo en la bandeja, y `enviar-correos` los manda con Resend | `remediacion.sql`. Falta la llave de Resend |
| 9 | Borrados en cascada y sin respaldos | Cerrado. Nada se borra en cascada y la bitácora es inmutable. `scripts/respaldo.mjs` respalda y la restauración dejó los mismos conteos | Restauración local del 08-10 |
| 10 | Migraciones no reproducibles | Cerrado. Las 44 migraciones corren sobre una base vacía y pasan 238 pruebas SQL | `supabase db reset` del 13-10 |
| 11 | Datos reales en el historial de git | **Abierto.** Requiere repo nuevo o reescribir el historial | Decisión de Samuel |
| 12 | Portal atrapaba al distribuidor | Cerrado. Cada campo muestra su error al salir y la lista final dice qué está mal | Revisado en navegador a 375 px |
| 13 | Hosting y cabeceras | Preparado en `public/_headers`. El hosting lo define IT | Pendiente de IT |

Además:

- **Carga de Oracle:** la cartera reproduce el export. De las 492 fianzas sin cambios, coinciden todos los campos salvo 4 estados y 1 prima posteriores al 21-07. Una carga sin cambios no escribe en la bitácora.
- **Dependencias:** xlsx 0.20.3, sin vulnerabilidades en `npm audit`.

## Pruebas

| Comando | Resultado |
| :--- | :--- |
| `npm run test:db` | 238 pruebas, 0 fallas, en base limpia y con la cartera y facturas reales de Oracle |
| `npm test` | 25 de 25 |
| `npm run test:e2e` | 6 de 6: flujo completo con la emisión reconocida sola desde FISO, y recorrido de consulta de cada rol sin acciones |
| `npm run build` | Compila |

## Lo que falta para el piloto

- **Git:** repo nuevo o historial reescrito antes de cualquier remoto.
- **Resend:** la llave y el dominio remitente. Configurar el SMTP del proyecto hospedado.
- **IT:**
  - Definir el hosting.
  - Programar la carga de Oracle (cartera y luego facturas) y el respaldo diario.
- **Administración:** asignar marca a los beneficiarios 58534, 10235 y 202289. Tienen 31 facturas que hoy nadie cobra.
- **Cobros:** pasar la cuenta bancaria que verá la marca.
- **Piloto:** que un distribuidor real complete el portal en su teléfono sin ayuda.
- **"Recordar con el mismo enlace":** no se puede hacer. El enlace se guarda solo como huella, así que recordar genera uno nuevo.
- **Seguimiento con el enlace usado:** se retiró. El enlace solo sirve para llenar la solicitud, y el distribuidor se entera por correo de las decisiones.
