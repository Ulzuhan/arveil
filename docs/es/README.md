# Documentación de Arveil

Arveil es un mensajero autoalojado y cifrado de extremo a extremo para
familias y pequeños círculos de confianza. Un relay en Go transporta sobres
cifrados; un núcleo Rust en cada dispositivo se encarga de la identidad, MLS,
el almacenamiento local y la recuperación; las apps Flutter para macOS y
Android funcionan sobre ese núcleo. Estas páginas explican cómo ponerlo en
marcha, cómo está diseñado y qué se ha verificado.

*English version: [../README.md](../README.md)*

**Estado (26 de septiembre de 2026).** El relay, el núcleo Rust y la CLI
están completos hasta la fase 4. Las apps implementan los hitos M3b.0 a
M3b.4, y el siguiente paso es una beta limitada para macOS y Android (M3b.5).
No hay ninguna versión publicada y el proyecto no ha pasado una auditoría
independiente. Cada ADR declara su estado; «DEBE» expresa un requisito del
diseño, y la [matriz de plataformas](PLATFORMS.md) indica qué requisitos se
han probado.

## Por dónde empezar

| Quiero… | Lee |
|---|---|
| Instalar la app tras recibir una invitación | La [guía paso a paso](https://arveil.kaicorplabs.com/es/instalar/) de la web |
| Probar Arveil | [Instalar y probar](INSTALLATION.md) |
| Poner un relay para mi familia | [Poner en marcha un realm](OPERATIONS.md) · [Podman sin root](../PODMAN.md) (en inglés) · [Cloudflare Tunnel](TUNNEL.md) |
| Compilar o empaquetar las apps | [Paquetes del cliente](CLIENT_RELEASES.md) · [Actualizaciones Android firmadas](CLIENT_UPDATES.md) · [README del cliente Flutter](https://github.com/Ulzuhan/arveil/blob/main/clients/flutter/README.md) (en inglés) |
| Entender la seguridad | [Modelo de amenazas](THREAT_MODEL.md) · [Protocolo](PROTOCOL.md) · [Arquitectura](ARCHITECTURE.md) |
| Seguir las apps | [Plan de la fase 3b](PHASE3B.md) · [Registro de implementación](CLIENT_FOUNDATION.md) · [Diseño del cliente](CLIENT_DESIGN.md) · [Matriz de plataformas](PLATFORMS.md) |
| Contribuir | [Guía de contribución](https://github.com/Ulzuhan/arveil/blob/main/CONTRIBUTING.md) · [Política de seguridad](https://github.com/Ulzuhan/arveil/blob/main/SECURITY.md) (en inglés) |

## Mapa de documentos

### Uso y administración

| Documento | Contenido |
|---|---|
| [Instalar y probar](INSTALLATION.md) | Rutas para servidor, macOS y Android, disponibilidad actual y aceptación de la instalación |
| [Poner en marcha un realm](OPERATIONS.md) | Instalación, direcciones y túneles, límites, salud y métricas, copias, restauración y actualizaciones |
| [Podman sin root](../PODMAN.md) (en inglés) | Un relay en red privada con SSH, Tailscale y Podman sin root persistente |
| [Cloudflare Tunnel](TUNNEL.md) | Abrir ese relay privado a Internet con un túnel y un proxy local que verifica las direcciones de los clientes |
| [Paquetes del cliente](CLIENT_RELEASES.md) | Compilar, auditar y publicar el ZIP de macOS y el APK de Android |
| [Actualizaciones Android firmadas](CLIENT_UPDATES.md) | La búsqueda opcional de actualizaciones de la app Android: clave de firma, canal firmado, publicación y qué verifica la app |

### Diseño

| Documento | Contenido |
|---|---|
| [Arquitectura](ARCHITECTURE.md) | Componentes, límites, despliegue, vías de acceso, alcance y fases |
| [Modelo de amenazas](THREAT_MODEL.md) | Activos, adversarios, qué sabe el servidor, garantías condicionadas e invariantes I-01 a I-13 |
| [Protocolo](PROTOCOL.md) | Arranque, transporte, grupos MLS, entrega duradera, catálogo de frames y recuperación |
| [Modelo de dominio](DOMAIN_MODEL.md) | Entidades, ciclo de vida de las claves, esquema del servidor, atomicidad local y máquinas de estados |

### Decisiones

| Registro | Decisión |
|---|---|
| [ADR-001](adr/ADR-001-go-server-rust-core.md) | Servidor Go y núcleo seguro en Rust |
| [ADR-002](adr/ADR-002-mls.md) | MLS para conversaciones y dispositivos |
| [ADR-003](adr/ADR-003-zero-trust-server.md) | Un servidor al que no se confía ni el contenido ni la identidad |
| [ADR-004](adr/ADR-004-sqlite-single-binary.md) | SQLite, el sistema de archivos y un único binario de servidor |
| [ADR-005](adr/ADR-005-cryptographic-identity.md) | Identidad criptográfica y dispositivos autorizados |
| [ADR-006](adr/ADR-006-local-first-recovery-first.md) | Primero local, primero la recuperación, historial explícito |
| [ADR-007](adr/ADR-007-optional-realm-redundancy.md) | Redundancia opcional después de V1; relays independientes como dirección preferente |
| [ADR-008](adr/ADR-008-carrier-independent-transport.md) | Canal Noise, lista firmada de direcciones y acceso por LAN, tailnet, túnel o Internet |
| [ADR-009](adr/ADR-009-flutter-first.md) | Flutter primero para las apps (aceptada) |
| [ADR-010](adr/ADR-010-distribution-and-updates.md) | Distribución y actualizaciones firmadas y opcionales fuera de las tiendas (aceptada para Android; propuesta para macOS) |
| [ADR-011](adr/ADR-011-shared-display-names.md) | Nombres que cada persona elige para sí, compartidos de extremo a extremo con sus conversaciones (propuesta) |
| [ADR-012](adr/ADR-012-qr-codes-and-links.md) | Códigos QR y enlaces para unirse, vincular dispositivos y añadir contactos; la verificación como paso aparte y opcional (propuesta) |
| [ADR-013](adr/ADR-013-realm-administration-from-the-app.md) | Roles del realm y administración desde la app, con el servidor como último recurso (propuesta) |

### Apps

| Documento | Contenido |
|---|---|
| [Plan de la fase 3b](PHASE3B.md) | Hitos M3b.0 a M3b.8 y sus criterios de aceptación (texto normativo) |
| [Registro de implementación](CLIENT_FOUNDATION.md) | Qué implementó cada cambio, su evidencia y sus límites |
| [Diseño del cliente](CLIENT_DESIGN.md) | Sistema visual, personalización y plan del rediseño |
| [Matriz de plataformas](PLATFORMS.md) | Pruebas de aceptación fechadas: dispositivo, sistema, commit y resultado |

### Planes, revisiones y evidencias

| Documento | Contenido |
|---|---|
| Planes de las fases [0](../PHASE0.md) · [1](../PHASE1.md) · [2](../PHASE2.md) · [3](../PHASE3.md) · [4](../PHASE4.md) (en inglés) | Hitos, condiciones de salida y resultados de cada fase completada |
| [Revisión de viabilidad v0.3](REVIEW-v0.3.md) | Revisión de estilo externo con referencias verificadas y riesgos abiertos |
| [Comparación de bibliotecas MLS](../spikes/M0.5-mls-library-comparison.md) (en inglés) | El spike M0.5 que llevó a elegir mls-rs |
| [Transcripción de la demo](../evidence/demo-transcript.txt) · [Captura Q3](../evidence/q3-capture-excerpt.txt) | La demo de la fase 0 y lo que vio del canal Noise un proxy que termina TLS (Q3) |
| [Noise dentro de un túnel de Cloudflare](../articles/noise-inside-a-cloudflare-tunnel.md) · [Sin tabla de salas](../articles/no-rooms-table.md) (en inglés) | Notas de diseño (borradores) |

---

Las secciones siguientes son el registro histórico del diseño de septiembre
de 2026. Explican cómo llegó el diseño a su forma actual; los documentos de
arriba describen lo que es cierto hoy.

## Antecedentes de diseño v0.4 (históricos)

El estado vigente se describe en la base de aplicación y el plan Flutter; las candidaturas y tareas siguientes corresponden a la propuesta original.

La dirección elegida es Go + Rust, MLS, identidad independiente del realm, entrega por mailboxes opacos, canal Noise independiente del carrier con lista firmada de endpoints, SQLite + filesystem y recuperación desde el cliente. Flutter es el candidato de interfaz; OpenMLS es el primer candidato de biblioteca MLS y mls-rs la alternativa a evaluar. Ninguna elección de biblioteca supone una auditoría de la aplicación.

Los detalles añadidos en esta edición —coordinador de commits, autorización directa por raíz, envoltorio HPKE y valores iniciales de retención— son propuestas para cerrar ambigüedades de la conversación, no decisiones previamente confirmadas ni requisitos de MLS.

Antes de congelar el protocolo deben resolverse: persistencia MLS transaccional, autorización de commits, serialización firmada, canal de vinculación de dispositivos, perfil de archivos y backups, revocación ante particiones y bindings para las plataformas iniciales. Los documentos indican un comportamiento conservador para esos casos.

La revisión actual sustituye las propuestas anteriores de backend Rust con PostgreSQL por un servidor Go con SQLite. No incluye federación global, llamadas, blockchain, criptografía propia ni un requisito de servicios externos de datos.

La edición v0.3 incorpora como **posibilidad futura y opcional** la redundancia del mismo realm entre máquinas o domicilios. [ADR-007](adr/ADR-007-optional-realm-redundancy.md) recoge alternativas, límites y criterios de evaluación. Standalone sigue siendo el perfil de V1; no se selecciona ni se promete un clúster, balanceador o motor de réplica.

## Referencias y trazabilidad

La fuente de intención es la conversación «Plantear arquitectura de idea», en particular su segunda propuesta. No se reproducen sus cifras sobre competidores, fechas de versiones ni afirmaciones de superioridad sin verificación.

**Ampliación v0.4 — 2026-09-04:** se añade [ADR-008](adr/ADR-008-carrier-independent-transport.md) tras constatar que el diseño anterior apoyaba en TLS extremo a extremo la confidencialidad de sesiones y capabilities y el pin del realm, lo que no se cumple con Cloudflare Tunnel u otros intermediarios que terminan TLS. Cambios: canal Noise `IK` entre dispositivo y realm dentro de WebSocket; la API pasa de rutas HTTP a frames CBOR; `DeviceCredential` sustituye la clave de transporte Ed25519 por una clave Noise X25519; el realm añade clave Noise y `RealmEndpointList` firmado; TLS queda como capa opcional; la LAN deja de necesitar certificados; ADR-007 adopta relays independientes como dirección preferente. Documentos en v0.4: README, ARCHITECTURE, THREAT_MODEL, PROTOCOL, DOMAIN_MODEL, ADR-007 y ADR-008. ADR-001 a ADR-006 no cambian. La [revisión v0.3](REVIEW-v0.3.md) queda como documento fechado; sus acciones sobre coordinador, push en iOS y esfuerzo siguen abiertas.

**Ampliación v0.3 — 2026-09-04:** se añade ADR-007 y se enlaza desde arquitectura, amenazas y ADR-004. Sus referencias de redundancia se consultaron en la conversación antes de esta ampliación; la elección tecnológica queda aplazada.

**Revisión online v0.2 — 2026-09-04:** se han consultado las publicaciones oficiales de Go y Rust, los RFC de MLS/HPKE, la documentación de SQLite y los repositorios de OpenMLS y mls-rs. Esta revisión sustituye el aviso de falta de acceso de v0.1. Confirma la dirección Go + Rust + MLS + SQLite, pero incorpora requisitos concretos de durabilidad, selección de dependencias y tratamiento de commits. No es una auditoría de código ni una prueba de interoperabilidad.

Cambios respecto a v0.1:

- Versiones candidatas de toolchain verificadas: Go 1.27.1 y Rust 1.98.1; detalle y fuentes en [ADR-001](adr/ADR-001-go-server-rust-core.md).
- SQLite: corrección de WAL-reset obligatoria y configuración de durabilidad explícita; [ADR-004](adr/ADR-004-sqlite-single-binary.md#requisitos-verificados-de-durabilidad).
- Core: distinguir plataformas compiladas de plataformas probadas y excluir funciones de debug sensibles; [ADR-001](adr/ADR-001-go-server-rust-core.md) y [ADR-002](adr/ADR-002-mls.md).
- Protocolo: separar commit preparado de commit aceptado y precisar pérdida/revocación del coordinador; [PROTOCOL](PROTOCOL.md#cambios-orden-y-particiones).

Permanecen abiertos el pairing, la política final de coordinación, el provider transaccional, las versiones concretas de bibliotecas y el formato de archivos/recuperación. Las páginas del manual OpenMLS no se pudieron recuperar; no se atribuyen a su API capacidades que no hayamos comprobado. Los enlaces a EdDSA, CBOR y SQLCipher son referencias complementarias pendientes de una revisión específica.

| Referencia primaria | Uso y alcance de revisión |
|---|---|
| [RFC 9420 — MLS](https://www.rfc-editor.org/rfc/rfc9420) | Protocolo de grupos, epochs, KeyPackages y seguridad |
| [RFC 9750 — MLS Architecture](https://www.rfc-editor.org/rfc/rfc9750) | Responsabilidades del Authentication Service y Delivery Service |
| [RFC 9180 — HPKE](https://www.rfc-editor.org/rfc/rfc9180) | Cifrado exterior por destinatario; no autenticación de persona por sí solo |
| [RFC 8032 — EdDSA](https://www.rfc-editor.org/rfc/rfc8032) | Referencia complementaria: firmas de identidad |
| [RFC 8949 — CBOR](https://www.rfc-editor.org/rfc/rfc8949) | Referencia complementaria: serialización determinista candidata |
| [OpenMLS](https://github.com/openmls/openmls) / [manual](https://book.openmls.tech/) | README revisado; manual no recuperado; candidato sujeto a integración |
| [mls-rs](https://github.com/awslabs/mls-rs) | Alternativa para comparar providers, plataformas y persistencia |
| [SQLite WAL](https://sqlite.org/wal.html) / [synchronous](https://sqlite.org/pragma.html#pragma_synchronous) / [Online Backup API](https://sqlite.org/backup.html) | Requisitos de persistencia y copia; revisados |
| [Go releases](https://go.dev/doc/devel/release) / [Rust 1.98.1](https://blog.rust-lang.org/2026/09/03/Rust-1.98.1/) | Versiones verificadas; compatibilidad del proyecto pendiente |
| [SQLCipher](https://www.zetetic.net/sqlcipher/) | Referencia complementaria: integración y versión base pendientes |
| [Noise Protocol Framework](https://noiseprotocol.org/noise.html) | Canal dispositivo↔realm de ADR-008; patrón `IK`; implementaciones `snow` (Rust) y `flynn/noise` (Go) pendientes de fijar versión |

No se atribuyen a estos estándares nuestras decisiones de producto: el modelo de identidad, las capabilities, el coordinador de commits y los flujos de recuperación son propuestas de esta aplicación que requieren revisión propia.
