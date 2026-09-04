# Phase 1 plan: LAN vertical

**Status:** plan v1, **all six milestones complete on 2026-09-04** · Exit condition from [Architecture §8](ARCHITECTURE.md#8-scope-and-engineering-gates): *restarts, duplicates, TTL and network loss with no silent loss*, for 1:1 and group chat with offline outbox, queues and attachments.

Phase 0 proved the three hypotheses (MLS in our transaction, policy before merge, opaque channel through a TLS-terminating proxy). Phase 1 turns the vertical into something a family could run on a LAN with the CLI: groups of more than two devices, messages written while the relay is down, envelopes and blobs that expire honestly, files, and a client that reaches the realm through whichever endpoint answers.

## Scope

**In:** groups of N devices with the creator as committer; adding members after creation; route distribution inside the group; sending with the relay unreachable and publishing later; relay-side expiry sweeps for envelopes, blobs and invites; encrypted attachments up to 25 MiB with a random FileKey and an E2EE descriptor; several endpoints in the signed list with client fallback by priority; truthful delivery states in the CLI (`queued`, `accepted`, `expired`).

**Out (Phase 2 and 3):** multi-device per person, device linking, identity kit and history archive, SQLCipher, push, GUI, commit coordinator succession (tracked in the [v0.3 review](REVIEW-v0.3.md#31-single-commit-coordinator)), chunked or resumable uploads.

## Milestones

| Milestone | Deliverable | Acceptance |
|---|---|---|
| **M1.1 Offline outbox** | `chat send` succeeds with the relay down; `chat sync` publishes what is pending; envelope states reported truthfully | Script: relay stopped, two sends queued, relay started, one sync publishes both, peer receives both exactly once |
| **M1.2 Group chat** | `chat start` with several routes; fan-out to every member device; `chat add` by the creator; routes learned inside the group by every member | Script: three devices, everyone reads everyone; a fourth added later reads only messages after its Add; an unauthorized Add from a non-creator is refused |
| **M1.3 TTL and cleanup** | Relay sweeps expired envelopes, blobs and invites on a timer; `envelope_put` honours `requested_expiry` up to the cap; the sender keeps its local copy and shows `expired/unknown`, never `delivered` | Store test with a short TTL; script with a 2-second TTL showing the envelope vanishes and the receiver never sees it |
| **M1.4 Endpoint fallback** | The relay advertises several endpoints; the client stores the signed list and tries endpoints by priority, skipping dead ones | Script: first advertised endpoint is a closed port, second is live; every command still works; a list with lower sequence is refused |
| **M1.5 Attachments** | Relay blob store (staging → committed, quota, TTL) with `blob_upload_begin` / `blob_chunk` / `blob_commit` / `blob_fetch`; client encrypts whole files with a random FileKey (AES-256-GCM) and sends the descriptor inside MLS; `chat send-file` and files saved by `chat sync` | Script: a 1 MiB file round-trips with matching hash; the relay stores only ciphertext; an expired blob is reported as unavailable, not silently skipped |
| **M1.6 Phase 1 exit** | This document updated with results; README roadmap; all scripts in CI | CI green with `scripts/phase1.sh` |

## Design notes fixed for this phase

- **Fan-out.** One MLS ciphertext per message, one HPKE envelope per recipient device, one outbox row per envelope, all in the send unit. A member with an unknown route is a visible pending delivery, not a silent skip.
- **Routes in the group.** Every member sends a `route` event on join; the creator forwards nothing. Members store one route per peer identity.
- **Attachments.** `FileKey` 32 bytes random, AES-256-GCM with a random 12-byte nonce over the whole file, descriptor `{version, blob_id, read_capability, file_key, nonce, ciphertext_hash, size, name, mime}` inside an MLS `file` event. Chunking on the wire only (frames of at most 60 KiB); no streaming AEAD in this phase.
- **Expiry.** The relay is store-and-forward: a swept envelope is gone. The sender never learns whether it was read; the CLI shows `accepted (expires <t>)` and, after that time, `expired/unknown`.

## Results

All acceptance rows are exercised by `scripts/phase1.sh`, which runs in CI.

- **M1.1** `chat send` commits locally and exits 0 with the relay down; `chat history` shows each recipient as `queued`, then `accepted (relay keeps it until t)`, then `expired/unknown`; one `chat sync` publishes everything pending and the peer receives each message exactly once.
- **M1.2** Groups of three: the creator claims one KeyPackage per peer, adds all in one commit, sends the Welcome to each and a `roster` event with every route; everyone reads everyone. `chat add` by the creator brings a fourth member in at epoch 2 with an updated roster; that member cannot read earlier history; `chat add` from a non-creator is refused by the policy on the sender's own device (the policy names the lowest active leaf as the only committer). Commits are accepted as MLS `PublicMessage` since the HPKE envelope already hides them from the relay. The receive pass stops at the first envelope that cannot be processed and advances the cursor only past processed ones, so nothing is lost behind a temporarily unprocessable envelope.
- **M1.3** The relay sweeps expired envelopes, stale invites and blobs on `-sweep-interval`, logging counts only; `requested_expiry` is honoured up to the cap. A 2-second envelope is gone before the receiver syncs; the sender keeps its copy and shows `expired/unknown`.
- **M1.4** With a dead endpoint advertised first, clients report it and connect through the next one; the signed list is refreshed on every connection and stored when its sequence increases.
- **M1.5** A 1 MiB file round-trips with a matching hash through `blob_upload_begin` / `blob_chunk` / `blob_commit` / `blob_fetch`; the relay's blob file holds ciphertext only; an expired blob is reported as `file unavailable` and recorded as a `file-unavailable` event.

What Phase 1 leaves open, for Phase 2: multi-device per person, device linking, identity kit and history archive, SQLCipher at rest, the commit coordinator successor rule, resumable uploads.
