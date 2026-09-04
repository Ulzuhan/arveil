# Threat model

**Status:** proposal v0.4, no audit and no verified implementation. [Architecture](ARCHITECTURE.md) · [Protocol](PROTOCOL.md).

*Versión en español: [es/THREAT_MODEL.md](es/THREAT_MODEL.md)*

## 1. Assets and trust boundaries

Highest-sensitivity assets: personal root keys, device private keys, active MLS secrets, local database keys, recovery codes, content and exported history. Also sensitive are the social graph, correlatable public identities, IP addresses, capabilities, push tokens and revocation state.

The trusted perimeter includes the legitimate core and UI, the operating system while it handles plaintext, and the device that authorizes an identity. An unlocked screen or a compromised process can expose conversations. The realm, proxy, network, intermediate tunnel or CDN, push provider, directory and remote storage are treated as adversarial for content confidentiality and person authenticity. An intermediary that terminates TLS, such as Cloudflare Tunnel, is additionally treated as an adversary of the API: the Noise channel of [ADR-008](adr/ADR-008-carrier-independent-transport.md) prevents it from seeing or using credentials and identifiers.

The homelab owner may be honest, curious or malicious. E2EE must protect against the last, but it does not force the server to deliver, retain or delete anything. An initially unverified identity can be substituted by the directory: the self-generated root does not by itself resolve the first contact.

## 2. Adversaries and scenarios

| Threat | Designed defense | Residual and condition |
|---|---|---|
| Network observer or MITM | Noise channel with the realm key verified at bootstrap; E2EE | IP, volume and timing visible; a substituted QR at bootstrap binds the client to an impostor realm |
| CDN, tunnel or proxy that terminates TLS (Cloudflare Tunnel, VPS, Funnel) | Noise channel inside the carrier; no secrets or identifiers outside the channel | Sees each client's IP, timing, sizes and number of connections; can block or delay. Does not see frames, credentials or operation types; cannot act against the relay |
| Hostile endpoint in the list or poisoned DNS | Signed and sequenced `RealmEndpointList`; handshake fails on a different key | The client may be left without service; reveals nothing to the impostor endpoint |
| Theft of the server database and blobs | MLS, per-device wrapping, encrypted attachments | Exposes memberships, routes, sizes and timing; it is not a database "without personal data" |
| Malicious realm operator | Local verification of roots, credentials, policies and events | Can block, reorder, fork views and correlate traffic |
| Key substitution in the directory | QR/fingerprint, signed manifests and persistent maximums | TOFU without external verification is vulnerable on first connection; the server can hide updates |
| Replay or duplicate delivery | IDs, epochs, MLS validation and durable deduplication | The transport can repeat indefinitely; quotas and limits apply |
| Messages from a removed device | Credential revocation, Remove and new epoch | Not instantaneous among isolated participants; does not erase prior copies |
| Temporary compromise of a member | MLS update with honest entropy after cleaning/excluding the attacker | PCS depends on the attacker losing access and on clients processing the update |
| Theft of a locked device | Local encryption and OS-protected secrets | Depends on lock, hardware and configuration; does not protect already-unlocked memory |
| Malware on the device or tampered client | Reduce privileges, signed releases, review and updates | Outside the E2EE guarantee: the attacker uses legitimate keys and plaintext |
| Theft of a personal backup | Authenticated archive encrypted with a high-entropy secret | Backup and key together expose content; a copy with the root also enables impersonation |
| Curious push provider | Generic payload, optional adapter | Can see token, IP, timing and application; the OS does not guarantee it will always wake the app |
| Malicious group member | Signature/identity of each leaf and authorization of changes | A legitimate recipient can copy, photograph or publish content |
| Exhaustion of disk, CPU or bandwidth | Quotas, sizes, parsing limits and future-epoch limits | No DDoS resistance or availability against the operator is promised |
| Global traffic analysis | Less persisted semantics, padding and individual wrapping | Unsolved; delivery authentication and fan-out allow correlation |
| Rollback of the server or of a backup | Local maximums, deduplication, new keys when restoring a client | A client that lost all state needs external cross-check; there is no trusted global clock |
| Library or supply chain failure | Pinned versions, inventory, tests, independent review | Standard MLS does not automatically make the integration secure |

## 3. What the server actually knows

| Data | Intended visibility |
|---|---|
| Members, public roots and registered devices | Visible to administration and directory |
| Mailbox and owning device | Visible for access control/quotas |
| Sender of an authenticated request and destination mailbox | Visible during delivery; correlatable by an operator |
| IP, time, size, frequency, push tokens | Visible depending on the component; minimize retention |
| API frames, capabilities, mailbox and delivery IDs | Visible only to the realm inside the Noise channel; opaque to tunnels, CDNs and proxies |
| Endpoint list and realm Noise key | Public by design; their authenticity depends on the realm signing key, not on the carrier |
| MLS group ID, epochs, roster and titles | Inside the encrypted wrapping; not server columns |
| Text, original files, original names and MIME types | Encrypted on the client |
| Private keys and personal recovery secrets | Never needed nor sent in the clear to the realm |
| Voluntarily hosted history backups | Ciphertext, size and access pattern; no content without the key |

The absence of conversation tables reduces what is stored and exposed by ordinary queries. It does not prevent a modified server from reconstructing relationships from connections and deliveries. Stable cryptographic identifiers can correlate a person across realms if they reuse the root: this architecture does not claim to be free of globally correlatable identifiers.

A carrier intermediary sees the same as a network observer: who connects, when and how much they send. With Cloudflare Tunnel that observer is a permanent third party in another jurisdiction; with Funnel or a VPS with passthrough, it sees only TLS bytes. It is an operator deployment decision, not a change of guarantees. Bucket padding reduces size precision; it does not hide total volume. A compromised outer HPKE key can reveal MLS headers of recorded envelopes; content confidentiality still depends on MLS. No forward secrecy is attributed to a static HPKE receiving key.

## 4. Guarantees, with conditions

**Content confidentiality and integrity:** the goal against an adversarial server/network when the endpoints and libraries are intact, identities have been authenticated and keys remain secret. Plaintext messages are not accepted as a fallback.

**Forward secrecy:** deleting message/epoch secrets according to the protocol limits what is recoverable from current secrets. It does not protect messages already decrypted and stored in local history, exports, screenshots or backups. Retaining epoch keys to accept late messages widens the exposure window and must be bounded.

**Post-compromise security:** requires that the adversary's control cease and that fresh honest material enter through the appropriate MLS operations. There is no automatic healing from time passing, changing the hostname or restoring the database. A still-authorized, compromised device remains a legitimate recipient. While the single-coordinator profile remains in force, a member's PCS also depends on the coordinator being available to confirm its Update; see the [v0.3 review](REVIEW-v0.3.md#31-single-commit-coordinator).

**Revocation:** once the correct Remove has been applied and the epoch has advanced, the excluded device must not decrypt messages from those later epochs. Out-of-date participants may keep sending in old epochs; the client that knows about the revocation stops sending until the change completes. Retention of old secrets and messages already sent limit the guarantee.

**Recovery:** preserving identity requires a recoverable root; preserving history requires explicit copies. Recovering the root does not magically recreate group secrets or expired messages. Compromising the root allows signing new devices and is a full identity incident.

**Availability and consistency:** not guaranteed against a malicious relay. On contradictory commits or evidence of a fork, the group is paused and explicit repair is required. Comparing checkpoints among participants can detect contradictions, but a server that isolates them can delay detection indefinitely.

## 5. Verifiable invariants and acceptance scenarios

| ID | Requirement | Evidence required before release |
|---|---|---|
| I-01 | The server receives neither personal secrets nor message plaintext | Client traces, field inventory, inspection of DB/blobs/logs and review of the key flow |
| I-02 | A foreign root does not replace a verified contact | Adversarial directory that changes root, manifest or device link; visible rejection |
| I-03 | Only valid devices and authorized changes enter a group | Fake, expired and revoked credentials, and valid but unauthorized MLS commits; rejection |
| I-04 | A send does not reuse MLS state after a crash | Failures between encryption, local commit and publication; retransmission of the persisted ciphertext |
| I-05 | ACK implies sufficient local persistence | Failures before/after commit and ACK; no loss or visible duplicates |
| I-06 | A removed device loses access to new epochs | Test with several members, partition, Remove and subsequent Update/commit; documented limits for old epochs |
| I-07 | Imported history does not revive old MLS secrets | Restoring an outdated backup; new device, rejoin and separate archive |
| I-08 | Server restore does not roll back known versions | Snapshot prior to revocation and deliveries; detection and reconciliation |
| I-09 | Push, errors and telemetry do not leak content/capabilities | Real payloads, proxy logs, crash reports and binding traces reviewed |
| I-10 | Malformed inputs do not consume unbounded resources | Fuzzing of framing, CBOR/MLS/HPKE and quota tests before deserializing |
| I-11 | The backup preserves a consistent set | Isolated restore with coherent DB, blobs, migrations and operational secrets |
| I-12 | An intermediary that terminates TLS obtains neither credentials, nor identifiers, nor the ability to act | Capture on the origin side of a tunnel: only opaque frames; replay of the first Noise message without effect; endpoint with a different key rejected |
| I-13 | The client switches carrier without intervention and without rolling back the endpoint list | Sequential failure of LAN, tailnet and public; list with a lower sequence or invalid signature rejected |

These tests can detect violations. No "we found no plaintext" test proves by itself that an attacker cannot decrypt; cryptographic review, assumptions and library quality remain essential.

The online review adds three mandatory cases to the test plan: durable commit selection before Welcome; loss or revocation of the coordinator; and power loss under the conditions of [ADR-004](adr/ADR-004-sqlite-single-binary.md#verified-durability-requirements). Library versions, providers and debug features are audited according to [ADR-002](adr/ADR-002-mls.md); this documentary review does not attest to an audit of those dependencies.

## 6. Open risks that block strong claims

- Review the extension/policy that restricts commits to the coordinator and how it is validated before merging state in the chosen library.
- Specify device linking, transcript, expiry, QR and replay resistance; a decorative QR does not authenticate the channel.
- Bound the retention of epoch secrets and the behavior when late-message windows are exceeded.
- Validate the suite and format of archives/recovery files without designing ad hoc cryptographic constructions.
- Verify access to the secure store and encryption of all local files, WAL, temporary files, thumbnails and notifications.
- Review signed updates from a channel independent of the realm and behavior on loss of the root.
- Fix the Noise pattern and suite, the handling of the first `IK` message and the rotation window of the realm Noise key; verify that no frame is processed before the handshake completes.

The product's Privacy Inspector must communicate these limits in plain language and distinguish what is observed from what is inferable. It must not show a check for "anonymity" or "history protected against any compromise".

Base references and review scope: [README](README.md#references-and-traceability).

## 7. Additional threats if optional HA is adopted

This extension is future work and does not extend the current guarantees. [ADR-007](adr/ADR-007-optional-realm-redundancy.md) requires studying:

- Partitions and dual writers, promotion of lagging replicas and return of the former primary.
- Reappearance of revoked capabilities, deleted envelopes or consumed invitations from a stale replica.
- Loss of files even though the database is replicated, and incompatible cleanup across nodes.
- Shared failures of power, router, provider or household; a single access path that prevents reaching healthy replicas.
- Entry of unauthorized nodes and greater exposure of metadata, operational credentials and backups.

Nodes do not receive E2EE keys. Cluster continuity will be evaluated against failures and partitions under operational trust among nodes; no protection against malicious nodes will be assumed from using consensus. On loss of write authority, the client keeps its pending outbox and does not simulate remote acceptance.
