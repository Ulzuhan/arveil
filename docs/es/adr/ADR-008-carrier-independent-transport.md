# ADR-008 — Transporte independiente del carrier: canal Noise y lista de endpoints

- **Estado:** propuesto.
- **Fecha:** 2026-09-04.
- **Edición documental:** v0.4.
- **Ámbito:** autenticación y confidencialidad entre dispositivo y realm; acceso por LAN, tailnet, Internet directo, túneles y CDN; preparación para varios relays.

*English version: [../../adr/ADR-008-carrier-independent-transport.md](../../adr/ADR-008-carrier-independent-transport.md)*

## Contexto

El realm debe ser alcanzable por cualquiera de estas vías, y a menudo por varias a la vez: LAN doméstica, una tailnet de Tailscale, puertos expuestos en el router, Tailscale Funnel, un túnel de Cloudflare con dominio propio o un VPS que reenvía TCP. El operador de referencia prevé usar Cloudflare Tunnel; los familiares deben necesitar solo la aplicación.

Las ediciones anteriores apoyaban tres funciones en TLS extremo a extremo: confidencialidad de sesiones y capabilities, vinculación del pin del realm y garantía de que nadie altera peticiones entre cliente y relay. Con Cloudflare Tunnel, TLS termina en el borde de Cloudflare y el túnel entrega HTTP en claro al origen. Un intermediario así vería rutas, identificadores de mailbox y entrega, tiempos, IPs y los secretos portadores de sesión y capabilities, con los que podría escribir en mailboxes, consumir KeyPackages o emitir ACKs falsos. No podría leer contenido, protegido por MLS y HPKE, pero pasaría de observador a actor. El pin TLS tampoco funcionaría: el cliente vería el certificado del intermediario.

El protocolo, por tanto, no era independiente del transporte. Esta decisión corrige esa dependencia.

## Decisión

**1. Canal Noise entre core Rust y realm, dentro de cualquier transporte.** Cada conexión establece un handshake Noise `IK` sobre WebSocket. El iniciador es el dispositivo, con una clave estática X25519 de transporte declarada en su `DeviceCredential` y firmada por la raíz. El respondedor es el realm, con una clave estática X25519 certificada por la clave de firma del realm. El dispositivo conoce la clave del realm desde el bootstrap; el realm identifica al dispositivo por su clave estática y la comprueba contra el directorio al terminar el handshake. Prólogo: versión de protocolo y `realm_id`. Toda operación de la API se transmite como frames CBOR dentro del canal.

**2. TLS queda como capa de conveniencia, no de seguridad del protocolo.** Sobre Internet se usa `wss://` con validación WebPKI ordinaria, para atravesar proxies, CDNs y middleboxes sin fricción. En LAN puede emplearse un certificado autofirmado o `ws://`; la seguridad no depende de ello. Ningún secreto ni identificador de la API viaja en URL, cabeceras HTTP o cookies.

**3. Lista firmada de endpoints.** El realm publica un `RealmEndpointList` firmado y secuenciado con sus direcciones LAN, tailnet y públicas, y su clave Noise vigente. El QR de bootstrap contiene la lista inicial o su hash y un endpoint de arranque. Los clientes conservan el máximo conocido, rechazan retrocesos y prueban los endpoints por prioridad, cambiando entre ellos sin intervención. Un endpoint erróneo u hostil solo produce un handshake fallido.

**4. Plano de administración separado.** Los frames administrativos solo se aceptan en endpoints marcados como administrativos, normalmente loopback, LAN o tailnet, y con credencial administrativa propia. Un túnel público no expone administración aunque comparta proceso.

**5. Multinodo por relays independientes.** Cuando existan varios nodos, cada uno es un relay con su propia identidad, su propia lista de endpoints y su propio almacenamiento; los dispositivos publican un `RouteBundle` por relay. [ADR-007](ADR-007-optional-realm-redundancy.md) registra esta dirección como preferente; los frames de V1 no anuncian clúster.

## Perfil técnico del canal

| Elemento | Especificación propuesta |
|---|---|
| Patrón | `Noise_IK_25519_ChaChaPoly_BLAKE2s`, fijado en M0.2 e implementado en ambos lados (`snow` 0.10 en el core, `flynn/noise` 1.1 en el relay); el prólogo es `arveil/<protocol_version>/<realm_id>` |
| Claves estáticas | Dispositivo: `transport_noise_public_key` en `DeviceCredential`. Realm: `realm_noise_public_key` firmada por la clave de firma del realm. No se derivan de claves Ed25519 |
| Primer mensaje | Sin datos de aplicación. `IK` no ofrece forward secrecy ni protección contra replay para el payload del primer mensaje; el servidor no actúa sobre nada anterior a completar el handshake |
| Autorización | Tras el handshake, el realm comprueba que la clave estática pertenece a una credencial activa de un miembro; si no, cierra. Las capabilities de mailbox y blob se presentan como campos de frame |
| Frames | CBOR determinista, con `frame_id` para correlación, límites de tamaño antes de decodificar y respuestas explícitas. Los mensajes Noise tienen un máximo de 65 535 bytes; los frames mayores se fragmentan y se reensamblan con límite acotado |
| Ciclo de vida | Sesión = conexión. Reconectar implica nuevo handshake; los cursores durables de mailbox permiten reanudar. Keepalive periódico para intermediarios que cierran conexiones inactivas |
| Rotación | La clave Noise del realm rota publicando una lista nueva; la anterior se acepta durante una ventana acotada. La clave del dispositivo rota mediante credencial nueva firmada por la raíz |
| Carrier | WebSocket en V1. Un carrier HTTP de sondeo para redes que bloquean WebSocket queda como posibilidad futura, transportando los mismos frames |

## Qué ve cada intermediario con este diseño

| Vía de acceso | Intermediario | Ve | No ve |
|---|---|---|---|
| LAN directa | Nadie | — | — |
| Tailnet | Coordinación de Tailscale; DERP si falla el NAT | Nodos que se comunican, volumen | Bytes del canal |
| Puertos expuestos | Nadie, pero la IP doméstica queda expuesta a contactos y escáneres | — | — |
| Tailscale Funnel | Ingreso de Tailscale | Bytes TLS, SNI, IP, tiempos | Contenido TLS; TLS termina en el nodo |
| Cloudflare Tunnel | Cloudflare | IP de cada cliente, tiempos, tamaños de frame, número de conexiones, dominio | Frames, identificadores de mailbox y entrega, credenciales, tipos de operación |
| VPS con passthrough TCP | Proveedor del VPS | Bytes TLS, IP, tiempos | Contenido TLS |

Con o sin Noise, ningún intermediario ve contenido de mensajes. Lo que Noise añade es que un intermediario que termina TLS deja de ver la API y sus credenciales. Sigue viendo patrones de conexión y volumen; el padding por buckets reduce precisión de tamaños, no oculta actividad. Este residuo se documenta en el [modelo de amenazas](../THREAT_MODEL.md#2-adversarios-y-escenarios).

## Alternativas

| Alternativa | Motivo para no adoptarla |
|---|---|
| Confiar en TLS extremo a extremo y exigir que el operador no use CDN | Excluye la vía de acceso más cómoda para familias y convierte una decisión de despliegue en una restricción de seguridad frágil |
| Firmar cada petición HTTP con la clave del dispositivo (RFC 9421) y firmar respuestas con la del realm | Impide que un intermediario actúe, pero sigue exponiendo identificadores, capabilities de terceros y estructura de la API. Sirve como carrier de reserva, no como base |
| mTLS con certificados de dispositivo | Incompatible con terminación TLS en CDN; complica la operación en LAN y en móviles |
| Exigir Tailscale u otra VPN a todos los miembros | Añade proveedor de identidad externo, conflicto con otras VPNs en móvil y fricción de instalación; se conserva solo como vía opcional y para administración |
| Diseñar un canal propio sobre HPKE | Rechazado: Noise es un framework revisado con implementaciones maduras en Rust y Go |

## Consecuencias

El relay deja de ser un servidor HTTP REST y pasa a ser un servidor de frames sobre WebSocket con TLS opcional; herramientas genéricas de inspección HTTP ya no muestran la API. Se pierde cacheo y enrutamiento por ruta en proxies, que este producto no necesita.

Se añade una clave X25519 por dispositivo y una por realm, con su ciclo de vida. La `DeviceCredential` sustituye la clave de autenticación de transporte Ed25519 por la clave estática Noise; la prueba de posesión ante el realm pasa a ser el propio handshake.

La LAN deja de requerir provisión de certificados. El bootstrap deja de depender de un pin TLS. La lista de endpoints, prevista en ADR-007 para HA, se adelanta a V1 y habilita acceso simultáneo por varias vías.

Los intermediarios que terminan TLS quedan reducidos a observadores de tráfico. Cloudflare Tunnel resulta aceptable como vía pública por defecto, con el residuo de metadatos declarado; Funnel o un VPS propio son sustitutos directos cambiando solo la lista de endpoints.

## Criterios de aceptación

1. Captura en el lado del origen de un túnel que termina TLS: solo frames opacos; sin identificadores, credenciales ni tipos de operación legibles.
2. Handshake contra un endpoint con clave Noise distinta: rechazo visible sin enviar frames.
3. Lista de endpoints con secuencia inferior o firma inválida: rechazo; conmutación LAN → tailnet → público sin intervención al caer cada vía.
4. Replay del primer mensaje `IK`: sin efecto en el servidor.
5. Frames malformados, sobredimensionados o fragmentación incompleta: cierre acotado sin consumo ilimitado.
6. Reconexión tras corte con cursores durables: sin pérdida ni duplicados visibles.
7. Administración por endpoint público: rechazada aunque la credencial sea válida.

## Registro de aceptación (M0.2, M0.6)

Los criterios 1 a 6 se ejercitan en CI: `scripts/q3-capture.sh` (criterio 1: la captura tras un proxy que termina TLS muestra solo frames opacos; extracto en `docs/evidence/q3-capture-excerpt.txt`), los tests del canal en core y relay (criterios 2, 4 y 5: clave estática errónea, primer mensaje repetido, frames malformados y sobredimensionados), `scripts/interop.sh` (criterio 3 parcialmente: lista firmada con comprobación de retrocesos; la conmutación entre varios endpoints vivos queda por guionizar) y `scripts/demo.sh` (criterio 6: reconexión tras reinicio del relay con cursores durables). El criterio 7 (administración rechazada en endpoints públicos) espera al primer frame administrativo.

## Reabrir

Si un carrier HTTP de sondeo resulta necesario en producción; si aparece una necesidad de sender no autenticado ante el relay, que exigiría un perfil distinto; o si el estudio de ADR-007 selecciona un clúster con estado compartido y hace falta enrutar frames entre nodos.

Referencias: [protocolo](../PROTOCOL.md#endpoints-y-carriers), [arquitectura](../ARCHITECTURE.md#6-homelab-y-operación), [amenazas](../THREAT_MODEL.md), [ADR-007](ADR-007-optional-realm-redundancy.md), [Noise Protocol Framework](https://noiseprotocol.org/noise.html), [RFC 8949 — CBOR](https://www.rfc-editor.org/rfc/rfc8949).
