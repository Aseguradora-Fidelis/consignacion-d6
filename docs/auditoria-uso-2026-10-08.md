# Auditoría de uso: Fianzas de consignación D-6

Fecha: 8 de octubre de 2026. Versión revisada: rama `producto-operativo`, commit `c62c796`.

Cómo se hizo: se usó la aplicación de punta a punta como lo haría cada persona, con la versión compilada y datos reales de cartera en un ambiente local.

1. ADMOSA pidió el alta de un distribuidor nuevo desde una laptop.
2. El distribuidor abrió el enlace en un teléfono, llenó las 9 partes del formulario, subió sus documentos, firmó y envió.
3. Suscripción revisó los documentos, aprobó y emitió.
4. Se revisaron la cartera, las bajas, los reclamos y la cuenta por cobrar de la marca, y el cierre del mes, el cuadre y los perfiles del lado de Fidelis.

## Resultado general

El recorrido completo funciona: la marca pide, el distribuidor llena, Suscripción decide y emite, y la fianza aparece en la cartera de la marca.

Lo que más frena hoy no es técnico sino de lenguaje y de diseño del proceso:

- **Todo o nada:** el distribuidor no puede enviar nada hasta tener los 7 documentos.
- **Lenguaje de aseguradora:** marcas y distribuidores ven palabras como afianzado, alta, expediente, beneficiario o endoso, que no son suyas.
- **Dato que falta:** la app casi nunca reconoce a un distribuidor que ya es cliente de Fidelis.

### Corregido durante la auditoría

| Problema | Efecto | Estado |
| :--- | :--- | :--- |
| Las reglas de seguridad por marca se evaluaban fila por fila | La portada de la marca tardaba más de 8 segundos y la base cancelaba la consulta | Corregido. La cartera de una marca bajó de 3.2 s a 47 ms. Mismas reglas de acceso, 150 pruebas pasan |
| En el teléfono la barra superior se salía de la pantalla | El selector de marca quedaba de 26 px, inservible | Corregido. Ninguna pantalla se sale de lado |
| Pedir baja ofrecía fechas posteriores al vencimiento | Una fianza que vence el 10/10 ofrecía cancelar el 31/10 | Corregido. Avisa que basta con no renovar |
| El botón de WhatsApp no usaba el teléfono del distribuidor | La marca tenía que buscar el contacto a mano | Corregido. Abre el chat y el mensaje dice qué documentos preparar y cuándo vence |
| La alerta de documento accesorio se duplicaba al emitir | El expediente decía "exige accesorio" y la fianza "no se exige" | Corregido |
| Aprobar avisaba de documentos pendientes solo al confirmar | La analista llenaba el diálogo para nada | Corregido. El aviso aparece antes |

## Hallazgos por persona

Nivel: **Bloquea** impide terminar o da un resultado equivocado. **Confunde** se puede terminar pero con dudas o con trabajo de más. **Pulir** detalle.

### La marca (ADMOSA, UMA)

| Nivel | Hallazgo | Propuesta |
| :--- | :--- | :--- |
| Bloquea | Al pedir un alta, "Beneficiario de la fianza" ofrece 5 opciones casi iguales de Central Americana. Son duplicados que vienen de Oracle | Unificar los beneficiarios duplicados y no mostrar el campo cuando la marca tiene uno solo. Si tiene varias razones sociales, mostrar nombres claros |
| Confunde | No hay botón para renovar. Una fianza que vence en 2 días solo ofrece "Pedir baja". Renovar está escondido en Solicitar alta | Botón "Renovar" en la fianza y en "Vencen pronto", con el formulario precargado |
| Confunde | "Cuenta por cobrar" es la cuenta de Fidelis. Para la marca es lo que debe pagar. Tampoco dice a qué banco ni a qué cuenta pagar | Llamarlo "Pagos" o "Lo que debo" y mostrar los datos bancarios y la referencia |
| Confunde | Solo puede generar un enlace nuevo, que anula el anterior. No ve cuánto lleva llenado el distribuidor | Mostrar el avance (partes llenas, documentos subidos, última actividad) y un botón "Recordar al distribuidor" que reenvía el mismo enlace |
| Confunde | El correo del distribuidor es obligatorio. Muchos distribuidores solo usan WhatsApp | Pedir correo o celular, cualquiera de los dos |
| Pulir | En reclamos la marca ve "Recuperado" y "En recobro", que son gestiones de Fidelis con el distribuidor | Ocultarlos en la vista de la marca |
| Pulir | Ve "Endoso 4", "Código del afianzado", "registro de FISO" | Ocultar o traducir (ver vocabulario) |

### El distribuidor (portal)

| Nivel | Hallazgo | Propuesta |
| :--- | :--- | :--- |
| Bloquea | "Continuar a firma" no se habilita hasta subir los 7 documentos. Quien llenó todo pero no tiene un papel a mano no puede enviar nada | Permitir enviar con documentos pendientes (ver solicitudes a medias) |
| Bloquea | Le pide la "Resolución de crédito de la marca", que es un documento de UMA o ADMOSA y que él no tiene | Que la marca la suba al pedir el alta, o que Fidelis la reciba por su lado |
| Confunde | La primera pantalla dice "Expediente", "Afianzado" y el código ALT. No explica qué es la fianza, cuánto tarda ni qué preparar | Pantalla de bienvenida: qué es, 15 a 20 minutos, lista de documentos, "puede avanzar por partes" |
| Confunde | "Estado patrimonial firmado" no dice qué es ni cómo se hace. En uno de los casos de referencia viene sellado por perito contador | Formato descargable y una línea de ayuda |
| Confunde | "Estados financieros, solo si su RTU indica régimen sobre utilidades" deja la decisión al distribuidor | Que lo decida Suscripción al revisar el RTU y lo pida si hace falta |
| Confunde | Después de enviar, el enlace muere. No sabe en qué va ni qué sigue | El mismo enlace muestra el estado: recibido, en revisión, falta algo, aprobado, firma del contrato |
| Pulir | El formulario tiene 9 partes. Vehículo, empresas propias y directorio de tiendas son opcionales pero se ven igual que lo obligatorio | Marcar las partes opcionales y dejar saltarlas |

### Suscripción y personal de Fidelis

| Nivel | Hallazgo | Propuesta |
| :--- | :--- | :--- |
| Bloquea | Solo 21 de 532 clientes tienen NIT en la app. La carga desde Oracle no lo trae. Por eso un distribuidor que ya es cliente aparece como "cliente nuevo, Q0 con todas las marcas" y la regla del accesorio de Q300,000 puede escaparse | Traer NIT y DPI de MG_CONTACTOS en la carga nocturna y buscar al cliente con el NIT y DPI que el distribuidor pone en su formulario |
| Confunde | Doble captura: se emite en FISO y después se vuelve a escribir el número, el contrato y las fechas en la app | A corto plazo, que la carga de FISO complete la emisión sola con el número. A largo plazo, integración con FISO |
| Confunde | Revisar documentos es abrir cada uno en otra pestaña y aceptarlo uno por uno | Visor al lado de la lista y "Aceptar todos los que revisé" |
| Confunde | La portada dice "Cuenta por cobrar Q0.00, nada vencido" junto a "Mora de más de 60 días: 140". Una cifra sale de la app y la otra de Oracle | Decir de dónde sale cada cifra o mostrar solo la de Oracle hasta que la app genere todos los estados de cuenta |
| Confunde | 57 % de los afianzados salen en riesgo medio, sobre todo por IVE vencido (61 %). Si casi todo es alerta, nada es alerta | Separar "actualizar IVE" (trámite) de riesgo de crédito |
| Pulir | "Vencen pronto" no tiene acción: no se puede avisar a la marca ni iniciar la renovación | Botón para avisar a la marca o renovar |

### General

- **Glosario aislado:** existe, pero no aparece junto a los términos. Conviene un signo de ayuda al lado de cada palabra técnica.
- **Rendimiento:** con la versión compilada, la cartera completa carga en 0.9 segundos. La lentitud que se nota al probar en modo desarrollo no es la del producto.

## Vocabulario propuesto

Fidelis puede seguir usando sus términos por dentro. Hacia afuera se usa el lenguaje de quien contrata.

| Hoy | Para la marca | Para el distribuidor |
| :--- | :--- | :--- |
| Afianzado | Distribuidor | Usted |
| Alta / solicitud de alta | Nueva fianza | Su solicitud |
| Baja | Cancelar fianza | No aplica |
| Expediente | Solicitud | Sus datos y documentos |
| Beneficiario | Oculto, es la marca | La marca |
| Endoso | Modificación, o se oculta | No aplica |
| Prima, derechos e IVA | Costo de la fianza | No aplica |
| Resolución de crédito | Aprobación de la marca | No aplica |
| Suscripción | Fidelis | Fidelis |
| Cuenta por cobrar | Pagos | No aplica |
| Vigencia | Válida del ... al ... | Válida del ... al ... |
| FISO | Oculto | Oculto |

## Solicitudes a medias

La idea central: que nadie tenga que tener todo para empezar. Cada solicitud lleva una lista de pendientes con su responsable (marca, distribuidor o Fidelis). La solicitud avanza con lo que hay.

1. **El distribuidor envía lo que tiene.** Llena el formulario y sube los documentos que tenga. Los que falten quedan como pendientes con el mismo enlace, sin generar uno nuevo. Suscripción empieza a revisar datos y referencias mientras llega el resto.
2. **La marca pide el alta sin la resolución.** Puede iniciar con nombre y celular para que el distribuidor arranque mientras la marca termina su análisis de crédito. La resolución se adjunta después y la emisión no ocurre sin ella.
3. **Pendientes visibles para todos.** Cada solicitud muestra qué falta, quién lo debe y desde cuándo. La marca ve el avance de su distribuidor. Fidelis ve en la portada los pendientes por responsable.
4. **Recordatorios automáticos.** Por WhatsApp o correo a los 2 y 5 días de un pendiente, y aviso a la marca si el distribuidor no avanza.
5. **Aprobación con condiciones.** Suscripción aprueba y deja condiciones pendientes (contrato firmado, documento accesorio, pago en el caso de UMA). La fianza se emite pero no se entrega hasta cumplirlas. El control de entrega con accesorio ya funciona así y se generaliza.
6. **Captura desde papel.** Cuando la información llega escaneada, como en uno de los casos de referencia, el personal sube el papel y llena el formulario por el cliente. Cada campo puede quedar marcado como "no lo trae" en lugar de en blanco.

## Otras ideas

- **Renovación en un clic** desde "Vencen pronto", con todo precargado. Solo se piden los estados de cuenta nuevos.
- **Estado de la solicitud para el distribuidor** con el mismo enlace.
- **Lectura automática de documentos:** leer el DPI, el RTU, la patente y el recibo para precargar datos y cruzar nombre, NIT y dirección. Ahorra tiempo a Suscripción, pero hay que validarlo bien antes de confiar en él.
- **Avisos de vencimiento** a la marca 60, 30 y 15 días antes.
- **Pago con tarjeta en línea** para las marcas que entregan la fianza pagada (UMA).
- **Firma electrónica del contrato** de consignación.

## Orden sugerido

| Cuándo | Qué |
| :--- | :--- |
| Antes de compartir el enlace de prueba | Vocabulario hacia afuera. Beneficiarios duplicados. Pantalla de bienvenida del portal. Quitar la resolución de la marca de los documentos del distribuidor |
| Primeras dos semanas | Envío con pendientes y lista de pendientes. Avance visible para la marca. Botón Renovar. Datos bancarios en Pagos. NIT y DPI desde Oracle |
| Después | Recordatorios automáticos. Estado de la solicitud para el distribuidor. Visor de documentos. Aprobación con condiciones. Captura desde papel |
| Más adelante | Lectura automática de documentos. Integración con FISO. Pago en línea. Firma electrónica |
