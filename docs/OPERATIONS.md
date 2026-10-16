# Running a realm

This is the operator's page: how to install the relay, put it where your family can reach it, watch it, back it up and get it back. It assumes one machine at home. Several relays are [ADR-007](adr/ADR-007-optional-realm-redundancy.md) and out of V1.

What the realm holds and what it does not is the whole reason the rest of this is short: no plaintext, no group identifiers, no conversation table. What it does hold is worth protecting anyway, because it is enough to impersonate the realm: the signing key and the Noise key under `server-secrets/`.

## Install

**Rootless Podman staging.** For a persistent test server with systemd startup,
commit-tagged images, updates and remote CLI acceptance, follow the
[Podman staging guide](PODMAN.md).

**Container.** The image carries the binary and nothing else, not even a shell.

```
docker build -f relay/Dockerfile -t arveil-relay .
docker compose -f relay/compose.yaml up -d
```

**Versioned images.** On `v*` release tags, `.github/workflows/relay-image.yml` publishes
`ghcr.io/ulzuhan/arveil-relay:<version>` for Linux x86-64 and ARM64, also
tagged with the full commit and with signed build provenance
(`gh attestation verify oci://ghcr.io/ulzuhan/arveil-relay:<version> --owner
Ulzuhan`). Each image's binary reports that commit with `-version`. Pull
requests that touch the relay build both architectures without publishing.
On a tag, nothing is built or pushed until a maintainer approves the run in
the repository's `release` environment. For code newer than the published
release, build the selected source as above. See [beta readiness](BETA_READINESS.md)
for client/relay compatibility and upgrade order.

**Release identity and verification.** Download relay/CLI binaries and
`SHA256SUMS-cli-relay.txt` together from the selected [release](https://github.com/Ulzuhan/arveil/releases).
Verify the checksums and `gh attestation verify <binary> --repo Ulzuhan/arveil`
before installing. New release builds report their tag version and full source
commit through `arveil-relay -version` and `arveil version`; the image reports the
same identity. Local builds retain development versions. The original v0.1.0
artifacts reported a development version; use their recorded commit to identify them.

Choose a relay whose release notes explicitly cover the installed clients.
Relay v0.1.0 predates beta 6 credential lookup and personal invitations.
[The beta record](BETA_READINESS.md) and [#133](https://github.com/Ulzuhan/arveil/issues/133)
track compatible distribution and the package upgrade evidence. Back up first,
upgrade the relay before dependent clients, and retain the binary matching each
backup. A schema migration does not support reopening data with an older binary.

**systemd.** Copy [`relay/packaging/arveil-relay.service`](https://github.com/Ulzuhan/arveil/blob/main/relay/packaging/arveil-relay.service), which runs as its own user with a hardened service section and keeps its data in `/var/lib/arveil`.

**By hand.** `arveil-relay -data-dir ./data -listen 127.0.0.1:8447`. The first line it prints is the bootstrap string; that is what a device needs to find and authenticate the realm.

Either way, the first thing after starting is one invite per person:

```
arveil-relay invite -data-dir /var/lib/arveil
```

It prints the token (`invite:`) and a join link (`link:`) that carries the realm and the invitation together, drawn as a QR code on a terminal ([ADR-012](adr/ADR-012-qr-codes-and-links.md)). The link opens `https://arveil.kaicorplabs.com` unless `-link-base` names another page; the invitation sits in the URL fragment, which no web server receives. The relay records the endpoint it advertises first in `advertised-endpoint` inside the data directory, and `invite` names it unless `-url` says otherwise.

## How people reach it

The channel is carrier independent ([ADR-008](adr/ADR-008-carrier-independent-transport.md)): the Noise handshake authenticates the realm and encrypts everything inside, so whatever carries it cannot read it. That is why a tunnel that terminates TLS is acceptable here and would not be elsewhere.

| Path | What to run | What it costs |
|---|---|---|
| LAN | `-listen 0.0.0.0:8447 -advertise lan=ws://<host>:8447/v1/channel` | Nothing leaves the house, and nothing works away from it |
| Tailscale | The same, bound to the tailnet address, advertised as `tailnet=` | Your tailnet coordinator learns who connects to what, and when |
| Cloudflare Tunnel | `cloudflared tunnel run` pointing at a local proxy, advertised as `public=wss://realm.example.org/v1/channel`; follow [the tunnel recipe](TUNNEL.md) | Cloudflare sees connection metadata and terminates TLS; it sees opaque frames, never content |
| TLS by the relay | `-tls-cert cert.pem -tls-key key.pem`, advertised as `wss://` | You own certificate renewal, and the port is exposed directly |

Advertise several and clients try them in order, skipping the ones that do not answer:

```
arveil-relay -advertise "lan=ws://192.0.2.10:8447/v1/channel,public=wss://realm.example.org/v1/channel"
```

Behind a proxy every connection appears to come from the proxy, so the per-address limits stop separating people. Turn on `-trust-forwarded-for` **only** if every connection reaches the relay through a proxy you trust. The relay then reads the last `X-Forwarded-For` entry, the one that proxy added, and ignores what a client wrote before it; a client that can reach the relay without that proxy could still name its own address. For the limits, IPv6 addresses are grouped by /64, since one client usually holds a whole /64. For Cloudflare Tunnel, follow [the tunnel recipe](TUNNEL.md), which keeps the public entry and a tailnet entry apart.

## Watching it

`-admin-listen 127.0.0.1:9090` serves `/healthz` and `/metrics`. Keep it off the tunnel: nothing outside needs it, and it is the one endpoint that answers without a handshake.

- `/healthz` returns 200 when the database answers, 503 otherwise. `arveil-relay healthcheck` asks it and is what the container's health check runs.
- `/metrics` is Prometheus text: connections, frames, envelopes stored and swept, blobs swept, pairings, notification hints. Counters only, with no labels, so scraping it cannot rebuild who talks to whom.

Logs are deliberately terse. A refusal says a limit bit, not which address hit it, and enrolments are logged with truncated identifiers.

## Limits

The quotas that matter for storage are per mailbox and per identity, and they only bind once somebody is a member. The pairing rendezvous is the one thing a stranger can touch, so it has its own bounds:

```
-max-conns 256 -max-conns-per-addr 8 -max-pairings-per-addr 4 -pairing-window 10m
```

Set `-max-conns-per-addr` above the number of devices one household has, or people behind the same address will refuse each other.

A refused rendezvous, by the per-address limit or the global cap, is answered with 429. The app then says the server is limiting pairing attempts from that network and to wait up to ten minutes before generating another code, since a retry inside the window is refused the same way. That wording assumes the default `-pairing-window`; keep it at 10m or less, or tell your users. People behind one address, such as a household or a mobile carrier's shared address, share the per-address budget. Other 429s (a full mailbox, the blob quota) reach the app as a limit reached, not as bad data.

## Backups

The database is the source of truth; the blobs are attachments the clients may no longer have. Back up both while the relay runs:

```
arveil-relay backup -data-dir /var/lib/arveil -out /backups/arveil-$(date +%F).tar.gz
```

The archive holds the realm's private keys. Encrypt it and keep it somewhere the realm cannot reach, so that whoever takes the machine does not take the backups with it.

Restoring goes into a new directory and never over a live one, because mixing two states would roll back revocations:

```
arveil-relay restore -in /backups/arveil-2026-09-04.tar.gz -data-dir /var/lib/arveil.new
systemctl stop arveil-relay
```

Before replacing the directory, compare both directories' keys at
`server-secrets/realm-signing.key` and `realm-noise.key` without printing their
contents. They must belong to the same realm. Preserve the **highest known
counter** from `server-secrets/endpoint-sequence` (a decimal integer) in the
restored directory, including starts after the backup. Retain ownership and
mode 0600. Do not lower the counter or clear clients' stored keys/lists. The
next startup increments it and signs a new list. If post-backup state was lost,
recover that known maximum before claiming endpoint refresh works; do not guess.

Otherwise a client retains its newest list and rejects the older one: it may
still connect through its known route, but does not accept the restored update.
After preserving the counter, swap directories and start the binary compatible
with the backup's schema:

```
mv /var/lib/arveil /var/lib/arveil.old && mv /var/lib/arveil.new /var/lib/arveil
systemctl start arveil-relay
```

Restoring an old snapshot is visible to clients rather than silent: a device recovering from its identity kit reports that the realm holds an older manifest than it does (invariant I-08), and members refresh manifests on every sync. That is detection, not prevention.

## Upgrading

Stop, replace the binary, start. The schema migrates on open. Take a backup first, and keep the previous binary until the family has used the new one, because there is no downgrade path for the database.

Relay schema 6 renumbers the envelope queue per mailbox and rounds stored times ([ADR-015](adr/ADR-015-delivery-metadata-and-anonymous-sender.md) part 1). Clients keep their cursors and need no update. A relay older than schema 6 refuses the migrated database; going back means restoring the backup taken before the upgrade, and losing what arrived since.

## Personal invitation rollout

See [owner setup and rollout](INVITATIONS.md). The personal invitation implementation migrates relay
schema 4→5 and client profiles 7→8. Back up consistently, rehearse restoration,
deploy the compatible relay first, and promote the intended existing owner by
full identity ID. Do not open newer databases with older binaries. The wider
administration panel is not implemented. Building a binary alone does not establish deployment or package acceptance.
