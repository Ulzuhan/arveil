# ADR-003 — Untrusted server for content and personal identity

- **Status:** proposed.
- **Date:** 2026-09-04.
- **Documentation edition:** v0.2; verification scope in the [index](../README.md#references-and-traceability).

*Versión en español: [../es/adr/ADR-003-zero-trust-server.md](../es/adr/ADR-003-zero-trust-server.md)*

## Context

Self-hosting allows controlling the infrastructure, but does not prevent disk theft, process compromise, exposed backups or a curious administrator. Identity cannot depend on the directory always delivering the correct keys.

## Decision

The server manages admission, resources and delivery. It is not the identity root, an MLS member or a custodian of personal keys. Clients verify roots and credentials and enforce group policy.

Persist `mailboxes`, `envelopes`, `blobs`, memberships and public device material. Do not keep semantic conversation entities, titles or group rosters on the server. Encapsulate MLS messages and controls in per-recipient HPKE envelopes; encrypt attachments at the source.

Identity recovery is performed with the user's material, not with an administrator password reset. E2EE applications are distributed through a signed release channel independent of the realm; a web client served dynamically by it is out of scope for V1.

## Alternatives

- TLS with messages readable on the server: does not protect against the operator or a compromised process.
- E2EE with the server as sole key authority: allows identity substitution if that authority is compromised.
- Relay network oriented to anonymity with an unauthenticated sender: would reduce some metadata, but requires another topology and abuse design; deferred.

## Consequences

The server cannot search message text, generate previews, moderate decrypted content or recover personal keys. Search and history live on the client. Push notifications are generic and optional.

"Zero-trust" is used here with a specific scope, not as a synonym for zero metadata. The relay knows the mailbox owner, memberships, sessions and destinations; it can infer the social graph. A session authenticated per send facilitates quotas and correlation. Not storing rooms does not prevent observing traffic groups.

Availability, global freshness of the directory and honest deletion are not guaranteed against a malicious realm. First contact needs external verification. A tampered endpoint or a legitimate recipient can exfiltrate plaintext.

## Acceptance criteria

Inventory of all stored/transmitted fields; tests with a directory that substitutes keys; review of logs/proxy/push; simulation of a relay that reorders, hides and repeats; inspection of full backups. Verify that the client never accepts plaintext or silent device enrollment as a fallback.

Reopen before adding a browser chat client, bots, bridges, remote search or managed recovery. Any of those functions can alter the key boundary and needs a decision of its own.

References: [threat model](../THREAT_MODEL.md), [domain model](../DOMAIN_MODEL.md), [sources](../README.md#references-and-traceability).
