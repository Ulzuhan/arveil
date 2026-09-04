# ADR-002 — MLS for E2EE messaging and multi-device groups

- **Status:** proposed; library adoption pending a spike.
- **Date:** 2026-09-04.
- **Documentation edition:** v0.2; verification scope in the [index](../README.md#references-and-traceability).

*Versión en español: [../es/adr/ADR-002-mls.md](../es/adr/ADR-002-mls.md)*

## Context

Groups, independent devices, joining, removal and key evolution are needed. Creating a cryptographic protocol of our own exceeds the scope and the level of evidence available. Always encrypting with a static conversation key makes the prototype easier but worsens the handling of compromise.

## Decision

Use MLS per RFC 9420, via an existing library. Model each conversation as a group and each device as a leaf. Evaluate OpenMLS first and mls-rs as an alternative; record version, provider, platforms, maintenance status and security review before selecting.

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

## Verified dependency conditions

OpenMLS declares the project's candidate suite and offers storage providers, but that does not demonstrate a joint transaction with our outbox. The `content-debug` and `crypto-debug` features, which allow printing content or keys, are prohibited in distributed builds. The check must include transitive features. [Source: OpenMLS](https://github.com/openmls/openmls#features).

The mls-rs README declares that it has not yet received a complete third-party security audit; it also marks aspects of Rust Crypto and Web Crypto as experimental. Its conformance with RFC 9420 does not replace that review. A concrete version and provider are compared, not just the library name. [Source: mls-rs](https://github.com/awslabs/mls-rs#security-notice).

The single coordinator remains a prototype hypothesis. Its removal or revocation is not resolved by a commit that removes itself: the conservative behaviour detailed in [PROTOCOL](../PROTOCOL.md#changes-ordering-and-partitions) is to close the affected group and create a new verified one. Before distributing V1 that flow must be tested and a decision made on whether its usage cost requires a succession mechanism with an ADR of its own.

## Acceptance criteria

Official vectors and library tests; groups with several devices; Add/Remove/Update; repeated packages; concurrent or unauthorized commits; out-of-order messages; crash between encryption and local commit; rejoin after losing epochs. Set limits on retained old secrets.

Reopen if the policy cannot be enforced or atomicity cannot be guaranteed with the library, or if the coordinator experience makes daily use unviable. Do not patch those problems by restoring old epochs.

References: [protocol](../PROTOCOL.md), [RFC 9420](https://www.rfc-editor.org/rfc/rfc9420), [RFC 9750](https://www.rfc-editor.org/rfc/rfc9750). Review scope: [index](../README.md#references-and-traceability).
