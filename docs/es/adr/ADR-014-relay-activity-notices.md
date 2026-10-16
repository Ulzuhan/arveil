# ADR-014 — Avisos de actividad desde el relay

- **Estado:** propuesta.
- **Fecha:** 2026-10-02.
- **Alcance:** cómo sabe un dispositivo que su buzón tiene algo mientras Arveil no está en pantalla, en Android y macOS, sin Google, sin una segunda app y sin un segundo servidor. Sustituye al receptor experimental ntfy/UnifiedPush de Android descrito en [adjuntos y notificaciones](../CLIENT_FILES_NOTIFICATIONS.md) y al aviso M3.4 del [protocolo](../PROTOCOL.md).

[English version](../../adr/ADR-014-relay-activity-notices.md).

## Contexto

Lo que existe el 02-10-2026:
- **Relay (M3.4).** Un dispositivo puede registrar una URL http(s) con `NotifyHintSet`. Cuando su buzón pasa de vacío a ocupado, el relay envía un POST con `arveil-hint/v1`: un intento de cinco segundos, sin reintentos, y cualquier respuesta HTTP cuenta como enviada.
- **Android (PR #141, experimental en las betas 5 y 6).** Esa URL pertenece a un servidor ntfy propio. El móvil necesita la app ntfy de F-Droid como distribuidor UnifiedPush, y la persona escribe la dirección del servidor ntfy en **Ajustes → Notificaciones**. Arveil comprueba que el endpoint pertenece a ese servidor y rechaza ntfy.sh.
- **macOS.** Sin push. Con «Mantener Arveil en segundo plano», el perfil abierto sincroniza cada diez segundos.

Los problemas:
1. **Tres piezas más para un solo dato.** Un servidor ntfy, la app ntfy y UnifiedPush, para decir algo que el relay ya sabe: este buzón tiene correo.
2. **Una pregunta que nadie debería tener que responder.** Se pide a la persona una dirección que conoce el operador y que no tiene nada que ver con su identidad.
3. **Peticiones salientes desde el relay.** El relay hace POST a URLs que le dan los dispositivos. Limitar destinos, direcciones resueltas y redirecciones sigue pendiente.
4. **Fuera del canal Noise.** Los endpoints de ntfy son capacidades al portador en URLs, el servidor ntfy guarda sus propios registros y el aviso viaja fuera de las protecciones de la [ADR-008](ADR-008-carrier-independent-transport.md).
5. **Un aviso perdido no se repite.** La sincronización normal recupera los mensajes, pero el aviso se pierde.
6. **El protocolo ya tenía la respuesta.** El [protocolo §6](../PROTOCOL.md) especifica un frame `mailbox_wakeup` del realm al cliente por el canal. M3.4 lo rodeó.

Cómo lo resuelven otras apps sin Google: en Android, SimpleX Chat mantiene un servicio en primer plano conectado a sus servidores (modo «instantáneo») o consulta periódicamente. ntfy es en sí un servicio así, conectado a otro servidor. Solo iOS obliga a usar un proveedor (APNs), y Arveil no tiene cliente iOS (M3b.7 no ha empezado).

## Decisión (propuesta)

### 1. El relay avisa de la actividad por el canal

- **Suscripción.** `MailboxWatch {}` suscribe la sesión a los buzones de su dispositivo. El relay responde `Ack` y, si alguno no está vacío, envía un aviso en ese momento. Así, al reconectar se recupera un aviso perdido sin conexión, sin reintentos ni estado de notificación duradero.
- **Aviso.** `MailboxWakeup {}` es un frame no solicitado del relay, con id 0. Se envía cuando un buzón vigilado pasa de vacío a ocupado. No lleva id de buzón, número, remitente ni tamaño.
- **Una suscripción por dispositivo.** Una nueva sustituye y cierra la anterior.
- **Mantener viva la conexión.** `Ping`/`Pong` ya existen. El cliente envía pings con un intervalo que se mide por ruta durante la aceptación, porque túneles y NAT cierran conexiones inactivas en minutos o menos.
- **Tamaño fijo.** Los frames de aviso y sus pings se rellenan a un mismo tamaño, para que quien observe la ruta no distinga un aviso de un ping por su longitud.
- **Compatibilidad.** Los clientes antiguos nunca envían `MailboxWatch` ni reciben frames no solicitados.

### 2. Una clave solo para vigilar, por dispositivo

En Android el perfil debe seguir cerrado: las claves MLS y del dispositivo no deben quedar en memoria con el móvil bloqueado. Por eso el servicio usa una clave que solo sirve para vigilar.
- **Clave aparte.** El dispositivo genera una *clave de vigilancia* X25519 y registra su parte pública con `WatchKeySet { key }` desde una sesión de miembro; una clave vacía la retira. No se deriva de la clave de transporte del dispositivo ni es igual a ella.
- **Sesión de vigilancia.** Una sesión Noise cuya clave estática es una clave de vigilancia registrada solo puede enviar `Ping`, `MailboxWatch` y `EndpointListGet`. Cualquier otro frame se rechaza igual que en una sesión provisional: `EnvelopeFetch`, `EnvelopeAck`, `EnvelopePut`, blobs, KeyPackages, manifiestos, invitaciones y `NotifyHintSet`.
- **Ciclo de vida.** Revocar la credencial del dispositivo borra su clave de vigilancia y cierra sus sesiones de vigilancia. La recuperación y la rotación la sustituyen. Cada dispositivo tiene como mucho una.
- **Almacenamiento.** La parte privada se cifra con una clave del Keystore de Android, como hace hoy `PushStore`. Nunca entra en copias del perfil ni en exportaciones.
- **Si la roban.** Quien la tenga sabe cuándo el buzón de ese dispositivo tiene correo, hasta que se revoque el dispositivo o se sustituya la clave. No puede leer, descargar, confirmar ni enviar, y no sabe quién escribió.

Se descartaron dos opciones. Mantener el perfil desbloqueado en el servicio, como en macOS, deja en memoria las claves privadas MLS y del dispositivo con el móvil bloqueado y debilita la defensa «robo de un dispositivo bloqueado» del [modelo de amenazas](../THREAT_MODEL.md). Meter la clave de vigilancia en la `DeviceCredential` obligaría a firmar con la raíz cada rotación; basta con atarla al dispositivo que la registró, porque el relay ya sabe qué buzón es de qué dispositivo.

### 3. Android: Arveil mantiene la conexión por sí mismo

- **Servicio.** Un servicio opcional en primer plano mantiene una sesión de vigilancia. Sigue la lista firmada de direcciones por prioridad (LAN, tailnet, pública), reconecta con espera creciente al cambiar de red y arranca tras reiniciar si la persona lo activó.
- **Notificación.** Con `MailboxWakeup` muestra la notificación genérica que ya existe, agrupada hasta una sincronización correcta en primer plano, sin abrir el perfil. Se reutilizan las reglas de agrupación y visibilidad de la PR #141.
- **Requisitos del sistema.** El servicio muestra la notificación permanente que exige Android; su canal se puede silenciar. Pide la exención de optimización de batería. El tipo de servicio es `specialUse`: `dataSync` está limitado a seis horas en Android 15 y Arveil se distribuye fuera de Google Play. Cada versión de Android se comprueba durante la aceptación.
- **Implementación.** El canal Noise vive en el núcleo Rust. El servicio llama por JNI a un punto de entrada Rust pequeño que solo abre una sesión de vigilancia e informa de los avisos; no arranca Flutter. La alternativa es un motor Flutter sin interfaz, más pesado. Noise no se reimplementa en Kotlin.
- **Respaldo.** Quien rechace el servicio permanente puede elegir una comprobación periódica con WorkManager, como mínimo cada 15 minutos. Abre una sesión de vigilancia, mira si hay correo y cierra.

### 4. macOS usa la misma suscripción

Con «Mantener Arveil en segundo plano», el perfil abierto ya tiene una sesión de miembro. Envía `MailboxWatch` por ella y sincroniza con cada `MailboxWakeup` en lugar de cada diez segundos. macOS no necesita clave de vigilancia mientras la sesión sea la del perfil abierto.

### 5. Se retiran ntfy y el aviso M3.4

- **Cliente.** La siguiente versión del cliente quita los ajustes de ntfy, el conector UnifiedPush y `ArveilPushService`. En el primer arranque borra el aviso registrado enviando `NotifyHintSet` vacío.
- **Relay.** Sigue aceptando `NotifyHintSet` durante un ciclo de versiones, solo para borrarlo. Después retira el frame, `sendHint`, `arveil-hintsink` y `scripts/test_ntfy_hints.py`, y elimina la tabla `notify_hints` en una migración. Las URLs guardadas se borran, no se migran.
- **Se conserva de la PR #141.** La notificación genérica, su agrupación, el almacén protegido con el Keystore y las pruebas de visibilidad.

## Qué sabe cada parte

| Parte | Hoy, con ntfy | Con esta decisión |
|---|---|---|
| Relay | Cuándo un buzón pasa a ocupado (ya lo sabía) y la URL registrada | Las mismas transiciones y, además, cuándo está conectado cada dispositivo que lo active y desde qué IP, de forma continua |
| Servidor ntfy | IP y conexión permanente del móvil, su tema y la hora de cada aviso | No existe |
| Ruta intermedia (por ejemplo Cloudflare Tunnel) | El tráfico relay→ntfy y móvil→ntfy, si pasa por ella | La conexión permanente del móvil: cambios de IP, horas de conexión y ritmo de frames; no los frames ni cuáles son avisos |
| Quien robe una clave de vigilancia | — | Cuándo ese buzón tiene correo, hasta la revocación |
| Quien obtenga un endpoint de ntfy | Puede enviar notificaciones al móvil | — |

La presencia es el coste real. Por eso los avisos siguen siendo opcionales y desactivados por defecto, y el texto de ajustes lo dice claro: el servidor sabrá cuándo está conectado tu móvil y desde qué red. Cuando el móvil tiene ruta tailnet se prefiere, para que un túnel público no vea la conexión permanente.

El contenido de las conversaciones no se ve afectado. Un aviso solo dice que un buzón tiene algo; el cliente sigue descargando por el canal Noise y verifica y descifra con MLS, y el relay no recibe ninguna clave.

## Alternativas

| Alternativa | Motivo para no adoptarla |
|---|---|
| Mantener ntfy y UnifiedPush, pero anunciar el servidor ntfy en la lista firmada | Quita la dirección escrita a mano, pero mantiene dos componentes más, la segunda app, URLs al portador fuera de Noise y peticiones salientes del relay |
| FCM / servicios de Google Play | Google conoce token, horarios y aplicación; excluido desde el principio |
| Mantener el perfil desbloqueado en un servicio Android | Claves del dispositivo y MLS en memoria con el móvil bloqueado |
| Solo consulta periódica | Retrasos de 15 minutos o más; se conserva como respaldo |
| Arveil como su propio distribuidor UnifiedPush | La misma conexión con un protocolo más en medio y ninguna ventaja para una sola app |

## Consecuencias

- Un servidor menos para el operador, una app menos para las familias y ninguna dirección que escribir.
- El relay mantiene una conexión duradera por cada dispositivo que lo active. Memoria y descriptores crecen con ellas, y los límites por dirección también se aplican a las sesiones de vigilancia.
- El relay deja de hacer peticiones salientes, así que desaparece la política de destinos pendiente.
- Nueva superficie en Android: servicio en primer plano, punto de entrada JNI, receptor de arranque y solicitud de exención de batería.
- El gasto de batería depende del ritmo de pings de cada ruta. LAN y tailnet se miden aparte del túnel público.
- Android, o el gestor de batería del fabricante, puede seguir matando el servicio. Un aviso es una pista; la sincronización normal sigue siendo la fuente de verdad.
- iOS, si llega, necesitará APNs y su propia decisión.

## Criterios de aceptación

1. Una sesión de vigilancia rechaza cualquier frame que no sea `Ping`, `MailboxWatch` o `EndpointListGet`, incluidos descarga, confirmación, envío, blobs, KeyPackages, manifiestos, invitaciones y `NotifyHintSet`.
2. Revocar el dispositivo cierra sus sesiones de vigilancia y rechaza su clave en el siguiente handshake.
3. Un aviso al pasar de vacío a ocupado; ninguno por sobres posteriores hasta que el buzón vuelva a vaciarse; uno al suscribirse a un buzón ocupado.
4. Captura detrás de un túnel que termina TLS: avisos y pings no se distinguen por tamaño.
5. Móvil Android físico: pantalla apagada y Doze, ahorro de batería, cambio de Wi-Fi a datos y vuelta, reinicio, muerte del proceso, retirada de Recientes, forzar cierre y reabrir. Se miden demora y consumo por LAN o tailnet y por el túnel público.
6. La notificación no muestra remitente, conversación ni número; no se abre el perfil y las marcas de no leído no cambian.
7. Actualizar desde la beta 6 con ntfy activado borra el aviso en el relay y quita los ajustes de ntfy sin dejar un interruptor engañoso.
8. macOS deja de consultar cada diez segundos y sigue recibiendo actividad por la suscripción.
9. Un relay hostil que inunda de avisos: el cliente muestra como mucho una notificación hasta la siguiente sincronización y limita sus reconexiones.

## Preguntas abiertas

- Punto de entrada JNI o motor Flutter sin interfaz.
- Intervalo de pings por ruta, y si el cliente debe quedarse en tailnet aunque responda antes una ruta pública.
- Si los avisos siguen llegando con el perfil cerrado (como hace hoy el receptor ntfy) o solo después de haber abierto el perfil una vez desde el arranque.

Referencias: [protocolo](../PROTOCOL.md), [modelo de amenazas](../THREAT_MODEL.md), [ADR-008](ADR-008-carrier-independent-transport.md), [ADR-015](ADR-015-delivery-metadata-and-anonymous-sender.md), [Doze en Android](https://developer.android.com/training/monitoring-device-state/doze-standby), [límites de servicios en primer plano](https://developer.android.com/develop/background-work/services/fgs/timeout).
