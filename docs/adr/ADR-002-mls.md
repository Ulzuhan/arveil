# ADR-002 — MLS for E2EE messaging and multi-device groups

- **Status:** proposed; **mls-rs selected as the library to integrate** after the M0.5 spike, subject to the mobile crypto-provider gate below.
- **Date:** 2026-09-04.
- **Documentation edition:** v0.5; verification scope in the [index](../README.md#references-and-traceability).

*Versión en español: [../es/adr/ADR-002-mls.md](../es/adr/ADR-002-mls.md)*

## Context

Groups, independent devices, joining, removal and key evolution are needed. Creating a cryptographic protocol of our own exceeds the scope and the level of evidence available. Always encrypting with a static conversation key makes the prototype easier but worsens the handling of compromise.

## Decision

Use MLS per RFC 9420, via an existing library. Model each conversation as a group and each device as a leaf. After the M0.5 spike, integrate **mls-rs 0.56** for Phase 0; OpenMLS 0.9 remains the fallback with an integration surface the spike showed to be equivalent. Version, provider, platforms, maintenance status and security review are recorded in the [spike report](../spikes/M0.5-mls-library-comparison.md).

MLS provides group key mechanisms, not the whole application. We must define identity, authorization, delivery, commit ordering, persistence, application replay, archiving and recovery. Do not present the adoption of MLS as evidence of audited product security.

The prototype profile proposes one commit coordinator per group and an authenticated policy that clients enforce before accepting state. Without a coordinator, membership changes wait; recovering from its loss creates a new verified group. Conservative semantics are prioritized over introducing distributed consensus or room state on the server.

## Alternatives

| Alternative | Assessment |
|---|---|
| Integrate a Signal-style protocol | Valid option, but requires solving this product's group and multi-device architecture separately |
| Adopt Matrix/OMEMO as a complete platform | Reduces our own work and brings interoperability, but changes the product and the operation/metadata constraints |
| Static symmetric key per group | Apparently simple implementation; does not satisfy the desired key evolution and historical exposure |
| Design our own primitives/ratchet | Rejected: unjustifiable security and review burden |

## Consequences and limits

MLS requires persisting correct state and handling epochs, KeyPackages, Welcome and absent members. The library must allow credential and policy validation, inspection of commits before merging and coherent storage transactions.

Forward secrecy depends on deleting secrets and does not protect archived plaintext. PCS requires an honest update after the compromise ends. A new device does not receive history automatically; explicit transfer is a separate function. Removal has no retroactive effect and is not instantaneous for isolated clients.

The coordinator simplifies races, but introduces an availability dependency for state changes. It is not hidden from the user nor confused with a guarantee of the standard. A malicious coordinator must also be unable to substitute others' identities without valid credentials; enrollments permitted by policy are always visible.

## Spike result (M0.5)

Both libraries answered the two blocking questions with passing tests in `spikes/mls`: group state can be written inside the application's own SQLite transaction (mls-rs through its explicit `write_to_storage`, OpenMLS through a `StorageProvider` bound to the transaction's connection), and a valid commit from an unauthorized leaf can be refused before any state change (mls-rs through `MlsRules::filter_proposals` on send and receive, OpenMLS by not merging the `StagedCommit`). Details and the full comparison table: [M0.5 spike report](../spikes/M0.5-mls-library-comparison.md).

mls-rs is selected because its explicit write model matches the transactional units of the [domain model](../DOMAIN_MODEL.md#5-local-state-and-atomicity) directly, its rules trait enforces the committer policy symmetrically with roster and group context available, and custom proposals and extensions are supported features. **Gate before Phase 3:** a stable mls-rs crypto provider (AWS-LC or OpenSSL) must build and pass the MLS test vectors on iOS and Android, or the RustCrypto provider must be promoted to stable upstream. If neither holds, switch to OpenMLS, whose persistence and policy paths the spike already exercised.

## Verified dependency conditions

OpenMLS declares the project's candidate suite and offers storage providers; the spike demonstrated a joint transaction with our outbox through a provider bound to the application's connection. The `content-debug` and `crypto-debug` features, which allow printing content or keys, are prohibited in distributed builds. The check must include transitive features. [Source: OpenMLS](https://github.com/openmls/openmls#features).

The mls-rs README declares that it has not yet received a complete third-party security audit; it also marks aspects of Rust Crypto and Web Crypto as experimental. Its conformance with RFC 9420 does not replace that review. A concrete version and provider are compared, not just the library name. [Source: mls-rs](https://github.com/awslabs/mls-rs#security-notice).

The single coordinator remains a prototype hypothesis. Its removal or revocation is not resolved by a commit that removes itself: the conservative behaviour detailed in [PROTOCOL](../PROTOCOL.md#changes-ordering-and-partitions) is to close the affected group and create a new verified one. Before distributing V1 that flow must be tested and a decision made on whether its usage cost requires a succession mechanism with an ADR of its own.

## Acceptance criteria

Official vectors and library tests; groups with several devices; Add/Remove/Update; repeated packages; concurrent or unauthorized commits; out-of-order messages; crash between encryption and local commit; rejoin after losing epochs. Set limits on retained old secrets.

Reopen if the mobile crypto-provider gate fails, if the coordinator experience makes daily use unviable, or if an independent security audit of one library changes the review parity assumed in the spike report. Policy enforcement and atomicity are no longer reopen conditions: both were demonstrated. Do not patch persistence problems by restoring old epochs.

References: [protocol](../PROTOCOL.md), [RFC 9420](https://www.rfc-editor.org/rfc/rfc9420), [RFC 9750](https://www.rfc-editor.org/rfc/rfc9750). Review scope: [index](../README.md#references-and-traceability).
