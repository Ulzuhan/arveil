# Why Cloudflare cannot read our API, even though it terminates our TLS

*Draft for publication. Part of the Arveil design notes. 2026-09-04.*

I am building [Arveil](https://github.com/Ulzuhan/arveil), a self-hosted end-to-end encrypted messenger for families. The server is meant to run on a Raspberry Pi at home. The obvious question for anyone who has hosted anything at home is: how do phones reach it from outside?

The honest answer for most people is a tunnel. Port forwarding fights with carrier-grade NAT and exposes your home IP. A VPN on every family member's phone is a support burden. Cloudflare Tunnel gives you a public hostname on your own domain, hides your IP, filters scanners, and needs nothing installed on the client. It is what I plan to use myself.

It also terminates TLS at Cloudflare's edge and hands your origin plain HTTP. That is the part this post is about.

## What a tunnel actually sees

End-to-end encryption protects message content. In Arveil, content is protected by MLS and each envelope is additionally sealed with HPKE to the receiving device, so a tunnel cannot read a single message. That is necessary and not sufficient.

Look at what my first protocol draft put in HTTP:

- Routes like `POST /v1/mailboxes/{id}/envelopes` and `POST /v1/key-packages/claim`.
- Mailbox identifiers, delivery identifiers, blob identifiers.
- Bearer tokens: a session token per device, and *capabilities*, which are random secrets that authorize writing to a mailbox or reading a blob.

Behind a TLS-terminating tunnel, all of that is readable by the intermediary. The identifiers let it build the social graph in more detail than timing alone. The bearer tokens are worse: with them the intermediary could write envelopes into mailboxes, exhaust a device's KeyPackages, or acknowledge deliveries that were never received. It could not decrypt anything, but it would move from *observer* to *actor*. And my "pin the realm's TLS certificate" bootstrap step stops working, because the client sees Cloudflare's certificate, not mine.

None of this is a problem with Cloudflare. It is a problem with a protocol that assumed TLS ends where the server begins. Tailscale Funnel, a rented VPS doing TCP passthrough, or a corporate proxy would each reveal a different subset. A protocol whose security depends on the deployment topology is a protocol waiting to be misdeployed.

## The fix: put the channel inside the carrier

The change is small to describe. Every connection between a device and the relay starts with a [Noise](https://noiseprotocol.org/noise.html) `IK` handshake inside the WebSocket. The device already has a static X25519 key in its signed credential. The realm has a static key certified by its signing key, and that signing key's hash is in the QR code you scan when you join. The handshake proves both sides to each other. After it, every API operation is a CBOR frame inside the Noise transport.

Now the layering is:

```text
Application event
  → MLS (group encryption, device authentication)
  → HPKE envelope per receiving device
  → CBOR frame inside the Noise channel (device ↔ relay)
  → WebSocket over whatever carrier: LAN, tailnet, tunnel, public port
  → TLS, optional, validated with ordinary WebPKI
```

What Cloudflare sees changes from "the whole API" to "a WebSocket carrying opaque frames": the IP of each client, when it connects, how many bytes flow and when. That is the same thing any ISP on the path sees. The mailbox identifiers, the capabilities, the frame types and the endpoint list are all inside the channel.

There is precedent. Signal serves its chat service behind CDNs and uses a Noise handshake inside the WebSocket for exactly this reason. It is a boring, well-understood technique, which is the kind I want in a project that promises not to invent cryptography.

## Three things fall out for free

**LAN needs no certificates.** Since TLS no longer carries any security requirement, the relay on your home network can serve plain `ws://` or a self-signed certificate and lose nothing. The previous design had an open issue about how to provision and pin LAN certificates for a family. That issue is now closed by deletion.

**Several access paths at once.** The realm publishes a signed, sequenced list of endpoints: a LAN address, a Tailscale name, a public hostname behind the tunnel. Clients keep the highest sequence they have seen, reject rollbacks, and try endpoints by priority. A wrong or hostile endpoint costs nothing: the handshake fails before any frame is sent. Being at home, on the tailnet or on mobile data is not a mode; it is which endpoint answered first.

**Multi-node without consensus.** Because the truth lives in the clients and deliveries are idempotent, the redundancy story becomes "run a second independent relay in another household, each with its own tunnel, and let devices publish a route per relay". No leader, no Raft, no shared SQLite. The previous plan involved evaluating rqlite and PostgreSQL replication. That plan is now the fallback.

## What it does not fix

A tunnel still learns who connects, when, and roughly how much they send. Bucketed padding blurs sizes; it does not hide activity. If that residue matters to you, Tailscale Funnel or a VPS with TCP passthrough see only TLS bytes, and switching is a matter of editing the endpoint list. The threat model says this in a table rather than in a footnote, because the point of a self-hosted messenger is that the operator gets to make that call knowingly.

The first-message limitation of `IK` is real: the initiator's first message has no forward secrecy against later compromise of the responder's static key, and it can be replayed. The relay therefore carries no application data in that message and acts on nothing before the handshake completes. Key rotation happens by publishing a new endpoint list with a new static key and a short overlap window.

## Where this lives

The decision is [ADR-008](../adr/ADR-008-carrier-independent-transport.md). The channel profile, frame catalog and endpoint list object are in the [protocol draft](../PROTOCOL.md#endpoints-and-carriers). The table of what each intermediary sees is in the [threat model](../THREAT_MODEL.md#2-adversaries-and-scenarios). Phase 0 has an explicit acceptance test: a capture from the origin side of a TLS-terminating proxy must show nothing but opaque frames.

If you host things at home and have opinions about this, the design is the thing to argue with right now. The code comes next.
