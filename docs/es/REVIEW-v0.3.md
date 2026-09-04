# Revisión de viabilidad — documentación v0.3

**Estado:** revisión documental externa · **Fecha:** 2026-09-04 · **Alcance:** los doce documentos de `docs/` en su edición v0.3/v0.2. [Índice](README.md) · [Arquitectura](ARCHITECTURE.md) · [Protocolo](PROTOCOL.md).

*English version: [../REVIEW-v0.3.md](../REVIEW-v0.3.md)*

Esta revisión evalúa coherencia interna, exactitud de las referencias citadas y viabilidad de ingeniería y de producto. No es una auditoría criptográfica ni una prueba de integración. Las recomendaciones son propuestas para discusión; ninguna modifica por sí sola un ADR.

## 1. Veredicto

La arquitectura es **técnicamente viable** y la documentación tiene un nivel de honestidad y precisión poco habitual en una propuesta v0.3. Las decisiones estructurales —relay Go sin semántica de conversación, core Rust compartido, MLS con una leaf por dispositivo, identidad raíz independiente del realm, SQLite en WAL y recuperación separada en kit, incorporación y archivo— son sólidas y tienen precedentes en producción.

Los riesgos de viabilidad no están en la criptografía. Están en tres puntos: el **coordinador único de commits**, el **push en iOS** y el **tamaño del esfuerzo** frente al equipo disponible. Los tres se detallan en la sección 3.

## 2. Referencias verificadas

Todas las afirmaciones externas de la documentación se contrastaron el 2026-09-04 contra sus fuentes primarias. Ninguna resultó incorrecta.

| Afirmación en los documentos | Fuente | Resultado |
|---|---|---|
| Bug WAL-reset presente desde 3.7.0 hasta 3.51.2; corregido en 3.51.3; backports 3.44.6 y 3.50.7 ([ADR-004](adr/ADR-004-sqlite-single-binary.md)) | [sqlite.org/wal.html](https://sqlite.org/wal.html) | Confirmado literalmente |
| Go 1.27.1 publicado el 2026-09-01 ([ADR-001](adr/ADR-001-go-server-rust-core.md)) | [go.dev/doc/devel/release](https://go.dev/doc/devel/release) | Confirmado; 1.27.0 es del 2026-08-19 |
| Rust 1.98.1 publicado el 2026-09-03 y corrige generación de vtables ([ADR-001](adr/ADR-001-go-server-rust-core.md)) | [blog.rust-lang.org](https://blog.rust-lang.org/2026/09/03/Rust-1.98.1/) | Confirmado: «fixes a miscompilation in vtable generation» |
| OpenMLS prueba Linux, Windows y macOS; Android, iOS y WASM solo se compilan ([ADR-001](adr/ADR-001-go-server-rust-core.md)) | [github.com/openmls/openmls](https://github.com/openmls/openmls) | Confirmado |
| Features `content-debug` y `crypto-debug` imprimen contenido y claves ([ADR-002](adr/ADR-002-mls.md)) | Mismo README | Confirmado; existe además `sqlite-provider` |
| mls-rs sin auditoría completa de terceros; Rust Crypto y Web Crypto experimentales ([ADR-002](adr/ADR-002-mls.md)) | [github.com/awslabs/mls-rs](https://github.com/awslabs/mls-rs) | Confirmado; OpenSSL y AWS-LC son los providers estables; existen `mls-rs-ffi` y `mls-rs-uniffi` |
| `MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519` es suite obligatoria ([PROTOCOL §1](PROTOCOL.md#1-capas-y-responsabilidades)) | [RFC 9420 §17.1](https://www.rfc-editor.org/rfc/rfc9420#section-17.1) | Confirmado: «All MLS implementations MUST support» |
| Un miembro no puede abandonar unilateralmente; debe retirarlo otro ([PROTOCOL §5](PROTOCOL.md#cambios-orden-y-particiones)) | [RFC 9750 §6.1](https://www.rfc-editor.org/rfc/rfc9750#section-6.1) | Confirmado literalmente |
| Riesgo de recuperar contra GroupInfo obsoleto del servidor ([PROTOCOL §5](PROTOCOL.md#cambios-orden-y-particiones)) | [RFC 9750 §5.3](https://www.rfc-editor.org/rfc/rfc9750#section-5.3) | Confirmado |

Dato adicional relevante para la sección 3: RFC 9750 §5.2.1 establece que «The Delivery Service is trusted to break ties when two members send a Commit message at the same time». El estándar contempla explícitamente que el relay secuencie commits.

## 3. Riesgos que condicionan la viabilidad

### 3.1 Coordinador único de commits

Es el punto más débil del diseño y los documentos lo reconocen, pero subestiman su coste para el público objetivo.

El coordinador es el dispositivo creador del grupo. En una familia ese dispositivo es un teléfono, y los teléfonos se pierden, se cambian o se rompen. La consecuencia documentada en [PROTOCOL §5](PROTOCOL.md#cambios-orden-y-particiones) y [ADR-002](adr/ADR-002-mls.md) es recrear cada grupo que ese teléfono creó, con reverificación de todos los participantes y pérdida de continuidad del grupo.

Hay una segunda consecuencia no documentada: **la post-compromise security depende de la disponibilidad del coordinador**. Solo él puede confirmar los Update de los demás miembros, así que un miembro que quiera rotar claves tras un compromiso espera a que el coordinador esté online. Esto debería constar en [THREAT_MODEL §4](THREAT_MODEL.md#4-garantías-con-condiciones).

Dos alternativas encajan con el resto del diseño y eliminan el bloqueo «crear grupo nuevo»:

| Alternativa | Mecanismo | Qué resuelve | Coste |
|---|---|---|---|
| **Sucesor determinista** | La extensión de GroupContext lista un orden de committers autorizados, o se aplica la regla «leaf activa de índice más bajo». Todos los clientes derivan el committer legítimo del estado que ya validan. | Baja, pérdida y revocación del coordinador sin recrear el grupo. No es una elección bajo partición: es una función del estado autenticado. | Definir la regla en la extensión y probar el relevo cuando el committer actual es revocado por manifiesto. |
| **Secuenciación opaca en el relay** | Compare-and-set sobre un contador por identificador aleatorio de grupo. El relay no interpreta el commit, solo garantiza un único ganador por epoch padre. | Commits concurrentes de cualquier miembro, conforme a RFC 9750 §5.2.1. Elimina el coordinador por completo. | El relay aprende que un conjunto de mailboxes comparte un contador. [THREAT_MODEL §3](THREAT_MODEL.md#3-qué-sabe-realmente-el-servidor) ya admite que el fan-out revela esa relación. |

Recomendación: evaluar la primera en el spike de ADR-002 como sustituta del coordinador fijo. Mantener la segunda como opción si la primera resulta frágil ante revocaciones concurrentes.

### 3.2 Push en iOS

Los documentos tratan el push como opcional y afirman que el sistema operativo «no garantiza despertar siempre». En iOS no es una degradación gradual: **sin APNs, la aplicación solo recibe mensajes cuando está abierta**. Para un messenger familiar esto equivale a no funcionar.

APNs exige las credenciales del publicador de la aplicación. Eso deja dos caminos, y ambos chocan con la promesa de soberanía tal como está redactada:

- Una pasarela de push central operada por quien firma el binario. El proyecto pasa a operar un servicio externo obligatorio para usuarios de iPhone.
- Que cada operador de realm tenga cuenta de desarrollador de Apple y compile y firme su propia app.

Existe además un coste de ingeniería derivado. Para mostrar contenido en una notificación iOS hace falta una Notification Service Extension, que es **otro proceso** accediendo al estado MLS y a la base cifrada. Eso rompe el supuesto de un escritor lógico de [DOMAIN_MODEL §5](DOMAIN_MODEL.md#5-estado-local-y-atomicidad) y exige un diseño propio de exclusión entre procesos, como el que Signal mantiene para su extensión.

En Android, UnifiedPush con un distribuidor autohosteado como ntfy es viable y coherente con el proyecto.

Recomendación: decidir la estrategia de iOS antes de la fase 3 y documentarla en un ADR propio. Si la respuesta es «iOS solo en primer plano en V1», decirlo en [ARCHITECTURE §8](ARCHITECTURE.md#8-alcance-y-gates-de-ingeniería).

### 3.3 Tamaño del esfuerzo

El alcance descrito equivale a varios años-persona: core Rust con identidad, MLS, persistencia transaccional, sincronización, pairing y archivo; servidor Go; clientes Flutter en cuatro plataformas; protocolo de vinculación; formato de archivo; y toda la batería de pruebas adversariales de [THREAT_MODEL §5](THREAT_MODEL.md#5-invariantes-verificables-y-escenarios-de-aceptación). Los gates por fase están bien planteados, pero no hay ninguna estimación de esfuerzo ni de equipo.

Recomendación: reducir la fase 0 a **clientes CLI en escritorio**, sin Flutter ni pairing, que demuestren MLS real, persistencia atómica y el relay Go. Ese entregable ya valida las tres hipótesis técnicas críticas con una fracción del coste.

### 3.4 TTL de 30 días y desincronización MLS

Un familiar que no abre la aplicación en un mes pierde los commits intermedios, se desincroniza y necesita reingresar sin el historial de ese periodo. [ARCHITECTURE §5](ARCHITECTURE.md#5-persistencia-y-entrega) lo describe como «reingreso»; para el público objetivo es una pérdida de datos percibida.

Mitigación barata ya contemplada por el protocolo: usar un `requested_expiry` más largo en los sobres que contienen commits y Welcome. El coste es que el servidor puede distinguir sobres de control por su caducidad, un metadato menor frente al beneficio.

### 3.5 Persistencia transaccional con la biblioteca MLS

La condición de adopción de [ADR-002](adr/ADR-002-mls.md) está bien planteada. Dato para el spike: **mls-rs persiste el estado de grupo mediante una llamada explícita**, mientras OpenMLS escribe a través del provider durante cada operación. El modelo explícito encaja mejor con la unidad de envío de [DOMAIN_MODEL §5](DOMAIN_MODEL.md#5-estado-local-y-atomicidad). Ambas bibliotecas permiten inspeccionar un commit antes de fusionarlo, por lo que la política de committers es implementable en las dos.

Precedente relevante para [ADR-001](adr/ADR-001-go-server-rust-core.md): Wire construye `core-crypto` sobre OpenMLS, con bindings FFI para iOS y Android, y modela cada cliente como leaf. La duda sobre plataformas móviles tiene una respuesta empírica favorable, sin que ello sustituya las pruebas propias.

## 4. Puntos abiertos con respuesta estándar disponible

Los documentos dejan varios formatos abiertos «para no diseñar criptografía ad hoc». Existen candidatos revisados que cierran cada uno sin construcciones propias:

| Punto abierto | Candidato | Motivo |
|---|---|---|
| Serialización firmada de objetos propios ([PROTOCOL §1](PROTOCOL.md#1-capas-y-responsabilidades)) | COSE_Sign1 (RFC 9052) sobre CBOR determinista (RFC 8949 §4.2) | Evita definir un esquema propio de contexto + versión + bytes; Ed25519 es suite COSE estándar |
| Archivo de historial y kit ([PROTOCOL §9](PROTOCOL.md#9-transferencia-y-archivo-de-historial)) | Formato `age` con su implementación Rust | Formato revisado, con derivación de clave y cifrado streaming |
| Adjuntos grandes y chunking ([PROTOCOL §7](PROTOCOL.md#7-adjuntos)) | Construcción STREAM de `age` | Resuelve el chunking que se aplaza; el límite de 25 MiB deja de ser necesario por motivos criptográficos |
| Canal de vinculación de dispositivos ([PROTOCOL §8](PROTOCOL.md#8-añadir-retirar-y-recuperar-dispositivos)) | Handshake Noise XX o IK mediante el crate `snow`; QR con clave efímera y código corto de confirmación del transcript | Patrón equivalente al enlace de dispositivos de Signal; Noise es un framework revisado |
| Redundancia futura ([ADR-007](adr/ADR-007-optional-realm-redundancy.md)) | Varios relays independientes con varios `RouteBundle` por dispositivo | Coherente con que la verdad vive en los clientes y las entregas son idempotentes; evita replicación con líder y consenso. ADR-007 lo menciona de pasada y merece ser la opción preferente |

## 5. Inconsistencias menores del texto

- **Versiones de edición.** README, ARCHITECTURE y THREAT_MODEL están en v0.3; PROTOCOL y DOMAIN_MODEL en v0.2. Conviene alinearlas o explicar en el índice que no todos los documentos cambiaron.
- **Uso de «domain».** [DOMAIN_MODEL §1](DOMAIN_MODEL.md#1-vocabulario-y-propiedad) define `identity_id = hash(domain, version, root_public_key)` con «domain» como separación de dominio, mientras [ARCHITECTURE §3](ARCHITECTURE.md#3-identidad-acceso-y-pertenencia) afirma que el dominio no forma parte de la identidad. Renombrar a `domain_separator` elimina la ambigüedad.
- **Validez temporal sin reloj confiable.** Las credenciales tienen `validity`, pero [PROTOCOL §2](PROTOCOL.md#2-versionado-y-objetos) declara que no hay tiempo confiable. Falta definir cómo trata un cliente offline una credencial aparentemente caducada.
- **Versión sin negociación.** La política de rechazar versiones mayores desconocidas implica que un familiar que no actualiza deja de comunicarse con el resto. Es una decisión correcta, pero debe aparecer en la matriz de recuperación de [ADR-006](adr/ADR-006-local-first-recovery-first.md) como incidente operativo con procedimiento.
- **PCS y coordinador.** Véase 3.1: la dependencia de disponibilidad debe constar en [THREAT_MODEL §4](THREAT_MODEL.md#4-garantías-con-condiciones).

## 6. Acciones propuestas antes de v0.4

1. Sustituir el coordinador fijo por un sucesor determinista en [ADR-002](adr/ADR-002-mls.md) y [PROTOCOL §5](PROTOCOL.md#cambios-orden-y-particiones), o justificar por qué se mantiene.
2. Abrir un ADR sobre notificaciones en iOS y Android con la decisión de pasarela, firma y proceso de extensión.
3. Añadir una estimación de esfuerzo por fase y redefinir la fase 0 como CLI de escritorio.
4. Adoptar COSE_Sign1, `age` y Noise como candidatos por defecto en [PROTOCOL §10](PROTOCOL.md#10-gates-antes-de-declarar-v1), sujetos al spike.
5. Corregir las inconsistencias de la sección 5.
