# ADR-012 — Códigos QR y enlaces para unirse, vincular y añadir contactos

- **Estado:** propuesta. Nada de lo que describe está implementado.
- **Fecha:** 2026-09-27.
- **Alcance:** cómo se une una persona a un realm, cómo vincula otro de sus dispositivos y cómo añade un contacto sin copiar cadenas largas entre apps; y cómo verificar un contacto pasa a ser un paso aparte y opcional. La administración del realm desde la app es la [ADR-013](ADR-013-realm-administration-from-the-app.md).

[English version](../../adr/ADR-012-qr-codes-and-links.md).

## Contexto

Su mantenedor probó la primera beta de principio a fin: un Mac con la identidad y un teléfono Android por vincular, con WhatsApp para pasar los códigos de uno a otro. El teléfono no llegó a vincularse. Los tres flujos comparten un coste: cada uno mueve a mano, a través de otra app, una cadena hexadecimal larga.

**Vincular un dispositivo** ([Protocolo §8](../PROTOCOL.md#8-añadir-retirar-y-recuperar-dispositivos), M3.1):
- El dispositivo nuevo muestra `arveil-pair:v1:…`, de 242 caracteres y sin botón de copiar. La persona lo lleva al dispositivo de administración.
- Antes de [#117](https://github.com/Ulzuhan/arveil/pull/117), el dispositivo nuevo dejaba de escuchar a los 90 segundos mientras su pantalla seguía contando diez minutos. El dispositivo de administración esperaba después sus propios 90 segundos y fallaba, y el código quedaba gastado. Cada reintento consumía una de las cuatro citas que una dirección puede abrir cada diez minutos.
- El dispositivo nuevo tiene que pegar además la cadena `arveil-bootstrap:v0:…` del realm. Ninguna pantalla de la app la muestra; solo el log del relay.
- El dispositivo de administración firma y publica la credencial nueva y el manifiesto en cuanto termina el handshake, **antes** de que nadie compare los números. La comparación solo decide si el dispositivo nuevo aplica la concesión. Si el código se sustituye por el camino, el dispositivo sustituto queda autorizado y la discrepancia aparece después; revocarlo exige la CLI.

**Unirse a un realm** ([Protocolo §3](../PROTOCOL.md#3-bootstrap-del-realm-e-identidad)):
- Una persona nueva recibe dos cadenas: el bootstrap, de unos 245 caracteres, y una invitación de 64 caracteres que solo se puede crear en el servidor del relay.

**Añadir un contacto** ([Protocolo §4](../PROTOCOL.md#4-verificación-de-contactos-y-rutas), M3.2):
- Una persona comparte `arveil-route:v1:…`, de 406 caracteres.
- El número de seguridad se calcula en local a partir de las dos raíces, así que quien compartió su ruta no ve ningún número hasta tener también la ruta del otro.
- La app exige «Hemos comparado los números» antes de crear una conversación. En la práctica el flujo se queda ahí, o se marca la casilla sin comparar. Una verificación que no ocurrió es peor que un «sin verificar» honesto.
- La conversación que crea se acepta sola en el otro lado, sin ninguna solicitud.

El diseño ya contaba con los QR: [Protocolo §3](../PROTOCOL.md#3-bootstrap-del-realm-e-identidad) y §8, el punto F1 del [diseño del cliente](../CLIENT_DESIGN.md) y el riesgo abierto del [modelo de amenazas](../THREAT_MODEL.md) según el cual «un QR decorativo no autentica el canal».

Qué hacen mensajeros comparables:
- **Vincular:** Signal, WhatsApp, Matrix y las passkeys escanean un QR de una pantalla con la cámara del otro dispositivo.
- **Altas:** los servidores reparten un único enlace o QR, con caducidad y número de usos. Ejemplos son los tokens de registro de Matrix, los QR de cuenta de Delta Chat y los enlaces de un solo uso de SimpleX.
- **Contactos:** Signal, WhatsApp, Threema, Matrix y SimpleX dejan hablar antes de verificar. Muestran el estado de verificación, avisan cuando cambia una clave y ofrecen verificar escaneando en persona o comparando números después. En Delta Chat un escaneo verifica a los dos lados.

## Principios

1. **Entre dos dispositivos que la persona tiene delante, un código viaja por la cámara, no por otra app.**
2. **Cuando tiene que viajar a distancia, es un único enlace `https`.** Su secreto va en el fragmento de la URL, que los navegadores no envían a ningún servidor.
3. **Conectar y verificar son pasos distintos.** La verificación es visible y opcional. Escanear en persona verifica.
4. **Ningún dispositivo queda autorizado antes de que la persona lo confirme en la pantalla que lo autoriza.**
5. **Pegar siempre funciona.** Cubre los dispositivos sin cámara, el permiso de cámara denegado y la accesibilidad.

## Decisión (propuesta)

### 1. Una carga, tres usos

Una carga es CBOR determinista `{version, kind, …}`, codificado en base64url sin relleno. Los tipos son `join`, `link` y `contact`. La misma carga puede viajar de tres formas:
- **como código QR** del enlace completo, en modo byte con corrección de errores M;
- **como enlace:** `https://arveil.kaicorplabs.com/<tipo>#<carga>`;
- **pegada:** la app acepta el enlace o la carga sola.

Cada carga lleva el bootstrap del realm al que pertenece: la clave de firma del realm, su clave Noise y una URL de endpoint. El cliente calcula `realm_id` a partir de la clave de firma en lugar de fiarse de uno copiado. Las cargas de más de 600 bytes se rechazan antes de analizarlas. El cliente nunca descarga el enlace; lo analiza en local.

Las cadenas antiguas (`arveil-bootstrap`, invitación en hexadecimal, `arveil-pair:v1`, `arveil-route:v1`) se siguen aceptando al pegarlas hasta que una versión posterior las retire.

### 2. Unirse: `join`

`{version, kind: "join", realm_signing_key, realm_noise_key, url, invitation}`, donde `invitation` es el token de 32 bytes.
- `arveil-relay invite` imprime el enlace y un QR en la terminal junto al token. La base del enlace se configura con `-link-base`.
- Una invitación creada en la app ([ADR-013](ADR-013-realm-administration-from-the-app.md)) puede llevar también el contacto de quien invita (§4). Al unirse, la persona nueva ya tiene una conversación con quien la invitó.
- La invitación es de un solo uso y de vida corta, como hoy. Si alguien canjea antes un enlace interceptado, la persona invitada ve «invitación ya usada» y quien administra ve quién la canjeó. Ser admitido no da acceso a los mensajes ni a las claves de nadie ([ADR-003](ADR-003-zero-trust-server.md), [ADR-005](ADR-005-cryptographic-identity.md)).

### 3. Vincular un dispositivo: `link`, iniciado por el dispositivo que tiene la raíz

Los papeles se invierten. Empieza el dispositivo que tiene la raíz; el dispositivo nuevo escanea.

1. **El dispositivo de administración abre la cita.** En «Vincular un dispositivo» llama a `pair_begin` desde su sesión de miembro; la trama y sus límites no cambian. Después genera una clave X25519 de un solo uso para esta vinculación y muestra una carga `link` como QR, con un botón de compartir y una cuenta atrás: `{version, kind: "link", claves del realm, url, pair_id, capability, responder_key}`.
2. **El dispositivo nuevo la escanea** en «Vincular con mi otro dispositivo», o abre el enlace. Conoce así el realm y la clave del respondedor, sin pegar nada. Crea sus claves de dispositivo y es el iniciador Noise `IK` hacia `responder_key`. El mensaje 1 lleva sus cuatro claves públicas y una descripción opcional de sí mismo, como «Pixel 8 · Android 15»; la descripción se muestra, pero nunca se da por cierta.
3. **Las dos pantallas muestran el mismo número corto**, derivado del hash del handshake como hoy. El dispositivo de administración pregunta «¿Vincular Pixel 8?» y muestra el número.
4. **Solo cuando la persona confirma allí**, el dispositivo de administración firma la credencial y el manifiesto N+1, los publica y deja la concesión en la última ranura.
5. **Cuándo confirma el dispositivo nuevo depende de cómo recibió la carga.**
   - Si la leyó con la cámara, aplica la concesión en cuanto llega. Ya autenticó la clave del respondedor a la vista, e `IK` la vincula.
   - Si llegó por un enlace o al pegarla, la carga cruzó otro canal, así que el dispositivo nuevo también pide a la persona que confirme el número antes de aplicar la concesión.

Consecuencias:
- El realm no puede responder por su cuenta. La clave del respondedor nunca llega al realm, y el mensaje 1 no se puede construir sin ella.
- Quien fotografíe el QR y responda antes se queda la ranura de escritura única. El dispositivo nuevo auténtico falla entonces de forma visible, y el dispositivo de administración muestra un dispositivo que la persona no reconoce. No se firma nada que la persona no confirme.
- Todas las citas las abre ahora un miembro. Cuando no queden clientes anteriores a este cambio, `pair_begin` se podrá rechazar en las sesiones provisionales. Eso elimina la única superficie de escritura sin autenticar del protocolo.
- Un Mac sin cámara recibe el enlace por AirDrop, Mensajes o cualquier otro canal. La confirmación en las dos pantallas cubre ese camino.
- Las tramas y los límites del relay no cambian. El flujo `arveil-pair:v1` sigue funcionando durante una versión.

### 4. Contactos: `contact`, primero conectados y verificados cuando se quiera

`{version, kind: "contact", claves del realm, url, campos de ruta, secret}`.
- Los campos de ruta son los de `arveil-route:v1`: identificador de dispositivo, hash de credencial, clave raíz, buzón, capacidad de escritura y clave HPKE.
- `secret` son 16 bytes aleatorios que recuerda el dispositivo que muestra la tarjeta.

**Dos formas de compartir:**
- **«Mostrar mi código»** enseña un QR para usar en persona. Su secreto vale mientras la pantalla está abierta y como mucho diez minutos, y una sola vez.
- **«Compartir mi contacto»** crea un enlace con la hoja de compartir del sistema. Su secreto vale 30 días y se puede revocar.

**Abrir una tarjeta.** La persona ve de quién es y «Empezar a hablar». No hay comparación obligatoria. La app crea la conversación, y su primer mensaje es un evento de aplicación MLS nuevo, `hello {secret}`. Los clientes antiguos descartan los tipos que no conocen, así que es un cambio aditivo.

**Recibir.**
- Una conversación creada por alguien que no es un contacto llega como **solicitud**: «Ana quiere hablar contigo (usó tu enlace del 12 de septiembre)», con Aceptar y Rechazar. Un secreto desconocido o caducado también produce una solicitud, marcada con «no usó ninguno de tus enlaces».
- Una conversación de un contacto se acepta directamente, y sus miembros aparecen en sus detalles.
- Esto sustituye la aceptación silenciosa de hoy y sigue el [Protocolo §5](../PROTOCOL.md#5-grupos-mls-keypackages-y-autorización), según el cual la lista de miembros se presenta al usuario.

**Estados de verificación:**
- **Sin verificar** es el estado por defecto, y se muestra en la cabecera y los detalles de la conversación.
- **Verificado en persona** requiere un escaneo. El lado que escanea leyó la raíz de la pantalla del otro, así que marca verificado a ese contacto. El lado que mostró el código marca verificado a quien escaneó cuando su `hello` devuelve el secreto en persona dentro del canal de extremo a extremo.
- **Verificado comparando** se alcanza desde los detalles de la conversación en cualquier momento. Los dos lados tienen ya las dos raíces, así que los dos ven el mismo número, y uno puede escanear el código del otro si se ven más adelante.
- La verificación sigue siendo una propiedad de la raíz, como en M3.2. Si cambia la raíz de un contacto verificado, aparece un aviso y hay que verificar de nuevo.

**Qué debe vincular la tarjeta.** Una tarjeta vale lo que valga el vínculo entre sus campos de ruta y su raíz. Antes de que una conversación use una tarjeta, el cliente comprueba las claves de dispositivo que nombra contra una credencial de dispositivo firmada por la raíz, como exige el [Protocolo §5](../PROTOCOL.md#5-grupos-mls-keypackages-y-autorización). El KeyPackage reclamado para ese dispositivo debe coincidir con la misma credencial. Hoy no se comprueba así ni `arveil-route:v1` ni la reclamación del KeyPackage. Esa revisión se sigue por separado y es requisito previo de esta sección.

**Para familias (pregunta abierta):** una lista de «Personas en este servidor» a la que cada miembro se apunta si quiere, con los nombres de la [ADR-011](ADR-011-shared-display-names.md).

### 5. Las páginas de enlace

`arveil.kaicorplabs.com` sirve `/join`, `/link` y `/contact` como páginas estáticas en inglés y español.
- Las páginas no cargan nada de terceros y usan una política de seguridad de contenidos estricta con `Referrer-Policy: no-referrer`. Sus metadatos de vista previa son genéricos.
- **Android.** La app declara esas rutas como [App Links](https://developer.android.com/training/app-links) verificados. La web publica `/.well-known/assetlinks.json` con el nombre del paquete y el SHA-256 del certificado de publicación. Con la app instalada, Android la abre directamente y la página ni siquiera se carga.
- **macOS.** Los enlaces universales necesitan un Apple Developer ID, que el proyecto no tiene. La app registra en su lugar el esquema `arveil:`, y la página ofrece un botón «Abrir en Arveil». Su pequeño script en línea copia el fragmento en una URL `arveil://`.
- **Sin la app,** la página explica cómo instalarla (el APK o `brew install --cask arveil`) y ofrece un botón para copiar el enlace. El campo de pegar de la app lo acepta.
- **Otros relays.** Un relay que lleve otra persona puede apuntar `-link-base` a su propia página. Android solo abre la app directamente para el dominio que la app declara; en los demás casos siguen funcionando el botón o pegar el enlace.

### 6. Cámara y bibliotecas de QR

- La cámara solo se abre después de pulsar «Escanear», como ya exige el punto F1 del diseño del cliente. Si se deniega el permiso, queda el campo de pegar.
- **Android** declara `CAMERA`.
- **macOS** añade el entitlement del sandbox `com.apple.security.device.camera` y una descripción de uso.
- Generar un QR es algo pequeño y determinista, y puede vivir en el núcleo Rust.
- El lector es una dependencia nueva, y su elección pasa una revisión de la cadena de suministro:
  - `mobile_scanner` usa ML Kit en Android, cuyo modelo integrado no es de código abierto, y AVFoundation en macOS;
  - un lector basado en zxing-cpp es de código abierto por completo.
  - En cualquier caso, el lector debe funcionar sin conexión y no enviar nada.

## Qué aprende cada parte

| Parte | Aprende | No aprende |
|---|---|---|
| El realm | Que un miembro abrió una cita, como hoy aprende del dispositivo de administración; que se creó una conversación | Claves del respondedor, secretos, nombres ni si una conversación empezó desde una tarjeta |
| El servidor web | Que alguien visitó `/join`, `/link` o `/contact` (IP y hora); las vistas previas de enlaces descargan la página sin el fragmento | El fragmento: invitaciones, capacidades, claves o secretos |
| El canal usado para un enlace (WhatsApp, Mensajes…) | El enlace, igual que las cadenas de hoy; puede guardarlo en sus copias de seguridad | Nada de lo que la app hace con él |

El enlace lleva un secreto al portador, como las cadenas de hoy. Las mitigaciones son un solo uso y una vida corta para invitaciones y vinculaciones, una vida limitada y la revocación para los enlaces de contacto, y el paso de solicitud para los contactos. La capacidad de escritura de una tarjeta es de larga duración, como la de la ruta hoy: quien la tiene puede dejar sobres en ese buzón, pero no leerlos.

## Alternativas

| Alternativa | Motivo para no adoptarla |
|---|---|
| Mantener los códigos de texto y solo añadir botones de copiar y compartir | Siguen siendo dos o tres pegados a través de otras apps; la única autenticación de una vinculación sigue siendo que el código llegue intacto |
| Que el dispositivo nuevo muestre el QR y lo escanee el de administración, como en Signal y WhatsApp | El dispositivo nuevo necesitaría el bootstrap del realm antes de mostrar nada, y el dispositivo de administración suele ser un Mac, donde escanear un teléfono es incómodo |
| Códigos cortos tecleados con un PAKE (como Magic Wormhole) | Buenos sin cámara, pero son una construcción criptográfica y una dependencia nuevas; la confirmación en las dos pantallas ya cubre ese camino |
| Verificación obligatoria antes del primer mensaje | Es el diseño actual. Detiene el flujo o enseña a marcar una casilla sin comparar |
| Solo enlaces propios `arveil://`, sin página web | Las apps de mensajería no los hacen pulsables, así que una invitación a distancia volvería a ser texto que copiar |
| Enlaces universales en macOS | Requieren un Apple Developer ID |

## Consecuencias

- **Cliente:** un lector, un generador de QR, App Links en Android y el esquema `arveil:` en macOS; los papeles de la vinculación invertidos; solicitudes de contacto; la verificación en los detalles de la conversación.
- **Protocolo:** un tipo de evento MLS nuevo (`hello`) y la regla de que la autorización sigue a la confirmación. El relay solo gana `-link-base` y los enlaces impresos.
- **Web:** las tres páginas de enlace y `assetlinks.json`, desplegadas con el sitio.
- **Se eliminan:** la casilla «Hemos comparado los números» y la aceptación silenciosa de conversaciones iniciadas por desconocidos.
- **Arreglos que salen antes:** el orden entre autorización y confirmación y el vínculo de las rutas con credenciales firmadas por la raíz son arreglos por sí mismos. No deben esperar al resto de esta decisión.

## Criterios de aceptación

1. **Vinculación.** Un teléfono se vincula a un Mac escaneando la pantalla del Mac, sin copiar ni pegar texto. La credencial se publica solo después de que la persona confirme en el Mac. Un segundo dispositivo que compite con una fotografía del QR es visible, y no recibe autorización salvo que se confirme.
2. **Alta.** Una persona se une a un realm con un solo enlace o QR. La invitación no aparece en ningún log del servidor web ni del relay.
3. **Contactos.**
   - Escanear en persona conecta a dos personas y marca a ambas como verificadas con un solo escaneo.
   - Compartir un enlace las conecta sin verificar, y quien lo recibe ve una solicitud.
   - Las dos ven el mismo número en los detalles de la conversación.
4. **Cadenas antiguas.** Siguen funcionando al pegarlas.
5. **Cámara.** No se pide hasta pulsar «Escanear». Denegarla deja disponible el pegado.
6. **Páginas de enlace.** No cargan recursos de terceros ni envían referrer. Con la app instalada en Android, pulsar un enlace abre la app directamente.
7. **Clientes antiguos.** Un cliente sin este cambio que recibe un evento `hello` sigue funcionando y no guarda nada.

## Preguntas abiertas

- Qué biblioteca de lectura usar, tras su revisión de la cadena de suministro.
- Si la capacidad de escritura de larga duración de una tarjeta debería pasar a ser una capacidad aparte y revocable por tarjeta.
- Si ofrecer la lista de «Personas en este servidor», y quién puede verla.
- Si los enlaces de relays que no son del proyecto deberían usar por defecto el dominio del proyecto.
