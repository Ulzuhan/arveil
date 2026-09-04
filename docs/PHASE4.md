# Phase 4 plan: operable

**Status:** plan v1, **all nine milestones complete on 2026-09-04** · Exit condition: *somebody who did not write this can install the realm, put it behind their tunnel, watch it, back it up and restore it; and the client stops depending on things that only hold for one conversation and five KeyPackages.*

Phases 0 to 3 proved the protocol and its guarantees. None of that helps if the relay is a binary you start by hand and hope for. This phase is the distance between "the protocol works" and "you can run it at home for your family", plus the three client gaps that are not the graphical interface.

## Scope

**In:** container image and compose file, systemd unit, an operations guide in both languages; limits per connection and per address on the one unauthenticated surface; a health endpoint and coarse metrics on a separate listener; TLS served by the relay itself for people without a tunnel, and a documented Cloudflare Tunnel path; backup and restore with a drill that proves a restored realm still works; KeyPackage replenishment; several conversations in the client; names for contacts.

**Out:** the Flutter clients and the verified platform matrix, still the rest of Phase 3; multi-node realms ([ADR-007](adr/ADR-007-optional-realm-redundancy.md)); an admin web interface, which [Architecture §8](ARCHITECTURE.md#8-scope-and-engineering-gates) rules out for V1.

## Milestones

| Milestone | Deliverable | Acceptance |
|---|---|---|
| **M4.1 Packaging** | Dockerfile building a static relay on a distroless base, a compose file with a data volume, a systemd unit with a hardened service section, and `docs/OPERATIONS.md` in both languages | The image builds and a container serves a real conversation; the compose file starts it with persistent data; the unit passes `systemd-analyze verify` |
| **M4.2 Limits per address** | Concurrent connections per address and per process, an open-rendezvous cap per address, and a bound on how fast a provisional session may act | Script: one address cannot exhaust the pairing capacity of the realm; a member from another address still pairs; the limits are visible in the logs and configurable |
| **M4.3 Health and metrics** | `-admin-listen` serving `/healthz` and `/metrics`, off unless configured, never on the public listener; counters that describe load, never who | Script: health answers before and after the channel port is busy; metrics carry no identity, mailbox or conversation; nothing is served when the flag is absent |
| **M4.4 TLS and tunnels** | `-tls-cert` and `-tls-key` for `wss://` without a proxy; the operations guide covers Cloudflare Tunnel, Tailscale and plain LAN with their trade-offs | Script: the relay serves TLS directly and a client connects with `ARVEIL_TLS_CA`; the endpoint list advertises the right scheme |
| **M4.5 Backup and restore** | `arveil-relay backup` producing a consistent snapshot of the database and the blobs while the relay runs, and `arveil-relay restore` refusing to overwrite a live directory | Script: back up mid-conversation, restore into a new directory, start the relay there and continue the same conversation with no loss |
| **M4.6 KeyPackage replenishment** | The client asks how many remain and publishes more when low; the relay reports the count for the session's device | Script: enough conversations to exhaust the initial batch still work; the count recovers after a sync; a device that never syncs degrades visibly, not silently |
| **M4.7 Several conversations** | `chat list`, and `--group <prefix>` on send, send-file, add and remove; with one conversation nothing changes, with several the command says which ones match | Script: two conversations in one data directory; sending to each by prefix; an ambiguous or unknown prefix is refused with the candidates |
| **M4.8 Contact names** | `contact name <identity> <name>`, names shown in `contact list`, `chat history` and rosters; a name is local and never authenticates anything | Script: naming a contact changes what is displayed and nothing else; the safety number is unchanged; names are not sent to the realm |
| **M4.9 Phase 4 exit** | `scripts/phase4.sh` in CI, this document updated with results, README and roadmap | CI green with every script |

## Design notes fixed for this phase

- **Metrics are load, not people.** Counters for connections, frames, envelopes stored and swept, blob bytes and rendezvous, never per identity, per mailbox or per conversation. The admin listener binds to localhost by default and is documented as something to keep off the tunnel.
- **Limits are per address, applied before the handshake.** The pairing rendezvous is the only surface a stranger can touch, so it gets its own cap per address on top of the global one, and both are logged when they bite.
- **Backups run against a live relay.** SQLite is copied with `VACUUM INTO`, which is consistent under WAL, and the blobs are copied afterwards; a blob written between the two is harmless, since the database is the source of truth and the reconciler removes files without a row.
- **Names are local.** They live in the client database, never travel, and never take part in any check. The safety number stays the only thing that authenticates a contact.

## Results

All acceptance rows are exercised by `scripts/phase4.sh`, which runs in CI. Two of them only run where the tools exist: the systemd unit is verified with `systemd-analyze` and the image is built and driven with `docker`, both present on the CI runner and skipped with a message elsewhere.

- **M4.1** The image builds from the repository root onto a base with no shell, and a container serves a real conversation between two clients, invites included. The compose file validates and mounts a named volume; the systemd unit passes `systemd-analyze verify` and runs as its own user under a hardened service section. [Running a realm](OPERATIONS.md) covers install, tunnels, limits, watching, backups and upgrades in both languages.
- **M4.2** With one connection and one rendezvous allowed per address, a second connection from that address is refused and a second rendezvous answers 429. Both refusals are logged and counted, and the refusal lines name no address: the relay's own listen addresses are in the log because the operator needs them, the client's are not.
- **M4.3** `/healthz` and `/metrics` answer on the admin listener and nowhere else; the channel port serves the channel alone. The metrics are counters with no labels, which is where a per-person dimension would otherwise arrive. `arveil-relay healthcheck` asks the same endpoint, so an image without a shell can still have a health check.
- **M4.4** With a certificate and key the relay serves `wss://` itself and advertises the right scheme; a client with the issuing authority connects, and one without it refuses the certificate. A self-signed certificate presented as the server's own is refused too, which is why the drill issues an authority and a leaf.
- **M4.5** A backup taken while the realm serves restores into a new directory; restoring over a live one is refused, and so is overwriting an existing archive. The restored realm keeps its identity, still holds the envelope accepted before the copy, and the same conversation continues through it.
- **M4.6** Five people exhaust the batch published at enrolment and the sixth is refused, visibly. One sync tops the shelf back up and the sixth conversation starts. The client checks on every sync, so the shelf refills long before anyone notices.
- **M4.7** `chat list` shows every conversation. With several open, a send without `--group` is refused with the candidates instead of picking one; a prefix sends to the right one and only that one; an unknown prefix and an ambiguous one are both refused with what they matched.
- **M4.8** A local name is shown in the contact list and in the history, does not change the safety number, and never reaches the realm. It can be removed.
- **M4.9** `scripts/phase4.sh` runs in CI beside the phase 0 to 3 scripts.

What Phase 4 does not do: multi-node realms, an admin interface, or anything that would make the relay know more than it does today.
