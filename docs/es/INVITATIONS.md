# Invitaciones personales: implementación y despliegue

1 de octubre de 2026 · implementado en `codex/invitation-onboarding`; **sin publicar**.
[English](../INVITATIONS.md) · [Plan detallado y matriz de aceptación](INVITATION_ONBOARDING_PLAN.md).

## Recorrido

En Contactos, **Invitar a alguien** permite al propietario autorizado crear una
invitación privada, de un uso y siete días. Puede compartirla desde el selector
del sistema, copiarla o mostrar su QR. Abrir o escanear solo presenta una vista
previa. Al aceptar expresamente, el destinatario crea su identidad independiente,
entra en el servidor, añade al emisor y prepara una conversación. No recibe
historial anterior ni queda nadie marcado como verificado. Si ya pertenece al
mismo servidor, conserva identidad y rol. Otro servidor o una invitación propia
se rechazan.

La primera instalación permite escanear/pegar antes de pedir datos del servidor.
Las invitaciones antiguas de solo alta mantienen una entrada separada. Después
de instalar se vuelve al enlace original o se escanea otra vez: no hay atribución
a través de la instalación. Acceso al canal de pruebas de Play y admisión en
el relay son controles distintos. La web complementaria está preparada en
`kaicorplabs-web` (`/join`, `/install`, `/es/instalar`), pendiente de desplegar.

El emisor puede estar desconectado durante la aceptación. Debe volver a abrir
**el dispositivo que emitió** y sincronizar para recibir el contacto. Otro
dispositivo activo de esa identidad puede listar metadatos y revocar; no puede
reconstruir el secreto, volver a compartir ese enlace ni recibir allí el primer
chat mediante este hito. Las notificaciones no condicionan el alta.

## Permiso para la identidad actual

Tener la raíz de la identidad personal no hace a nadie administrador del relay.
Solo un miembro activo con rol literal `owner` emite/revoca; `member` y el rol
antiguo `admin` no tienen ese permiso. La migración no asciende a nadie.

Después de revisar y desplegar el relay, comparar el identificador público
completo de **Invitar a alguien → detalles del permiso** con el miembro al que
se quiere autorizar. En el host, con la cuenta del servicio y su directorio:

```sh
arveil-relay make-owner -data-dir /ruta/datos-del-realm -identity ID_COMPLETO_64_HEX
```

Promueve solo esa membresía activa existente y registra auditoría. No sustituye
su identidad ni crea una API remota para cambiar roles. Volver a abrir
Invitaciones actualiza el permiso. La CLI `invite` conserva el alta antigua.
**No se ha promovido ninguna identidad real durante esta implementación.**

## Contrato de protocolo

Los nombres siguientes son variantes CBOR exactas dentro del canal Noise
autenticado; no son rutas HTTP. Bytes vacíos se codifican `h''`, nunca null;
listas vacías son arrays.

| Petición | Campos | Respuesta y autorización |
|---|---|---|
| `InvitePolicyGet` | Variante sin cuerpo | `InvitePolicy {can_invite, server_time, ttl}`; miembro activo |
| `InviteCreate` | `request_key: bytes24, token_hash: bytes32, ttl: u64` | `Invitation`; owner; admite un `member`; TTL 1–604800 s, app pide 604800 |
| `InviteList` | `cursor: u64, limit: u16` | `Invitations {invitations, next_cursor}`; solo emisiones de esa identidad; límite 1–50 |
| `InviteGet` | `invitation_id: bytes32` | `Invitation`; emisor o identidad reclamante registrada |
| `InviteRevoke` | `invitation_id: bytes32` | `Invitation`; owner y emisor original; idempotente antes del uso |
| `InviteAccept` | `token: bytes32` | `Invitation`; miembro activo del realm; gasta el uso sin cambiar membresía |
| `KeyPackagesClaimOnce` | `request_key: bytes24, identity_id: bytes32, device_id: bytes16` | `KeyPackageClaimed` existente; miembro activo, un paquete durable por petición |

`Invitation` contiene `invitation`. Cada registro lleva `sequence: u64`,
`id: bytes32` (SHA-256 del token), `created_at/expires_at/claimed_at: u64`,
`state: pending|used|revoked|expired` y `claimed_identity: bytes32` (vacío antes
del uso; `claimed_at=0`). Fechas en segundos Unix. Cursor = última secuencia
recibida; las secuencias son globales y las filas se filtran por emisor.
Una identidad nueva usa `InviteRedeem`, que actualiza el recibo personal en la
misma transacción. Repetir aceptación está ligado a la misma credencial, no solo
identidad: dos dispositivos vinculados no pueden reclamar dos chats distintos.

La clave de petición contiene ocho bytes de fecha big-endian obtenida de la
política del relay y dieciséis aleatorios criptográficos. Una petición nueva se
admite durante siete días, con cinco minutos de tolerancia futura. Primero se
busca el recibo: mismo actor/clave/parámetros devuelve el resultado original;
cambiar destino o parámetros produce conflicto. Una clave antigua cuyo recibo
ya se limpió no emite ni consume otro paquete. No se cambia de clave ante una
respuesta de red incierta.

Cada acción vuelve a consultar credencial, membresía y rol, incluso en una
conexión abierta. Cuotas: 20 emisiones/identidad/24 h, 50 pendientes/realm,
60 intentos/sesión/minuto, 120/dirección/minuto (incluidos rechazos) y 100 claims
durables de paquetes/credencial/24 h. Errores: 400 petición inválida (un relay
antiguo también rechaza variantes desconocidas), 401 sesión provisional,
403 permiso, 409 conflicto/usada, 410 invitación no disponible/sin paquete y
429 cuota. La UI usa razones fijas traducidas, sin texto arbitrario del relay
ni secretos.

## Formato y confianza

Se conservan los lectores v1 de join/contact/link. Una invitación personal usa
`version: 2, kind: "join"`, las claves y URL del realm, `invitation: bytes32`,
`expires_at` y la tupla compacta `contact` en este orden:

```text
[device_id:16, credential_hash:32, identity_root:32, mailbox_id:16,
 write_capability:32, hpke_public_key:32, contact_secret:16, name:text|null]
```

Se mantienen 600 bytes máximos de CBOR canónico, 128 caracteres de URL y
64 bytes UTF-8 de nombre. Clientes antiguos rechazan v2; no completan solo el
alta. El payload máximo y su QR renderizado/decodificado pasan pruebas; queda
pendiente la lectura física.

El fragmento permanece en el navegador: la web no lo manda por HTTP ni a
analítica. Quien recibe o transporta el mensaje compartido sí puede ver el enlace
completo. Es un permiso al portador: gana el primer reclamante válido, incluso
si le reenviaron el enlace. El nombre es una declaración, no una autenticación.
El receptor comprueba credencial firmada por raíz, manifiesto activo y claves
MLS correspondientes. El emisor solo acepta automáticamente si el secreto y
hash del hello cifrado coinciden con su operación, el recibo identifica a ese
remitente y la hoja MLS corresponde a la credencial validada. Sin prueba sigue
como solicitud normal. Una solicitud rechazada no se acepta automáticamente.

## Persistencia, privacidad y limpieza

Relay **4 → 5** añade emisiones/auditoría y recibos de claim. Perfil **7 → 8**
añade operaciones y hellos candidatos. No cambia identidades ni verificación
de contactos existentes. El relay conoce la relación emisor/reclamante, fechas
y destino del paquete reclamado. Estas API no le entregan nombres, secretos de
contacto ni contenido de conversaciones.

El perfil cifrado guarda enlace/token/secreto antes de un efecto de red. Flutter
solo mantiene estado temporal de pantalla. Kits de identidad y archivos de
conversación no exportan esta tabla. Una copia cifrada del perfil completo puede
contener secretos pendientes: necesita la protección del propio perfil. Borrar
en el perfil actual no borra copias antiguas ni el enlace ya compartido.

Receptor: `accepting → enrolled → prepared → complete`. Emisor: `issuing →
pending → used → connected`, más `revoke-pending`, `revoked` y `expired`.
El ejecutor serializa mutaciones de alta y sincronización. Guarda el paquete
reclamado antes de MLS; MLS, conversación, outbox y vínculo operación→grupo se
confirman juntos. Reintentar reutiliza paquete, grupo y outbox. Completar significa
publicar en el relay, no lectura ni descarga por el otro dispositivo.

Un fallo incierto conserva progreso. Un rechazo definitivo antes del alta
libera solo ese marcador y permite otra invitación conservando identidad. Una
persona ya admitida mantiene su membresía si falla el contacto. Revocar queda
pendiente hasta confirmación; si un canje válido ganó antes, se representa usada.

Los registros del relay permanecen hasta que vencimiento y canje superan ambos
37 días. Recibos de paquetes/auditoría retienen 37 días desde creación. Los
recibos de alta preexistentes mantienen su política. Esto supera los 30 días
actuales de retención de sobres. Al listar se limpian pruebas/metadatos locales
salientes pasados vencimiento +37 días. Completar entrada borra enlace, secreto
y paquete, conservando el mínimo ID→grupo. Las entradas sin terminar se guardan
para reanudar. Es limpieza lógica, no garantía de borrado de snapshots o de todas
las páginas libres de SQLite.

## Evidencia del 1 de octubre de 2026

- Suite Go con detector de carreras; permisos, cuotas, canje/revocación,
  migración desde v4, copia consistente y recibo tras reapertura correctos.
- Suite Rust y Clippy correctos; migración de perfil, reapertura cifrada,
  rollback del vínculo de grupo, compatibilidad v1 y QR v2 máximo.
- Pruebas reales Go↔Rust con relay desechable: persona nueva con emisor cerrado,
  reinicio del relay, enlace repetido, miembro existente, sustitución de token
  rechazado, red caída/reapertura/reintentos concurrentes, revocación offline que resiste
  un refresco y recibo eliminado
  que conserva una solicitud sin bloquear sync. El CI las ejecuta expresamente.
- Dos matrices añaden 22 fallos de persistencia: intención de emisión/alta,
  respuestas de canje, mailbox y paquetes, transacciones de conversación,
  publicación, finalización, revocación y recepción. Un trigger SQL aborta la
  escritura elegida; el proceso hijo sale sin cerrar el perfil ni ejecutar
  destructores. Tras quitar el trigger y reiniciar el relay, la reapertura
  cifrada conserva identidad, paquete, grupo y bytes del outbox, sin duplicar
  membresías, buzones, sobres ni consumo de paquetes. Se comprueba el rollback
  de las transacciones fallidas. Modela respuestas recibidas pero no registradas;
  no pretende simular cada pérdida de paquetes ni un corte eléctrico físico.
- Backup del relay activo y restauración completa en un directorio vacío:
  mantiene claves del servidor, rol owner, invitaciones usadas/pendientes/revocadas,
  recibos de paquetes y sobres aún no recogidos. Rechaza sobrescribir datos.
  Después permite terminar los chats pendientes. Es restauración de esquema 5
  con binario compatible, no downgrade de la base a esquema 4. Un cliente que
  conoce una lista de endpoints posterior rechaza la del backup y conserva su
  lista; acepta la nueva tras preservar el mayor contador del mismo realm.
  El [procedimiento del operador](OPERATIONS.md#copias-de-seguridad) incluye ese paso.
- Ensayo separado de reversión del relay: binario base
  `f5dfd190b97f13de694c91a7cf4b5257ca59cc26`, backup vivo de esquema 4,
  migración a 5 y rechazo del binario antiguo sin reescribir la base. Se restaura
  el backup previo con el binario anterior, conservando claves y contador; alta
  antigua e invitaciones previas funcionan. Los cambios posteriores al backup
  se descartan de forma deliberada. No se han degradado perfiles de clientes.
- Segundo dispositivo vinculado: misma identidad y permiso, lista sin secretos,
  revocación autorizada y ningún primer chat atribuido al dispositivo equivocado;
  el emisor original lo recibe al reabrir. Son nueve escenarios de integración,
  contando cada matriz como un escenario.
- Aceptación nativa macOS 26.6.2 y Android 15/API 35 arm64 emulado, con
  relay/perfiles desechables: crear y renderizar QR
  desde la pantalla real, vista previa sin identidad/efecto de red, consentimiento,
  caída de red, perfil cifrado cerrado/reabierto, continuar sin volver a pegar,
  enlace repetido sin duplicados y mensajes en ambos sentidos. Ambos contactos
  quedan sin verificar. El CI incluye este recorrido nativo.
- Análisis Flutter y 303 pruebas correctas: consentimiento, doble pulsación,
  progreso, permisos, idiomas/accesibilidad y capturas de Contactos. Compilan APK
  debug arm64 y app debug macOS; no son paquetes firmados de aceptación/publicación.

Web local: dos idiomas y 11 anchos (320–1920 px) sin desplazamiento lateral;
fragmento sintético conservado al abrir la app y ausente de peticiones HTTP.
Lighthouse: guías 99/100/100/100; join 99/100/100/66 por el `noindex` intencional
existente, que impide rastreo. Se conserva esa privacidad. Esta prueba local no
acredita despliegue ni certificados en producción.

Para repetir la integración desde la raíz:

```sh
go -C relay build -o /tmp/arveil-invitations-relay ./cmd/arveil-relay
cd core
ARVEIL_TEST_RELAY=/tmp/arveil-invitations-relay cargo test -p arveil-app --test invitations --locked -- --ignored
```

Para repetir la aceptación nativa desde la raíz:

```sh
python3 scripts/test_client_conversations.py --device macos --scenario invitations
# Con un emulador desechable encendido y adb en PATH:
python3 scripts/test_client_conversations.py --device emulator-PORT --scenario invitations
```

Pendientes: QR máximo físico, cámara denegada en dispositivo real, primera
instalación desde WhatsApp/Play/APK, App Links con firma de Play y candidata
firmada. La reversión del relay usa un backup anterior compatible, nunca
un downgrade del esquema; tampoco acredita la reversión de perfiles 8 a 7. Pérdida del emisor,
ruta revocada o reanudación fuera de retención requieren recuperación explícita;
no hay traslado automático de ruta ni botón para abandonar una operación
incierta. Las etiquetas locales opcionales por invitación tampoco están.
Por tanto P7/P8 siguen abiertos: no se dan por aprobados A01–A18 en su conjunto.

## Despliegue y reversión

1. Revisar sobre `codex/files-notifications` (PR #141), dependiente de
   `codex/android-qr-pairing` (PR #139). Publicar beta 5 no fusionó esas ramas.
2. Cerrar aceptación física pendiente. Hacer copia
   consistente del relay con su comando de backup y preservar perfiles antes
   de abrirlos con el cliente nuevo.
3. Actualizar primero relay; verificar salud, alta antigua y esquema 5.
   Promover el owner previsto por ID completo y comprobar emisión.
4. Desplegar web compatible y verificar enlaces con certificados reales.
   Preparar versión/build nueva; no reutilizar build 26.
5. Aceptar en Android físico limpio y Mac empaquetado, y después publicar en
   Play/cask/feed. Registrar fuente, hashes, dispositivo y resultados.

No abrir bases 5/8 con binarios anteriores. Preferir corrección hacia delante;
restaurar exige datos/binario compatibles y acordar qué cambios posteriores al
backup se pierden. Bajar la versión de un feed no baja la de una app instalada.
Este cambio no ha desplegado servicios, promovido un owner real ni publicado.
