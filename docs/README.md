# Arveil — architecture documentation

**Current client status:** see the [implemented client foundation](CLIENT_FOUNDATION.md), [Flutter implementation plan](PHASE3B.md) and [accepted ADR-009](adr/ADR-009-flutter-first.md). These updates supersede the earlier client proposals below. Flutter is selected; `mls-rs` is already in use. No graphical client exists yet. Earlier unresolved-item lists are historical, not the current backlog.

**Status:** design proposal v0.4 · **Date:** 2026-09-04 · **Language:** English.

*Versión en español: [es/README.md](es/README.md)*

Self-hosted messenger for family, friends and small circles of trust. A Go server transports and temporarily retains encrypted data; a Rust core on each client controls identity, MLS, local storage and recovery. The differentiating goal is to combine privacy with simple household operation and understandable recovery.

These documents describe the current bet, not an implemented product, a finished interoperable specification or audited security. Each ADR declares its own status; ADR-009 is accepted. The application foundation is implemented, while the GUI remains pending. "MUST" expresses a design requirement; it does not certify that code exists to satisfy it.

## Map and reading order

| Document | Content |
|---|---|
| [CLIENT_FOUNDATION.md](CLIENT_FOUNDATION.md) | Implemented changes, evidence and limitations |
| [PHASE3B.md](PHASE3B.md) | Flutter plan and acceptance criteria |
| [ADR-009](adr/ADR-009-flutter-first.md) | Accepted Flutter-first decision |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Components, boundaries, deployment, scope and phases |
| [THREAT_MODEL.md](THREAT_MODEL.md) | Assets, adversaries, metadata, conditional guarantees and tests |
| [PROTOCOL.md](PROTOCOL.md) | Flows, transport contracts, MLS, delivery and recovery |
| [DOMAIN_MODEL.md](DOMAIN_MODEL.md) | Entities, keys, persistence, invariants and states |
| [ADR-001](adr/ADR-001-go-server-rust-core.md) | Go server and secure Rust core |
| [ADR-002](adr/ADR-002-mls.md) | MLS for conversations and devices |
| [ADR-003](adr/ADR-003-zero-trust-server.md) | Untrusted server for content and identity |
| [ADR-004](adr/ADR-004-sqlite-single-binary.md) | SQLite, filesystem and a single server binary |
| [ADR-005](adr/ADR-005-cryptographic-identity.md) | Cryptographic identity and authorized devices |
| [ADR-006](adr/ADR-006-local-first-recovery-first.md) | Local-first, recovery and explicit history |
| [ADR-007](adr/ADR-007-optional-realm-redundancy.md) | Optional redundancy after V1; independent relays as the preferred direction |
| [ADR-008](adr/ADR-008-carrier-independent-transport.md) | Noise channel, signed endpoint list and access over LAN, tailnet, tunnel or Internet |
| [REVIEW-v0.3](REVIEW-v0.3.md) | External viability review: verified references, risks and proposed actions |



## Historical v0.4 design background

The application foundation and Flutter plan describe current status; the candidates and tasks below belong to the original proposal.

The chosen direction is Go + Rust, MLS, identity independent of the realm, delivery through opaque mailboxes, a carrier-independent Noise channel with a signed endpoint list, SQLite + filesystem and client-driven recovery. Flutter is the interface candidate; OpenMLS is the first candidate MLS library and mls-rs the alternative to evaluate. No library choice implies an audit of the application.

The details added in this edition —commit coordinator, direct authorization by the root key, HPKE envelope and initial retention values— are proposals to close ambiguities in the conversation, not previously confirmed decisions or MLS requirements.

Before freezing the protocol, the following must be resolved: transactional MLS persistence, commit authorization, signed serialization, device linking channel, archive and backup profile, revocation under partitions and bindings for the initial platforms. The documents indicate conservative behavior for those cases.

The current revision replaces the earlier proposals of a Rust backend with PostgreSQL by a Go server with SQLite. It does not include global federation, calls, blockchain, home-grown cryptography or a requirement for external data services.

The v0.3 edition incorporates, as a **future and optional possibility**, redundancy of the same realm across machines or households. [ADR-007](adr/ADR-007-optional-realm-redundancy.md) collects alternatives, limits and evaluation criteria. Standalone remains the V1 profile; no cluster, load balancer or replication engine is selected or promised.

## References and traceability

The source of intent is the conversation "Plantear arquitectura de idea", in particular its second proposal. Its figures on competitors, release dates and claims of superiority are not reproduced without verification.

**Extension v0.4 — 2026-09-04:** [ADR-008](adr/ADR-008-carrier-independent-transport.md) is added after finding that the previous design relied on end-to-end TLS for the confidentiality of sessions and capabilities and for the realm pin, which does not hold with Cloudflare Tunnel or other intermediaries that terminate TLS. Changes: Noise `IK` channel between device and realm inside WebSocket; the API moves from HTTP routes to CBOR frames; `DeviceCredential` replaces the Ed25519 transport key with an X25519 Noise key; the realm adds a Noise key and a signed `RealmEndpointList`; TLS remains as an optional layer; the LAN no longer needs certificates; ADR-007 adopts independent relays as the preferred direction. Documents at v0.4: README, ARCHITECTURE, THREAT_MODEL, PROTOCOL, DOMAIN_MODEL, ADR-007 and ADR-008. ADR-001 through ADR-006 do not change. The [v0.3 review](REVIEW-v0.3.md) remains as a dated document; its actions on the coordinator, push on iOS and effort remain open.

**Extension v0.3 — 2026-09-04:** ADR-007 is added and linked from the architecture, threat model and ADR-004. Its redundancy references were consulted in the conversation before this extension; the technology choice is deferred.

**Online review v0.2 — 2026-09-04:** the official Go and Rust releases, the MLS/HPKE RFCs, the SQLite documentation and the OpenMLS and mls-rs repositories were consulted. This review replaces the v0.1 notice about lack of access. It confirms the Go + Rust + MLS + SQLite direction, but incorporates concrete requirements on durability, dependency selection and commit handling. It is not a code audit or an interoperability test.

Changes with respect to v0.1:

- Verified candidate toolchain versions: Go 1.27.1 and Rust 1.98.1; details and sources in [ADR-001](adr/ADR-001-go-server-rust-core.md).
- SQLite: mandatory WAL-reset fix and explicit durability configuration; [ADR-004](adr/ADR-004-sqlite-single-binary.md#verified-durability-requirements).
- Core: distinguish compiled platforms from tested platforms and exclude sensitive debug features; [ADR-001](adr/ADR-001-go-server-rust-core.md) and [ADR-002](adr/ADR-002-mls.md).
- Protocol: separate prepared commit from accepted commit and specify loss/revocation of the coordinator; [PROTOCOL](PROTOCOL.md#changes-ordering-and-partitions).

Still open: pairing, the final coordination policy, the transactional provider, the concrete library versions and the archive/recovery format. The OpenMLS manual pages could not be retrieved; no capabilities are attributed to its API that we have not verified. The links to EdDSA, CBOR and SQLCipher are complementary references pending a specific review.

| Primary reference | Use and scope of review |
|---|---|
| [RFC 9420 — MLS](https://www.rfc-editor.org/rfc/rfc9420) | Group protocol, epochs, KeyPackages and security |
| [RFC 9750 — MLS Architecture](https://www.rfc-editor.org/rfc/rfc9750) | Responsibilities of the Authentication Service and Delivery Service |
| [RFC 9180 — HPKE](https://www.rfc-editor.org/rfc/rfc9180) | Outer encryption per recipient; not person authentication on its own |
| [RFC 8032 — EdDSA](https://www.rfc-editor.org/rfc/rfc8032) | Complementary reference: identity signatures |
| [RFC 8949 — CBOR](https://www.rfc-editor.org/rfc/rfc8949) | Complementary reference: candidate deterministic serialization |
| [OpenMLS](https://github.com/openmls/openmls) / [manual](https://book.openmls.tech/) | README reviewed; manual not retrieved; candidate subject to integration |
| [mls-rs](https://github.com/awslabs/mls-rs) | Alternative for comparing providers, platforms and persistence |
| [SQLite WAL](https://sqlite.org/wal.html) / [synchronous](https://sqlite.org/pragma.html#pragma_synchronous) / [Online Backup API](https://sqlite.org/backup.html) | Persistence and backup requirements; reviewed |
| [Go releases](https://go.dev/doc/devel/release) / [Rust 1.98.1](https://blog.rust-lang.org/2026/09/03/Rust-1.98.1/) | Verified versions; project compatibility pending |
| [SQLCipher](https://www.zetetic.net/sqlcipher/) | Complementary reference: integration and base version pending |
| [Noise Protocol Framework](https://noiseprotocol.org/noise.html) | Device↔realm channel of ADR-008; `IK` pattern; `snow` (Rust) and `flynn/noise` (Go) implementations pending version pinning |

Our product decisions are not attributed to these standards: the identity model, the capabilities, the commit coordinator and the recovery flows are proposals of this application that require their own review.
