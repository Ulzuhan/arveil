# Arveil documentation

Arveil is a self-hosted, end-to-end encrypted messenger for families and
small circles of trust. A Go relay moves encrypted envelopes; a Rust core on
each device owns identity, MLS, local storage and recovery; Flutter apps for
macOS and Android sit on top of that core. These pages explain how to run it,
how it is designed and what has been verified.

*Versión en español: [es/README.md](es/README.md)*

**Status (September 26, 2026).** The relay, the Rust core and the CLI are
complete through Phase 4. The apps implement milestones M3b.0 to M3b.4, and
the next step is a limited macOS and Android beta (M3b.5). No release has been
published and the project has not been independently audited. Each ADR
declares its own status; "MUST" states a design requirement, and the
[platform record](PLATFORMS.md) says which requirements have been tested.

## Where to start

| I want to… | Read |
|---|---|
| Install the app after an invitation | The website's [step-by-step guide](https://arveil.kaicorplabs.com/install/) |
| Try Arveil | [Install and try](INSTALLATION.md) |
| Run a relay for my family | [Running a realm](OPERATIONS.md) · [Rootless Podman](PODMAN.md) · [Cloudflare Tunnel](TUNNEL.md) |
| Build or package the apps | [Client packages](CLIENT_RELEASES.md) · [Signed Android updates](CLIENT_UPDATES.md) · [Flutter client README](https://github.com/Ulzuhan/arveil/blob/main/clients/flutter/README.md) |
| Understand the security | [Threat model](THREAT_MODEL.md) · [Protocol](PROTOCOL.md) · [Architecture](ARCHITECTURE.md) |
| Follow the apps | [Phase 3b plan](PHASE3B.md) · [Implementation record](CLIENT_FOUNDATION.md) · [Client design](CLIENT_DESIGN.md) · [Platform record](PLATFORMS.md) |
| Contribute | [Contributing guide](https://github.com/Ulzuhan/arveil/blob/main/CONTRIBUTING.md) · [Security policy](https://github.com/Ulzuhan/arveil/blob/main/SECURITY.md) |

## Document map

### Using and operating

| Document | Contents |
|---|---|
| [Install and try](INSTALLATION.md) | Server, macOS and Android routes, current availability and installation acceptance |
| [Running a realm](OPERATIONS.md) | Install, addresses and tunnels, limits, health and metrics, backups, restore and upgrades |
| [Rootless Podman](PODMAN.md) | A private-network relay with SSH, Tailscale and persistent rootless Podman |
| [Cloudflare Tunnel](TUNNEL.md) | Opening that private relay to the Internet through a tunnel and a local proxy that verifies client addresses |
| [Client packages](CLIENT_RELEASES.md) | Building, auditing and publishing the macOS ZIP and Android APK |
| [Signed Android updates](CLIENT_UPDATES.md) | The opt-in update check in the Android app: signing key, signed feed, publishing and what the app verifies |

### Design

| Document | Contents |
|---|---|
| [Architecture](ARCHITECTURE.md) | Components, boundaries, deployment, access paths, scope and phases |
| [Threat model](THREAT_MODEL.md) | Assets, adversaries, what the server knows, conditional guarantees and invariants I-01 to I-13 |
| [Protocol](PROTOCOL.md) | Bootstrap, transport, MLS groups, durable delivery, frame catalog and recovery |
| [Domain model](DOMAIN_MODEL.md) | Entities, key lifecycle, server schema, local atomicity and state machines |

### Decisions

| Record | Decision |
|---|---|
| [ADR-001](adr/ADR-001-go-server-rust-core.md) | Go server and a secure Rust core |
| [ADR-002](adr/ADR-002-mls.md) | MLS for conversations and devices |
| [ADR-003](adr/ADR-003-zero-trust-server.md) | A server trusted with neither content nor identity |
| [ADR-004](adr/ADR-004-sqlite-single-binary.md) | SQLite, the filesystem and a single server binary |
| [ADR-005](adr/ADR-005-cryptographic-identity.md) | Cryptographic identity and authorized devices |
| [ADR-006](adr/ADR-006-local-first-recovery-first.md) | Local-first, recovery-first, explicit history |
| [ADR-007](adr/ADR-007-optional-realm-redundancy.md) | Optional redundancy after V1; independent relays preferred |
| [ADR-008](adr/ADR-008-carrier-independent-transport.md) | Noise channel, signed endpoint list, access over LAN, tailnet, tunnel or Internet |
| [ADR-009](adr/ADR-009-flutter-first.md) | Flutter first for the apps (accepted) |
| [ADR-010](adr/ADR-010-distribution-and-updates.md) | Distribution and signed, opt-in updates outside the app stores (accepted for Android; proposed for macOS) |
| [ADR-011](adr/ADR-011-shared-display-names.md) | Names people choose for themselves, shared end to end with their conversations (proposed) |
| [ADR-012](adr/ADR-012-qr-codes-and-links.md) | QR codes and links to join, link devices and add contacts; verification as a separate, optional step (proposed) |
| [ADR-013](adr/ADR-013-realm-administration-from-the-app.md) | Realm roles and administration from the app, with the host as the last resort (proposed) |

### Apps

| Document | Contents |
|---|---|
| [Phase 3b plan](PHASE3B.md) | Milestones M3b.0 to M3b.8 and their acceptance criteria |
| [Implementation record](CLIENT_FOUNDATION.md) | What each change implemented, its evidence and its limits |
| [Client design](CLIENT_DESIGN.md) | Visual system, personalization and the redesign plan |
| [Platform record](PLATFORMS.md) | Dated acceptance runs: device, system, commit and result |

### Plans, reviews and evidence

| Document | Contents |
|---|---|
| Phase plans [0](PHASE0.md) · [1](PHASE1.md) · [2](PHASE2.md) · [3](PHASE3.md) · [4](PHASE4.md) | Milestones, exit conditions and results of each completed phase |
| [Viability review v0.3](REVIEW-v0.3.md) | External-style review with verified references and open risks |
| [MLS library comparison](spikes/M0.5-mls-library-comparison.md) | The M0.5 spike behind choosing mls-rs |
| [Demo transcript](evidence/demo-transcript.txt) · [Q3 capture](evidence/q3-capture-excerpt.txt) | The Phase 0 demo run, and what a TLS-terminating proxy saw of the Noise channel (Q3) |
| [Noise inside a Cloudflare Tunnel](articles/noise-inside-a-cloudflare-tunnel.md) · [No rooms table](articles/no-rooms-table.md) | Design notes (drafts) |

---

The sections below are the historical design record from September 2026.
They explain how the design reached its current shape; the documents above
describe what is true today.

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
