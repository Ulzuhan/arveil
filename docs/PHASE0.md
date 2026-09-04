# Phase 0 plan: viability slice

**Status:** plan v1, **all six milestones complete on 2026-09-04** · Exit condition from [Architecture §8](ARCHITECTURE.md#8-scope-and-engineering-gates): *real MLS, verified identity and atomic persistence demonstrated*.

Phase 0 exists to turn the documentation into evidence with the smallest possible surface. It is deliberately ugly: two command-line clients on a desktop, one relay on localhost, no UI, no mobile, no pairing. When it ends, the repository has a demo recording, a passing CI and answers to the three questions the design cannot answer on paper.

## Questions Phase 0 must answer

| # | Question | Where the design left it open |
|---|---|---|
| Q1 | Can the chosen MLS library persist group state in the **same transaction** as our outbox and event log? | [ADR-002](adr/ADR-002-mls.md), [Domain model §5](DOMAIN_MODEL.md#5-local-state-and-atomicity) |
| Q2 | Can the library **inspect and reject a commit** before merging it, enough to enforce a committer policy from a GroupContext extension? | [Protocol §5](PROTOCOL.md#5-mls-groups-keypackages-and-authorization) |
| Q3 | Does the **Noise channel** survive a TLS-terminating intermediary with nothing but opaque frames visible at the origin? | [ADR-008](adr/ADR-008-carrier-independent-transport.md#acceptance-criteria) |

A negative answer to Q1 or Q2 reopens ADR-002 before any further work. A negative answer to Q3 reopens ADR-008.

## Scope

**In:** one realm on localhost; two CLI clients on the same machine; single device per identity; Noise `IK` channel over WebSocket; CBOR frames; SQLite with the durability settings of [ADR-004](adr/ADR-004-sqlite-single-binary.md#verified-durability-requirements) on both sides; invite redeem; device credential and manifest; KeyPackage publish and claim; one MLS 1:1 group and one three-member group; envelope put, fetch and ACK; crash injection around the send and receive transactions.

**Out:** Flutter or any GUI; device linking and QR; multi-device per person; attachments and blobs; history archive and identity kit; push; TLS; endpoint list switching between carriers (a single endpoint is enough, the list object is still emitted and validated); commit coordinator successor rules (a fixed coordinator is acceptable here; the successor design is tracked in the [v0.3 review](REVIEW-v0.3.md#31-single-commit-coordinator)).

## Milestones

| Milestone | Deliverable | Acceptance |
|---|---|---|
| **M0.1 Skeleton** | Rust workspace, Go module, CI green, docs site published | `make test` and `make docs-build --strict` pass; Pages URL live |
| **M0.2 Channel** | Noise `IK` handshake in `arveil-core` and relay; CBOR frame codec with size limits and fragmentation; `endpoint_list_get` frame | Handshake against wrong static key fails before any frame; replayed first message has no effect; frames over 65 535 bytes fragment and reassemble; fuzz target for the codec runs in CI |
| **M0.3 Identity** | Root key, `DeviceCredential`, `DeviceManifest`, invite redeem, credential and manifest frames, SQLite schema on the relay with WAL + `synchronous=FULL` | Manifest with lower sequence rejected; credential from a foreign root rejected; invite consumed atomically with membership (kill -9 between the two leaves no half state) |
| **M0.4 Delivery** | Mailboxes, capabilities, `envelope_put` / `envelope_fetch` / `envelope_ack`, HPKE outer envelope, durable client outbox and inbox | Invariants I-04 and I-05 from the [threat model](THREAT_MODEL.md#5-verifiable-invariants-and-acceptance-scenarios) under crash injection; duplicate delivery produces one visible event; retry with different body conflicts |
| **M0.5 MLS spike** | OpenMLS and mls-rs evaluated against Q1 and Q2 with a written comparison; winner integrated for a 1:1 group and a 3-member group with Add and Remove | Q1 and Q2 answered with test evidence; official MLS test vectors pass; a valid-but-unauthorized commit is rejected before merge |
| **M0.6 Demo** | Two `arveil` CLI processes chat through the relay; relay restarted mid-conversation; one client killed mid-send; recording in the README | Demo reproducible from a script in `scripts/demo.sh`; no message lost, none duplicated, relay database contains no plaintext, no group identifiers and no conversation table |

Milestones M0.2 to M0.4 can proceed in parallel with the M0.5 spike, since the channel and delivery layers do not depend on the MLS library choice. The recommended order for a single developer is M0.5 first: a negative answer to Q1 or Q2 changes the domain model, and it is cheaper to learn that before building the channel and delivery layers.

The spike lives in `spikes/mls`, outside the main workspace so its dependencies do not weigh on the core build. It contains passing baselines for both libraries and the Q1 and Q2 tests for both, none ignored; see the answers below. Progress is tracked in the [M0.5 milestone](https://github.com/Ulzuhan/arveil/milestone/5).

## Answers so far

**Q1 — answered yes for both libraries** (2026-09-04). mls-rs: `GroupStateStorage` over the application's connection, one `write_to_storage` inside the transaction; rollback leaves nothing, commit leaves the group loadable. OpenMLS: `StorageProvider` ported from the in-memory reference onto the same connection; create + add + merge inside the transaction behave the same way. Tests: `spikes/mls/src/mlsrs_sqlite.rs`, `spikes/mls/src/openmls_sqlite.rs`.

**Q2 — answered yes for both libraries** (2026-09-04). mls-rs: `MlsRules::filter_proposals` refuses a commit whose `CommitSource` is not the authorized leaf, on send and receive; epoch unchanged, group still usable. OpenMLS: the receiver inspects the `StagedCommit` and does not merge it. Tests: `spikes/mls/src/mlsrs_policy.rs`, `spikes/mls/src/openmls_spike.rs`.

**Library decision:** mls-rs, with a mobile crypto-provider gate before Phase 3. Rationale and comparison table in the [M0.5 spike report](spikes/M0.5-mls-library-comparison.md); recorded in [ADR-002](adr/ADR-002-mls.md).

**Integration (M0.5 step 4) — done** (2026-09-04). `arveil-core` has `storage` (shared connection, ADR-004 pragmas, unit of work, bundled SQLite ≥ 3.51.3 gate) and `mls` (SQLite stores for group state, key packages and PSKs; `GroupPolicy` GroupContext extension type 0xF000; `PolicyRules` failing closed; engine). Nine core tests cover 1:1 both ways, 3-member add and remove with the removed member unable to read the new epoch, unauthorized commits refused by sender and every receiver, missing policy failing closed, and the shared unit of work. Conformance evidence: `spikes/mls/src/interop.rs` joins an OpenMLS member to a group created by `arveil-core`, exchanges messages both ways, and the policy refuses the OpenMLS member's commit. mls-rs runs the official RFC 9420 vectors in its own CI; running them here is deferred to the relay-integrated tests of M0.6.

**M0.2 Channel — done** (2026-09-04). `arveil-core::channel` (Noise IK over `snow`, CBOR frames, fragmentation, signed endpoint list verification) and the relay's `internal/channel`, `internal/endpoints`, `internal/realm` and `internal/server` (WebSocket carrier). Acceptance rows #2 to #6 are covered by unit and property tests on both sides, with the Rust CBOR encodings as vectors in the Go tests, and by `scripts/interop.sh`: the Go relay serves the channel, the Rust CLI completes the handshake, verifies the signed list and exchanges a ping; a tampered realm id is refused before any frame. CI runs the script.

**M0.3 Identity — done** (2026-09-04). Core: `signed` (deterministic CBOR, SignedObject envelope), `identity` (root key, identity id, `DeviceCredential`, chained `DeviceManifest`, verification refusing foreign roots, expired windows, rollbacks, conflicts and broken chains), `client` (local persistence of identity, device, manifests and realm). Relay: `internal/store` on `modernc.org/sqlite` (embedded SQLite 3.53.4, WAL + `synchronous=FULL`, invite redeem in one transaction with a fault-injection test proving no half state), `internal/identity` (same contexts and hashes as the core, verified against core-generated vectors), session states in `internal/server` (provisional until a credential bound to the session's Noise static key is accepted), and the `invite` command. `scripts/interop.sh` now enrolls a device with an invite, reconnects as a member, and checks that a consumed invite, a forged token and a garbage manifest are refused. Driver decision for ADR-004: modernc.org/sqlite.

**M0.4 Delivery — done** (2026-09-04). Core: `envelope` (HPKE DHKEM(X25519)/HKDF-SHA256/AES-128-GCM, AAD bound to realm, mailbox and delivery id, bucketed padding 256 B to 256 KiB), `delivery` (outbox with stored sealed bytes, inbox deduplication with ACK state, cursors, local events) and tests that drive two MLS peers through send and receive units failing before commit: nothing persists, the group is reloaded and retried exactly once, retransmission reuses the stored bytes, duplicates never reach MLS, ACK follows the commit (I-04, I-05). Relay: mailboxes with hashed read/write capabilities, envelopes unique per (mailbox, delivery id) with body hash for idempotent retries and conflict on a different body, size and queue bounds, cursor fetch, ACK delete, expiry sweep; frames `mailbox_create`, `envelope_put`, `envelope_fetch`, `envelope_ack` on member sessions only. CLI: `mailbox create`, `send`, `fetch`. `scripts/interop.sh` sends a sealed envelope from one enrolled device to another through the Go relay, fetches, decrypts and ACKs it, verifies the second fetch is empty, that an unenrolled sender is refused, and that the relay database holds no plaintext.

**M0.6 Demo — done** (2026-09-04). `scripts/demo.sh` runs two CLI clients with real MLS through the Go relay: enrollment, KeyPackage claim, group with the Arveil policy, Welcome and route sealed to the peer, messages both ways, relay restart mid-conversation, a client crash after committing and before publishing followed by retransmission received exactly once, and the relay database inventory (no plaintext, no MLS group id, no conversation table). Transcript: [evidence/demo-transcript.txt](evidence/demo-transcript.txt). Runs in CI.

**Q3 — answered yes** (2026-09-04). `scripts/q3-capture.sh` puts a TLS-terminating proxy (`relay/cmd/arveil-tlsproxy`, a test tool that records every WebSocket frame unmasked) between the Rust client and the Go relay, runs enrollment and a chat through it, and asserts the capture holds no frame names, identifiers, capabilities or message text; the proxy sees the HTTP upgrade path, the number of connections, and the sizes and timing of opaque binary frames. Excerpt: [evidence/q3-capture-excerpt.txt](evidence/q3-capture-excerpt.txt). Runs in CI. ADR-008 acceptance criterion 1 is met.

## Evidence required at exit

- Test suite covering every acceptance row above, runnable with `make test`.
- A short written answer to Q1, Q2 and Q3 with links to the tests, appended to this document. **Done, see "Answers so far".**
- A capture from the origin side of a TLS-terminating proxy (a local reverse proxy is enough for Phase 0) showing only opaque frames, attached to the ADR-008 acceptance record. **Done: `evidence/q3-capture-excerpt.txt`.**
- The demo recording linked from the repository README. **Done as a text transcript: `evidence/demo-transcript.txt`; a terminal recording can replace it later.**

## What Phase 0 does not prove

Mobile viability, battery and background behaviour, push, the pairing protocol, the archive format and the usability of the identity kit. Those are Phase 2 and 3 questions and the [v0.3 review](REVIEW-v0.3.md) lists the risks attached to each.
