# Viability review — documentation v0.3

**Status:** external documentation review · **Date:** 2026-09-04 · **Scope:** the twelve documents in `docs/` in their v0.3/v0.2 edition. [Index](README.md) · [Architecture](ARCHITECTURE.md) · [Protocol](PROTOCOL.md).

*Versión en español: [es/REVIEW-v0.3.md](es/REVIEW-v0.3.md)*

This review evaluates internal coherence, accuracy of the cited references and engineering and product viability. It is not a cryptographic audit or an integration test. The recommendations are proposals for discussion; none of them modifies an ADR on its own.

## 1. Verdict

The architecture is **technically viable** and the documentation has a level of honesty and precision unusual in a v0.3 proposal. The structural decisions —Go relay without conversation semantics, shared Rust core, MLS with one leaf per device, root identity independent of the realm, SQLite in WAL and recovery split into identity kit, enrollment and archive— are solid and have precedents in production.

The viability risks are not in the cryptography. They are in three points: the **single commit coordinator**, **push on iOS** and the **size of the effort** relative to the available team. All three are detailed in section 3.

## 2. Verified references

All external claims in the documentation were checked on 2026-09-04 against their primary sources. None turned out to be incorrect.

| Claim in the documents | Source | Result |
|---|---|---|
| WAL-reset bug present from 3.7.0 through 3.51.2; fixed in 3.51.3; backports 3.44.6 and 3.50.7 ([ADR-004](adr/ADR-004-sqlite-single-binary.md)) | [sqlite.org/wal.html](https://sqlite.org/wal.html) | Confirmed literally |
| Go 1.27.1 released on 2026-09-01 ([ADR-001](adr/ADR-001-go-server-rust-core.md)) | [go.dev/doc/devel/release](https://go.dev/doc/devel/release) | Confirmed; 1.27.0 is from 2026-08-19 |
| Rust 1.98.1 released on 2026-09-03 and fixes vtable generation ([ADR-001](adr/ADR-001-go-server-rust-core.md)) | [blog.rust-lang.org](https://blog.rust-lang.org/2026/09/03/Rust-1.98.1/) | Confirmed: "fixes a miscompilation in vtable generation" |
| OpenMLS tests Linux, Windows and macOS; Android, iOS and WASM are only compiled ([ADR-001](adr/ADR-001-go-server-rust-core.md)) | [github.com/openmls/openmls](https://github.com/openmls/openmls) | Confirmed |
| Features `content-debug` and `crypto-debug` print content and keys ([ADR-002](adr/ADR-002-mls.md)) | Same README | Confirmed; `sqlite-provider` also exists |
| mls-rs without a complete third-party audit; Rust Crypto and Web Crypto experimental ([ADR-002](adr/ADR-002-mls.md)) | [github.com/awslabs/mls-rs](https://github.com/awslabs/mls-rs) | Confirmed; OpenSSL and AWS-LC are the stable providers; `mls-rs-ffi` and `mls-rs-uniffi` exist |
| `MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519` is a mandatory suite ([PROTOCOL §1](PROTOCOL.md#1-layers-and-responsibilities)) | [RFC 9420 §17.1](https://www.rfc-editor.org/rfc/rfc9420#section-17.1) | Confirmed: "All MLS implementations MUST support" |
| A member cannot leave unilaterally; another member must remove them ([PROTOCOL §5](PROTOCOL.md#changes-ordering-and-partitions)) | [RFC 9750 §6.1](https://www.rfc-editor.org/rfc/rfc9750#section-6.1) | Confirmed literally |
| Risk of recovering against stale GroupInfo from the server ([PROTOCOL §5](PROTOCOL.md#changes-ordering-and-partitions)) | [RFC 9750 §5.3](https://www.rfc-editor.org/rfc/rfc9750#section-5.3) | Confirmed |

Additional fact relevant to section 3: RFC 9750 §5.2.1 states that "The Delivery Service is trusted to break ties when two members send a Commit message at the same time". The standard explicitly contemplates that the relay sequences commits.

## 3. Risks that condition viability

### 3.1 Single commit coordinator

It is the weakest point of the design and the documents acknowledge it, but they underestimate its cost for the target audience.

The coordinator is the device that created the group. In a family that device is a phone, and phones get lost, replaced or broken. The consequence documented in [PROTOCOL §5](PROTOCOL.md#changes-ordering-and-partitions) and [ADR-002](adr/ADR-002-mls.md) is recreating every group that phone created, with re-verification of all participants and loss of group continuity.

There is a second, undocumented consequence: **post-compromise security depends on the availability of the coordinator**. Only it can confirm the Updates of the other members, so a member who wants to rotate keys after a compromise waits until the coordinator is online. This should be recorded in [THREAT_MODEL §4](THREAT_MODEL.md#4-guarantees-with-conditions).

Two alternatives fit with the rest of the design and remove the "create a new group" blocker:

| Alternative | Mechanism | What it solves | Cost |
|---|---|---|---|
| **Deterministic successor** | The GroupContext extension lists an order of authorized committers, or the rule "active leaf with the lowest index" is applied. All clients derive the legitimate committer from state they already validate. | Removal, loss and revocation of the coordinator without recreating the group. It is not an election under partition: it is a function of the authenticated state. | Defining the rule in the extension and testing the handover when the current committer is revoked by manifest. |
| **Opaque sequencing at the relay** | Compare-and-set on a counter per random group identifier. The relay does not interpret the commit, it only guarantees a single winner per parent epoch. | Concurrent commits from any member, in accordance with RFC 9750 §5.2.1. Removes the coordinator entirely. | The relay learns that a set of mailboxes shares a counter. [THREAT_MODEL §3](THREAT_MODEL.md#3-what-the-server-actually-knows) already admits that fan-out reveals that relationship. |

Recommendation: evaluate the first in the ADR-002 spike as a replacement for the fixed coordinator. Keep the second as an option if the first proves fragile under concurrent revocations.

### 3.2 Push on iOS

The documents treat push as optional and state that the operating system "does not guarantee always waking up". On iOS it is not a gradual degradation: **without APNs, the application only receives messages while it is open**. For a family messenger this amounts to not working.

APNs requires the credentials of the application's publisher. That leaves two paths, and both clash with the sovereignty promise as it is written:

- A central push gateway operated by whoever signs the binary. The project comes to operate a mandatory external service for iPhone users.
- Each realm operator has an Apple developer account and builds and signs their own app.

There is also a derived engineering cost. To show content in an iOS notification, a Notification Service Extension is needed, which is **another process** accessing the MLS state and the encrypted database. That breaks the single-logical-writer assumption of [DOMAIN_MODEL §5](DOMAIN_MODEL.md#5-local-state-and-atomicity) and requires a dedicated design for cross-process exclusion, like the one Signal maintains for its extension.

On Android, UnifiedPush with a self-hosted distributor such as ntfy is viable and consistent with the project.

Recommendation: decide the iOS strategy before phase 3 and document it in its own ADR. If the answer is "iOS only in the foreground in V1", say so in [ARCHITECTURE §8](ARCHITECTURE.md#8-scope-and-engineering-gates).

### 3.3 Size of the effort

The described scope amounts to several person-years: Rust core with identity, MLS, transactional persistence, synchronization, pairing and archive; Go server; Flutter clients on four platforms; linking protocol; archive format; and the whole battery of adversarial tests in [THREAT_MODEL §5](THREAT_MODEL.md#5-verifiable-invariants-and-acceptance-scenarios). The per-phase gates are well laid out, but there is no estimate of effort or team.

Recommendation: reduce phase 0 to **desktop CLI clients**, without Flutter or pairing, that demonstrate real MLS, atomic persistence and the Go relay. That deliverable already validates the three critical technical hypotheses at a fraction of the cost.

### 3.4 30-day TTL and MLS desynchronization

A family member who does not open the application for a month loses the intermediate commits, becomes desynchronized and needs to rejoin without the history of that period. [ARCHITECTURE §5](ARCHITECTURE.md#5-persistence-and-delivery) describes it as "rejoin"; for the target audience it is perceived data loss.

Cheap mitigation already contemplated by the protocol: use a longer `requested_expiry` on the envelopes that contain commits and Welcome. The cost is that the server can distinguish control envelopes by their expiry, a minor metadata item compared with the benefit.

### 3.5 Transactional persistence with the MLS library

The adoption condition in [ADR-002](adr/ADR-002-mls.md) is well laid out. Fact for the spike: **mls-rs persists group state through an explicit call**, while OpenMLS writes through the provider during each operation. The explicit model fits better with the send unit of [DOMAIN_MODEL §5](DOMAIN_MODEL.md#5-local-state-and-atomicity). Both libraries allow inspecting a commit before merging it, so the committer policy is implementable in both.

Relevant precedent for [ADR-001](adr/ADR-001-go-server-rust-core.md): Wire builds `core-crypto` on OpenMLS, with FFI bindings for iOS and Android, and models each client as a leaf. The doubt about mobile platforms has a favorable empirical answer, without that replacing our own tests.

## 4. Open points with a standard answer available

The documents leave several formats open "so as not to design ad hoc cryptography". Reviewed candidates exist that close each one without home-grown constructions:

| Open point | Candidate | Reason |
|---|---|---|
| Signed serialization of our own objects ([PROTOCOL §1](PROTOCOL.md#1-layers-and-responsibilities)) | COSE_Sign1 (RFC 9052) over deterministic CBOR (RFC 8949 §4.2) | Avoids defining a home-grown context + version + bytes scheme; Ed25519 is a standard COSE suite |
| History archive and identity kit ([PROTOCOL §9](PROTOCOL.md#9-history-transfer-and-archive)) | `age` format with its Rust implementation | Reviewed format, with key derivation and streaming encryption |
| Large attachments and chunking ([PROTOCOL §7](PROTOCOL.md#7-attachments)) | STREAM construction of `age` | Solves the chunking that is deferred; the 25 MiB limit is no longer necessary for cryptographic reasons |
| Device linking channel ([PROTOCOL §8](PROTOCOL.md#8-adding-removing-and-recovering-devices)) | Noise XX or IK handshake via the `snow` crate; QR with ephemeral key and short transcript confirmation code | Pattern equivalent to Signal's device linking; Noise is a reviewed framework |
| Future redundancy ([ADR-007](adr/ADR-007-optional-realm-redundancy.md)) | Several independent relays with several `RouteBundle`s per device | Consistent with the truth living on the clients and deliveries being idempotent; avoids leader-based replication and consensus. ADR-007 mentions it in passing and it deserves to be the preferred option |

## 5. Minor inconsistencies in the text

- **Edition versions.** README, ARCHITECTURE and THREAT_MODEL are at v0.3; PROTOCOL and DOMAIN_MODEL at v0.2. They should be aligned, or the index should explain that not all documents changed.
- **Use of "domain".** [DOMAIN_MODEL §1](DOMAIN_MODEL.md#1-vocabulary-and-ownership) defines `identity_id = hash(domain, version, root_public_key)` with "domain" as domain separation, while [ARCHITECTURE §3](ARCHITECTURE.md#3-identity-access-and-membership) states that the domain is not part of the identity. Renaming it to `domain_separator` removes the ambiguity.
- **Temporal validity without a trusted clock.** Credentials have `validity`, but [PROTOCOL §2](PROTOCOL.md#2-versioning-and-objects) declares that there is no trusted time. It remains to define how an offline client treats an apparently expired credential.
- **Version without negotiation.** The policy of rejecting unknown major versions implies that a family member who does not update stops communicating with the rest. It is a correct decision, but it must appear in the recovery matrix of [ADR-006](adr/ADR-006-local-first-recovery-first.md) as an operational incident with a procedure.
- **PCS and coordinator.** See 3.1: the availability dependency must be recorded in [THREAT_MODEL §4](THREAT_MODEL.md#4-guarantees-with-conditions).

## 6. Proposed actions before v0.4

1. Replace the fixed coordinator with a deterministic successor in [ADR-002](adr/ADR-002-mls.md) and [PROTOCOL §5](PROTOCOL.md#changes-ordering-and-partitions), or justify why it is kept.
2. Open an ADR on notifications on iOS and Android with the decision on gateway, signing and extension process.
3. Add an effort estimate per phase and redefine phase 0 as a desktop CLI.
4. Adopt COSE_Sign1, `age` and Noise as default candidates in [PROTOCOL §10](PROTOCOL.md#10-gates-before-declaring-v1), subject to the spike.
5. Correct the inconsistencies in section 5.
