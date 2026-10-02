# ADR-015 — Metadatos de entrega y remitente anónimo

- **Estado:** propuesta. La parte 1 (metadatos de entrega guardados) está pensada para la siguiente versión del relay. La parte 2 (remitente anónimo) espera a las condiciones que enumera. La parte 3 deja escrito lo que no es objetivo.
- **Fecha:** 2026-10-02.
- **Alcance:** qué puede relacionar el relay entre remitentes, buzones y personas, en su base de datos y mientras funciona, y qué reducciones compensan su coste en un realm familiar.

[English version](../../adr/ADR-015-delivery-metadata-and-anonymous-sender.md).

## Contexto

SimpleX Chat está diseñado para que sus servidores no puedan relacionar entre sí las colas de un mismo usuario. Nos preguntamos si Arveil podría hacer lo mismo. Esto es lo que hoy relaciona las cosas, leído del esquema del relay el 02-10-2026:

| Fuente | En la base de datos (robo de la base o de una copia) | Mientras funciona (un operador que instrumenta el relay) |
|---|---|---|
| Dueño de cada buzón | Guardado: `mailboxes.owner_identity`, `owner_device` | Sí |
| Remitente de cada sobre | No se guarda: `envelopes` no tiene columna de remitente | Sí: cada `EnvelopePut` llega por una sesión de miembro ([protocolo §4](../PROTOCOL.md), V1) |
| Destinatarios de un mismo mensaje | **Reconstruibles.** `seq` es un autoincremento común a todo el realm y `expires_at` es la hora de llegada más la caducidad, al segundo. Un mensaje a N dispositivos deja N filas consecutivas con la misma caducidad | Sí: una ráfaga de envíos en una sesión |
| Adjuntos | Quién lo subió y la hora exacta: `blobs.owner_identity`, `created_at` | Quién sube y quién descarga |
| Reclamación de KeyPackages | Solo que un paquete se consumió | Quién reclama el paquete de quién |
| IP y conexiones | El relay no las guarda; un proxy puede registrarlas | Sí |

Hay además una pequeña fuga hacia los miembros: el cursor de descarga es el `seq` de todo el realm, así que un dispositivo puede saber cuánto recibió el realm entero entre dos descargas.

En un realm de cinco a diez personas, un operador que observe tiempos y direcciones IP suele poder reconstruir quién escribe a quién, haga lo que haga el protocolo: hay muy poca gente entre la que esconderse. El diseño de SimpleX funciona en parte porque cada servidor tiene miles de usuarios. También se apoya en colas creadas sin cuenta, un segundo servidor en el camino de envío (enrutado privado) y aislamiento de transporte por cola o Tor, opcionales. Un realm de Arveil funciona por membresía por diseño ([ADR-003](ADR-003-zero-trust-server.md), [ADR-013](ADR-013-realm-administration-from-the-app.md)): sabe quiénes son sus miembros. La pregunta es, por tanto, más acotada: cuánto sabe el realm sobre **quién habla con quién**.

## Decisión (propuesta)

### Parte 1 — Metadatos de entrega guardados (siguiente versión del relay)

La ganancia barata y real está en lo que revela una base de datos o una copia robada.
- **Secuencia por buzón.** Los sobres pasan a una tabla con clave `(mailbox_id, mailbox_seq)` y sin rowid, de modo que el orden físico sigue al buzón y no a la llegada en todo el realm. El cursor que reciben los clientes es la secuencia del buzón.
- **Migración de cursores.** El contador de cada buzón empieza por encima del `seq` más alto del realm en el momento de migrar. Todos los cursores que ya tienen los clientes siguen siendo válidos y no se salta ni se repite nada.
- **Caducidad redondeada.** `expires_at` se redondea hacia abajo al día UTC para duraciones de dos días o más, y a la hora por debajo de eso. El protocolo ya permite una caducidad efectiva más corta, declarada en la respuesta `EnvelopeAccepted`.
- **Blobs.** `created_at` y `expires_at` se redondean igual. `owner_identity` se mantiene porque la cuota por miembro la necesita; queda documentado como residuo.
- **Reparto en orden aleatorio.** El cliente envía las copias de un mensaje en orden aleatorio, para que los dispositivos propios del remitente no vayan siempre primero o último.

Esto no oculta tamaños (el relleno por tramos reduce su precisión) ni los tiempos ante quien observe el relay en directo. Las páginas de SQLite, el WAL y las páginas libres pueden conservar rastros del orden de inserción. El objetivo son las consultas normales y las copias, no resistir un análisis forense.

### Parte 2 — Perfil de remitente anónimo (espera a sus condiciones)

**Diseño.**
- **Sesión anónima.** Un dispositivo puede entregar desde una sesión cuya clave estática Noise es nueva, de un solo uso y desconocida para el realm. Ese tipo de sesión provisional ya existe para canjear invitaciones y vincular dispositivos. Su único permiso nuevo es `EnvelopePut` con una capacidad de escritura válida y un token anónimo.
- **Tokens.** Las sesiones de miembro obtienen lotes de tokens de un solo uso mediante una emisión Privacy Pass ([RFC 9576](https://www.rfc-editor.org/rfc/rfc9576), [RFC 9578](https://www.rfc-editor.org/rfc/rfc9578)). Emisor y verificador son el mismo relay, así que encaja el tipo VOPRF de verificación privada. La emisión se limita por identidad y día. Canjear un token no revela qué miembro lo recibió. Los tokens gastados se guardan por hash hasta que caducan.
- **Una sesión anónima por mensaje.** Las copias de un mensaje comparten sesión anónima. Mientras funciona, el relay sigue viendo que esos buzones recibieron el mismo mensaje, pero no de quién.
- **Bibliotecas.** Hacen falta implementaciones revisadas en Rust para el cliente y en Go para el relay, sin construcciones propias. Mientras no existan con calidad suficiente, esta parte queda bloqueada.

**Qué cambia, sin exagerar.** El proceso del relay deja de recibir la identidad del remitente con cada entrega: registros, métricas, volcados de fallos o un relay modificado para registrar sesiones no la obtienen directamente. Frente a un operador que mire direcciones IP y tiempos aporta poco. El mismo móvil suele tener abierta su sesión de miembro desde la misma dirección en el mismo momento, así que el operador puede emparejar las dos sesiones. El «sealed sender» de Signal tiene el mismo límite.

**Cuándo adoptarlo.** Cualquiera de estos casos:
- se diseñan contactos en otros realms: hoy no puede entregar quien no es miembro del realm de destino, y un perfil anónimo con tokens es la forma natural de permitirlo;
- los realms crecen mucho más allá de una familia;
- una revisión independiente lo pide.

### Parte 3 — Lo que no es objetivo

- **Que no se puedan relacionar los buzones de una persona**, es decir, colas por contacto leídas sin autenticar. Obliga a rehacer la revocación (M2.3 revoca los buzones de un dispositivo por su dueño), las cuotas y los avisos de actividad. La sesión de vigilancia única por dispositivo de la [ADR-014](ADR-014-relay-activity-notices.md) las volvería a relacionar, y sin ocultar las direcciones IP la ganancia desaparece.
- **Ocultar las direcciones IP al realm**, con Tor o con un segundo relay de otro operador como intermediario. Coste alto en batería, latencia y operación, y sigue siendo débil en realms pequeños.

Se reabre si aparecen realms con muchos usuarios sin relación entre sí, si los operadores se federan o si una prueba con usuarios muestra la necesidad. El [modelo de amenazas](../THREAT_MODEL.md) deja escrito que esa desvinculación no es objetivo en realms pequeños, para que nadie la dé por supuesta.

## Qué sabe cada parte

| Parte | Hoy | Tras la parte 1 | Tras la parte 2 |
|---|---|---|---|
| Quien robe la base de datos o una copia | Dueños de los buzones; destinatarios de un mismo mensaje por filas consecutivas y caducidad idéntica; quién subió cada adjunto y a qué hora exacta | Dueños de los buzones; día u hora de llegada por buzón; quién subió cada adjunto | Igual que la parte 1 |
| Operador que instrumenta el relay | Sesión remitente de cada entrega, destinatarios, IP, tiempos | Igual | Destinatarios de un mismo mensaje, IP, tiempos; el remitente solo emparejando IP y tiempos |
| Otros miembros | Volumen de todo el realm entre dos descargas | Solo su propio buzón | Igual que la parte 1 |

## Alternativas

| Alternativa | Motivo para no adoptarla |
|---|---|
| Copiar el modelo de SimpleX: colas anónimas por contacto, enrutado privado, aislamiento de transporte | Rompe revocación, cuotas y avisos, y no protege frente al operador en un realm pequeño sin ocultar las IP |
| Remitente anónimo ya, sin tokens | Sin cuotas anónimas, una sesión sin autenticar podría llenar buzones con solo una capacidad de escritura filtrada |
| Retardos aleatorios en el reparto | Añaden latencia a cada mensaje y solo difuminan tiempos ante un observador en directo; se puede revisar como opción |
| No hacer nada | Deja que una base de datos robada reconstruya quién está en cada grupo |

## Consecuencias

- La parte 1 necesita una migración del relay y un cambio en el cliente (reparto en orden aleatorio); los cursores siguen siendo compatibles.
- Las caducidades efectivas son menos precisas; la retención puede acabar hasta un día antes de lo pedido.
- La parte 2, si se adopta, añade emisión de tokens, registro de tokens gastados, un nuevo tipo de sesión provisional y dos dependencias criptográficas que revisar.
- El modelo de amenazas declara que relacionar los buzones de una persona no se evita en realms pequeños.

## Criterios de aceptación

Parte 1:
1. Tras un mensaje de grupo a N dispositivos, ninguna consulta normal sobre la base de datos o una copia agrupa sus N copias: ni orden común al realm ni caducidad idéntica al segundo.
2. El cursor que recibe un cliente no revela nada de otros buzones.
3. Migración desde una base con `seq` común al realm: todos los cursores de los clientes existentes continúan sin pérdidas ni duplicados.
4. Las horas de los blobs están redondeadas; la columna de quién lo subió se mantiene, documentada.

Parte 2, si se adopta:
5. Una sesión anónima solo puede hacer `EnvelopePut` con una capacidad válida y un token sin gastar.
6. Un token gastado se rechaza y un miembro no puede obtener más del límite diario.
7. Relacionar emisión y canje es imposible bajo las hipótesis del esquema, comprobado con los vectores de prueba y la revisión de la biblioteca.

Referencias: [modelo de amenazas](../THREAT_MODEL.md), [protocolo](../PROTOCOL.md), [ADR-008](ADR-008-carrier-independent-transport.md), [ADR-014](ADR-014-relay-activity-notices.md), [arquitectura Privacy Pass (RFC 9576)](https://www.rfc-editor.org/rfc/rfc9576), [emisión Privacy Pass (RFC 9578)](https://www.rfc-editor.org/rfc/rfc9578).
