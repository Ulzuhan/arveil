# Running a realm

This is the operator's page: how to install the relay, put it where your family can reach it, watch it, back it up and get it back. It assumes one machine at home. Several relays are [ADR-007](adr/ADR-007-optional-realm-redundancy.md) and out of V1.

What the realm holds and what it does not is the whole reason the rest of this is short: no plaintext, no group identifiers, no conversation table. What it does hold is worth protecting anyway, because it is enough to impersonate the realm: the signing key and the Noise key under `server-secrets/`.

## Install

**Container.** The image carries the binary and nothing else, not even a shell.

```
docker build -f relay/Dockerfile -t arveil-relay .
docker compose -f relay/compose.yaml up -d
```

**systemd.** Copy [`relay/packaging/arveil-relay.service`](https://github.com/Ulzuhan/arveil/blob/main/relay/packaging/arveil-relay.service), which runs as its own user with a hardened service section and keeps its data in `/var/lib/arveil`.

**By hand.** `arveil-relay -data-dir ./data -listen 127.0.0.1:8447`. The first line it prints is the bootstrap string; that is what a device needs to find and authenticate the realm.

Either way, the first thing after starting is one invite per person:

```
arveil-relay invite -data-dir /var/lib/arveil
```

## How people reach it

The channel is carrier independent ([ADR-008](adr/ADR-008-carrier-independent-transport.md)): the Noise handshake authenticates the realm and encrypts everything inside, so whatever carries it cannot read it. That is why a tunnel that terminates TLS is acceptable here and would not be elsewhere.

| Path | What to run | What it costs |
|---|---|---|
| LAN | `-listen 0.0.0.0:8447 -advertise lan=ws://<host>:8447/v1/channel` | Nothing leaves the house, and nothing works away from it |
| Tailscale | The same, bound to the tailnet address, advertised as `tailnet=` | Your tailnet coordinator learns who connects to what, and when |
| Cloudflare Tunnel | `cloudflared tunnel run` pointing at `http://127.0.0.1:8447`, advertised as `public=wss://realm.example.org/v1/channel` | Cloudflare sees connection metadata and terminates TLS; it sees opaque frames, never content |
| TLS by the relay | `-tls-cert cert.pem -tls-key key.pem`, advertised as `wss://` | You own certificate renewal, and the port is exposed directly |

Advertise several and clients try them in order, skipping the ones that do not answer:

```
arveil-relay -advertise "lan=ws://192.168.1.10:8447/v1/channel,public=wss://realm.example.org/v1/channel"
```

Behind a proxy every connection appears to come from the proxy, so the per-address limits stop separating people. Turn on `-trust-forwarded-for` **only** if that proxy is yours and overwrites `X-Forwarded-For`; a client that sets the header itself would otherwise pick its own address.

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

## Backups

The database is the source of truth; the blobs are attachments the clients may no longer have. Back up both while the relay runs:

```
arveil-relay backup -data-dir /var/lib/arveil -out /backups/arveil-$(date +%F).tar.gz
```

The archive holds the realm's private keys. Encrypt it and keep it somewhere the realm cannot reach, so that whoever takes the machine does not take the backups with it.

Restoring goes into a new directory and never over a live one, because mixing two states would roll back revocations:

```
arveil-relay restore -in /backups/arveil-2026-09-04.tar.gz -data-dir /var/lib/arveil.new
systemctl stop arveil-relay && mv /var/lib/arveil /var/lib/arveil.old && mv /var/lib/arveil.new /var/lib/arveil && systemctl start arveil-relay
```

Restoring an old snapshot is visible to clients rather than silent: a device recovering from its identity kit reports that the realm holds an older manifest than it does (invariant I-08), and members refresh manifests on every sync. That is detection, not prevention.

## Upgrading

Stop, replace the binary, start. The schema migrates on open. Take a backup first, and keep the previous binary until the family has used the new one, because there is no downgrade path for the database.
