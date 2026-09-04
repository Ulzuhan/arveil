# ADR-005 — Realm-independent identity and per-device keys

- **Status:** proposed.
- **Date:** 2026-09-04.
- **Documentation edition:** v0.2; verification scope in the [index](../README.md#references-and-traceability).

*Versión en español: [../es/adr/ADR-005-cryptographic-identity.md](../es/adr/ADR-005-cryptographic-identity.md)*

## Context

Losing a server or changing domain must not change who a person is. The administrator may decide who uses the infrastructure, but must not be able to fabricate a new key and pass it off as an already verified contact. Multi-device requires removing a phone without invalidating all the others.

## Decision

Generate a local Ed25519 root and use the hash of its versioned public representation as the identity. Separate `Identity`, `Device` and `RealmMembership`. Names and aliases do not take part in cryptographic authentication.

Each device receives independent keys for MLS, transport authentication and external reception. The root signs a credential that binds them to device, identity, usages and validity. A signed, sequenced and chained manifest enumerates active and revoked credentials.

V1 requires explicit access to the root to issue credentials and manifests. It may be kept encrypted on an administration device or recovered via the identity kit. It is not copied to every device, nor is any member granted the implicit power to sign new devices. Delegations and social recovery remain out of scope until there is a reviewed design.

Contacts are verified via QR/fingerprint and store the root and the highest known manifest. The realm publishes, but the client authenticates. Access to each group is a separate authorization and requires an explicit MLS join.

## Alternatives

- Username/password as root: simplifies reset, but returns to the server the power to substitute identity.
- One private key shared across all devices: hinders individual revocation and allows cloning states.
- Personal certificates issued exclusively by the realm: the server becomes an impersonation authority.
- Unlimited delegation between devices: convenient enrollment, but a compromised phone can persist by authorizing others.
- Per-relationship identities only: reduces correlation, but complicates recovery and UX; may be studied later.

## Consequences and limits

Continuity across servers is obtained, at the cost of responsibility for the root and correlation if it is reused in several realms. Losing the root and all its backups prevents issuing new credentials with that identity. An existing device can keep operating while its groups/credentials allow it, but cannot rebuild the root.

Compromising the root compromises the identity authority: revoking a phone is not enough. V1 requires a new root, external contact and re-verification; a signature from the compromised root does not prove that the new one belongs to the legitimate user.

A signed manifest proves origin, not absolute freshness. Known rollbacks and conflicts are rejected; isolated participants may not see a recent revocation. Restoring from an old identity kit requires checking versions against surviving sources or re-verifying.

Revocation requires a new manifest, operational invalidation and Remove/Commit in each group. The UI presents these steps and partial states; it does not claim an instantaneous global removal.

## Acceptance criteria

Legitimate enrollment, fake device, credential with a substituted key, changed root with the same username, old or forked manifest, loss of the administrator, recovery with the identity kit and removal of an offline device. Each case must produce visible results and not substitute trust silently.

Reopen for delegation, root rotation with continuity, key transparency or per-contact identities. Each extension must declare what new authority it introduces.

References: [domain model](../DOMAIN_MODEL.md), [identity flows](../PROTOCOL.md), [sources](../README.md#references-and-traceability).
