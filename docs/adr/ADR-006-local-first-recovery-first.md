# ADR-006 — Local-first and recovery as fundamental functions

- **Status:** proposed.
- **Date:** 2026-09-04.
- **Documentation edition:** v0.2; verification scope in the [index](../README.md#references-and-traceability).

*Versión en español: [../es/adr/ADR-006-local-first-recovery-first.md](../es/adr/ADR-006-local-first-recovery-first.md)*

## Context

A homelab can be switched off and a phone can be lost. E2EE without local history, honest states and a recovery path is of little use to family members. At the same time, restoring old cryptographic snapshots or handing all keys to every device destroys important properties.

## Decision

The client's encrypted database is the source of its history; the local queue allows composing and preparing sends without network. The relay keeps envelopes until ACK/TTL and is not the mandatory historical archive.

Separate three capabilities:

1. **Identity kit:** encrypted private root and recovery metadata; allows authorizing new devices. Its high-entropy secret is kept outside the single endpoint.
2. **Device enrollment:** new keys and leaf; root authorization and Add per group. Do not clone device private keys or active MLS states.
3. **History archive/transfer:** exported messages and selected attachments, encrypted and authenticated with separate keys. Does not include secrets of active epochs.

Outgoing encryption and MLS evolution are committed together with the outbox in one transaction. Reception and deduplication are committed before ACK. Restoring an earlier database does not allow resuming sending from that state: it is treated as recovery and rejoin.

## Recovery matrix

| Incident | What it allows recovering | What it requires |
|---|---|---|
| Server lost; clients intact | Identity and local history; service from backup or a new realm | Reconfigure routes, trust the new endpoint and reconcile pending items |
| Phone lost; another device and the root accessible | Identity, new enrollment and selected history | Revoke the phone, Remove/Commit and authenticated transfer |
| All devices lost; identity kit and archive available | Identity and exported history | New keys, manifest comparison, rejoin and possibly a new group |
| Identity kit only | Authority of the identity | Rejoin; the past depends on other clients or archives |
| History archive and its key only | The archived records | New identity; the archive does not authorize signing as the previous one |
| No devices, kit or archive | Nothing of the previous identity/history | Start with a new identity and re-verify contacts |
| Relay backup without personal material | Service, metadata and envelopes still useful for clients that hold keys | Does not by itself recover identity or decryptable history |
| Compromised root | Continue with a new identity | Revocations where possible, external contact and re-verification; do not trust automatic continuity |

## Alternatives

- Permanent decryptable history on the server: breaks the E2EE boundary.
- Encrypted remote history as the only copy: keeps potential confidentiality, but depends on availability and key; does not satisfy local-first.
- Restore the full database with MLS sending state: can roll back generations and revocations; rejected as automatic recovery.
- Offer no recovery in order to preserve FS: avoids copies, but does not satisfy the product. An explicit archive with clear limits is offered.

## Consequences

Copying history increases the places where the past can be exposed. Transport forward secrecy does not retroactively encrypt local messages nor protect an archive when its key is stolen. The UI allows choosing period and attachments and explains this consequence before transferring.

The application distinguishes local pending, relay acceptance, reception per device and optional read. A group can have partial delivery. Expiry or loss of the server leaves messages uncertain; they are not filled in with invented success states.

Recovery is validated from the first usable version: exporting an archive is not enough without restoring it. The user can verify the identity kit through a controlled test that does not send its secret to the server. The exact design of the archive and of the linking channel remains pending review.

## Acceptance criteria

Open history and compose without network; restart during send/receive without losing or duplicating visible events; restore a server; recover with an old identity kit; recover history only; total loss; a removed device attempting to return; archive password/secret failure; missing or corrupt attachment.

Reopen if permanent cloud synchronization, managed recovery or social delegation is added. No new convenience may secretly restore an old MLS state or hand the root to the operator.

References: [architecture](../ARCHITECTURE.md), [protocol](../PROTOCOL.md), [threat model](../THREAT_MODEL.md).
