# Phase 3 plan: ready to hand out

**Status:** plan v1, **the six milestones of this slice complete on 2026-09-04** · Exit condition from [Architecture §8](ARCHITECTURE.md#8-scope-and-engineering-gates): *signed builds, external review and a verified platform matrix*.

Phases 0 to 2 produced something a family could run on a LAN with the command line: groups, several devices per person, revocation, recovery and encryption at rest. Phase 3 is about handing it to someone who is not the person who built it. That means closing the last protocol gap the design still marks as open (pairing over a live channel), letting people verify each other, surviving bad networks during uploads, telling a sleeping device that it has mail without telling the realm anything new, and publishing builds a stranger can check.

## Scope

**In:** device pairing over a live authenticated channel with a short verification code, replacing the copied grant of Phase 2; contact verification between identities with a safety number; resumable uploads and downloads; an optional push hint that carries no metadata beyond "you have mail"; signed, checksummed release builds for the relay and the CLI, produced by CI with provenance.

**Out (still ahead of this slice):** the Flutter clients and the verified platform matrix. They need a UI toolchain and real devices that this repository does not have yet, and pretending otherwise would put a screenshot where evidence belongs. They stay in [Architecture §8](ARCHITECTURE.md#8-scope-and-engineering-gates) as the rest of Phase 3; everything here is the protocol and operations work they would otherwise be built on top of. Also out: social recovery, delegating the root's signing power, federation.

## Milestones

| Milestone | Deliverable | Acceptance |
|---|---|---|
| **M3.1 Pairing over a live channel** | A rendezvous on the relay (`pair_begin` / `pair_put` / `pair_get`, TTL and size capped, opaque to the realm); a Noise `IK` handshake between the two devices through it; a short authentication string derived from the handshake transcript; `device pair`, `device pair-approve` and `device pair-confirm` replacing the copied grant | Script: two processes pair; both print the same code; the new device refuses to apply the grant under a different code; a third party that answers the rendezvous produces a different code and its grant is refused; the relay's rendezvous rows hold only ciphertext and expire |
| **M3.2 Contact verification** | A safety number over the two identities' root keys, stable and order-independent; `contact list` and `contact verify`; a route whose root key does not match a verified contact is refused with the reason | Script: two identities show the same number on both sides; verifying pins the root; a route carrying a different root for a verified contact is refused; the number changes when the identity does |
| **M3.3 Resumable transfers** | Upload resumes from the relay's stored offset after an interruption; download resumes from the local partial file; both verify the whole ciphertext hash before the AEAD as today | Script: an upload interrupted mid-file resumes and produces a matching hash without re-sending what the relay already has; a download interrupted mid-file resumes; a resumed upload with different bytes at the same offset is refused |
| **M3.4 Push hint without metadata** | Per-device notification hint the operator configures, sent by the relay when a mailbox goes from empty to non-empty; it carries no sender, no size, no conversation, and it is optional | Script: a hint fires on the first envelope and not on the second; its body contains nothing but the fact that mail exists; with no hint configured nothing is sent and nothing is stored |
| **M3.5 Signed builds** | A release workflow producing the relay and the CLI for the supported targets with checksums and build provenance, plus `arveil version` and `arveil-relay -version` reporting the built revision | A tagged run publishes artifacts and their checksums; the checksums match a local build of the same revision for the reproducible parts; the workflow is readable in the repository |
| **M3.6 Phase 3 exit** | `scripts/phase3.sh` in CI, this document updated with results, README roadmap, protocol notes in both languages | CI green with every script |

## Design notes fixed for this phase

- **Rendezvous.** The relay stores at most two blobs per direction under a random `pair_id` with a bearer capability, for ten minutes, capped in size, with a bound on how many exist at once. A provisional session may create one, because the device that is pairing is not a member yet; that is the only unauthenticated write surface, and it is the reason for every one of those bounds.
- **Pairing handshake.** The pairing code carries the realm id, the `pair_id`, the capability and the new device's static Noise key: `arveil-pair:v1:<realm>:<pair_id>:<capability>:<static key>`. The administration device is the Noise `IK` initiator, so the responder's key is authenticated by the code itself, and the code is what the user carries between the two screens.
- **Short authentication string.** Both sides derive it from the handshake hash after the second message, as eight digits in two groups. It is not a secret and it is not a password: it tells the user that the two devices are talking to each other and not to something in the middle. The new device stores the grant as pending and applies it only when the user confirms that number.
- **Safety number.** SHA-256 over the two root public keys sorted, rendered as twelve groups of five digits. It depends on identities only, so it survives device changes and reveals a substituted root.
- **Push.** The realm learns nothing new: it already knows a mailbox received an envelope. The hint is a bare POST to a URL the device's operator configured, with no body beyond a version marker, and it is sent only on the transition from empty to non-empty so it cannot count messages for an observer of the network to the notifier.

## Results

All acceptance rows are exercised by `scripts/phase3.sh`, which runs in CI.

- **M3.1** Two processes pair through a rendezvous the realm brokers and cannot read: the new device prints a code, the administration device answers it, both derive the same eight digits from the Noise transcript, and the grant is applied only after the user confirms that number. A wrong number is refused with nothing applied, a second device is refused a code already answered, the rendezvous rows hold ciphertext only, and an expired one is refused and swept. The paired device then works as a full member in a group with a third party.
- **M3.2** Both sides read the same safety number over their two root keys; a wrong number does not verify. Verifying pins the contact, after which a route naming a different root for that identity is refused where routes are stored. The number belongs to identities, not devices: adding a device leaves it unchanged, another identity produces a different one, and one's own devices never appear as contacts.
- **M3.3** An upload interrupted after two chunks resumes at exactly what the realm holds and finishes with a matching hash; a download interrupted the same way resumes from its partial file, and nothing is written under the file's own name until the whole ciphertext is verified. A file that changed since the interrupted attempt starts a new upload instead of mixing versions, and the realm still refuses to overwrite bytes it already has.
- **M3.4** The first envelope into an empty mailbox pokes the configured endpoint with a fixed marker, an untouched URL and no identifiers; the second envelope pokes nothing; emptying the mailbox arms it again. Removing the endpoint stops it and leaves no row. A recording of what the endpoint actually receives is asserted on, not described.
- **M3.5** The relay reports the commit it was built from and a local build claims none. The release workflow injects the same revision into both binaries and fails if either does not report it, publishes checksums, and attaches signed build provenance. Platform code signing is not done and the README says so.
- **M3.6** `scripts/phase3.sh` runs in CI beside the phase 0, 1 and 2 scripts.

What this slice leaves for the rest of Phase 3: the Flutter clients, the verified platform matrix and the external review. They need a UI toolchain and real devices, and no amount of protocol work substitutes for them.
