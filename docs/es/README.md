# Arveil — documentación de arquitectura

**Estado actual del cliente:** la [base implementada](CLIENT_FOUNDATION.md), el [plan Flutter](PHASE3B.md) y la [ADR-009 aceptada](adr/ADR-009-flutter-first.md) actualizan las propuestas anteriores. Flutter está elegido y `mls-rs` ya se utiliza. Todavía no existe cliente gráfico. Las listas históricas de cuestiones abiertas que aparecen más abajo no son el backlog actual.

**Estado:** propuesta de diseño v0.4 · **Fecha:** 2026-09-04 · **Idioma:** español.

*English version: [../README.md](../README.md)*

Messenger autohosteado para familiares, amigos y pequeños círculos de confianza. Un servidor Go transporta y conserva temporalmente datos cifrados; un core Rust en cada cliente controla identidad, MLS, almacenamiento local y recuperación. El objetivo diferencial es combinar privacidad con una operación doméstica sencilla y una recuperación comprensible.

Estos documentos describen la apuesta actual, no un producto implementado, una especificación interoperable terminada ni una seguridad auditada. Cada ADR declara su estado; ADR-009 está aceptada. La base de aplicación ya está implementada, pero la GUI está pendiente. «DEBE» expresa un requisito del diseño; no certifica que exista código que lo cumpla.

## Mapa y orden de lectura

| Documento | Contenido |
|---|---|
| [CLIENT_FOUNDATION.md](CLIENT_FOUNDATION.md) | Cambios implementados, evidencia y límites |
| [PHASE3B.md](PHASE3B.md) | Plan Flutter y criterios de aceptación |
| [ADR-009](adr/ADR-009-flutter-first.md) | Flutter primero, decisión aceptada |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Componentes, límites, despliegue, alcance y fases |
| [THREAT_MODEL.md](THREAT_MODEL.md) | Activos, adversarios, metadatos, garantías condicionadas y pruebas |
| [PROTOCOL.md](PROTOCOL.md) | Flujos, contratos de transporte, MLS, entrega y recuperación |
| [DOMAIN_MODEL.md](DOMAIN_MODEL.md) | Entidades, claves, persistencia, invariantes y estados |
| [ADR-001](adr/ADR-001-go-server-rust-core.md) | Servidor Go y core seguro Rust |
| [ADR-002](adr/ADR-002-mls.md) | MLS para conversaciones y dispositivos |
| [ADR-003](adr/ADR-003-zero-trust-server.md) | Servidor no confiable para contenido e identidad |
| [ADR-004](adr/ADR-004-sqlite-single-binary.md) | SQLite, filesystem y un binario servidor |
| [ADR-005](adr/ADR-005-cryptographic-identity.md) | Identidad criptográfica y dispositivos autorizados |
| [ADR-006](adr/ADR-006-local-first-recovery-first.md) | Local-first, recuperación e historial explícito |
| [ADR-007](adr/ADR-007-optional-realm-redundancy.md) | Redundancia opcional después de V1; relays independientes como dirección preferente |
| [ADR-008](adr/ADR-008-carrier-independent-transport.md) | Canal Noise, lista firmada de endpoints y acceso por LAN, tailnet, túnel o Internet |
| [REVIEW-v0.3](REVIEW-v0.3.md) | Revisión de viabilidad externa: referencias verificadas, riesgos y acciones propuestas |



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
