# ADR-008 — Carrier-independent transport: Noise channel and endpoint list

- **Status:** proposed.
- **Date:** 2026-09-04.
- **Documentation edition:** v0.4.
- **Scope:** authentication and confidentiality between device and realm; access via LAN, tailnet, direct Internet, tunnels and CDN; preparation for several relays.

*Versión en español: [../es/adr/ADR-008-carrier-independent-transport.md](../es/adr/ADR-008-carrier-independent-transport.md)*

## Context

The realm must be reachable through any of these paths, and often through several at once: household LAN, a Tailscale tailnet, port forwarding on the router, Tailscale Funnel, a Cloudflare tunnel with its own domain or a VPS forwarding TCP. The reference operator plans to use Cloudflare Tunnel; family members must need only the application.

Previous editions relied on end-to-end TLS for three functions: confidentiality of sessions and capabilities, binding of the realm pin and the guarantee that nobody alters requests between client and relay. With Cloudflare Tunnel, TLS terminates at Cloudflare's edge and the tunnel delivers plaintext HTTP to the origin. Such an intermediary would see routes, mailbox and delivery identifiers, timings, IPs and the bearer secrets of sessions and capabilities, with which it could write to mailboxes, consume KeyPackages or issue fake ACKs. It could not read content, protected by MLS and HPKE, but it would go from observer to actor. The TLS pin would not work either: the client would see the intermediary's certificate.

The protocol, therefore, was not transport-independent. This decision corrects that dependency.

## Decision

**1. Noise channel between the Rust core and the realm, inside any transport.** Each connection establishes a Noise `IK` handshake over WebSocket. The initiator is the device, with a static X25519 transport key declared in its `DeviceCredential` and signed by the root. The responder is the realm, with a static X25519 key certified by the realm's signing key. The device knows the realm's key from bootstrap; the realm identifies the device by its static key and checks it against the directory when the handshake completes. Prologue: protocol version and `realm_id`. Every API operation is transmitted as CBOR frames inside the channel.

**2. TLS remains a convenience layer, not a protocol security layer.** Over the Internet, `wss://` with ordinary WebPKI validation is used, to traverse proxies, CDNs and middleboxes without friction. On the LAN a self-signed certificate or `ws://` may be used; security does not depend on it. No API secret or identifier travels in URLs, HTTP headers or cookies.

**3. Signed endpoint list.** The realm publishes a signed and sequenced `RealmEndpointList` with its LAN, tailnet and public addresses, and its current Noise key. The bootstrap QR contains the initial list or its hash and a bootstrap endpoint. Clients keep the highest known one, reject rollbacks and try the endpoints by priority, switching between them without intervention. A wrong or hostile endpoint only produces a failed handshake.

**4. Separate administration plane.** Administrative frames are accepted only on endpoints marked as administrative, normally loopback, LAN or tailnet, and with a dedicated administrative credential. A public tunnel does not expose administration even if it shares the process.

**5. Multi-node via independent relays.** When several nodes exist, each one is a relay with its own identity, its own endpoint list and its own storage; devices publish one `RouteBundle` per relay. [ADR-007](ADR-007-optional-realm-redundancy.md) records this direction as preferred; V1 frames do not announce a cluster.

## Technical profile of the channel

| Element | Proposed specification |
|---|---|
| Pattern | `Noise_IK_25519_ChaChaPoly_BLAKE2s`, fixed in M0.2 and implemented on both sides (`snow` 0.10 in the core, `flynn/noise` 1.1 in the relay); the prologue is `arveil/<protocol_version>/<realm_id>` |
| Static keys | Device: `transport_noise_public_key` in `DeviceCredential`. Realm: `realm_noise_public_key` signed by the realm's signing key. Not derived from Ed25519 keys |
| First message | No application data. `IK` offers neither forward secrecy nor replay protection for the first message's payload; the server acts on nothing before the handshake completes |
| Authorization | After the handshake, the realm checks that the static key belongs to an active credential of a member; if not, it closes. Mailbox and blob capabilities are presented as frame fields |
| Frames | Deterministic CBOR, with `frame_id` for correlation, size limits before decoding and explicit responses. Noise messages have a maximum of 65,535 bytes; larger frames are fragmented and reassembled with a bounded limit |
| Lifecycle | Session = connection. Reconnecting implies a new handshake; durable mailbox cursors allow resuming. Periodic keepalive for intermediaries that close idle connections |
| Rotation | The realm's Noise key rotates by publishing a new list; the previous one is accepted during a bounded window. The device's key rotates via a new credential signed by the root |
| Carrier | WebSocket in V1. A polling HTTP carrier for networks that block WebSocket remains a future possibility, carrying the same frames |

## What each intermediary sees with this design

| Access path | Intermediary | Sees | Does not see |
|---|---|---|---|
| Direct LAN | Nobody | — | — |
| Tailnet | Tailscale coordination; DERP if NAT traversal fails | Communicating nodes, volume | Channel bytes |
| Port forwarding | Nobody, but the household IP is exposed to contacts and scanners | — | — |
| Tailscale Funnel | Tailscale ingress | TLS bytes, SNI, IP, timings | TLS content; TLS terminates on the node |
| Cloudflare Tunnel | Cloudflare | Each client's IP, timings, frame sizes, number of connections, domain | Frames, mailbox and delivery identifiers, credentials, operation types |
| VPS with TCP passthrough | VPS provider | TLS bytes, IP, timings | TLS content |

With or without Noise, no intermediary sees message content. What Noise adds is that an intermediary that terminates TLS no longer sees the API and its credentials. It still sees connection patterns and volume; bucket padding reduces the precision of sizes, it does not hide activity. This residue is documented in the [threat model](../THREAT_MODEL.md#2-adversaries-and-scenarios).

## Alternatives

| Alternative | Reason not to adopt it |
|---|---|
| Rely on end-to-end TLS and require the operator not to use a CDN | Excludes the most convenient access path for families and turns a deployment decision into a fragile security constraint |
| Sign each HTTP request with the device's key (RFC 9421) and sign responses with the realm's | Prevents an intermediary from acting, but still exposes identifiers, third-party capabilities and API structure. Serves as a fallback carrier, not as the basis |
| mTLS with device certificates | Incompatible with TLS termination at a CDN; complicates operation on LAN and on mobile |
| Require Tailscale or another VPN for all members | Adds an external identity provider, conflicts with other VPNs on mobile and installation friction; kept only as an optional path and for administration |
| Design our own channel over HPKE | Rejected: Noise is a reviewed framework with mature implementations in Rust and Go |

## Consequences

The relay ceases to be an HTTP REST server and becomes a frame server over WebSocket with optional TLS; generic HTTP inspection tools no longer show the API. Per-route caching and routing in proxies is lost, which this product does not need.

One X25519 key per device and one per realm are added, with their lifecycle. The `DeviceCredential` replaces the Ed25519 transport authentication key with the static Noise key; proof of possession to the realm becomes the handshake itself.

The LAN no longer requires certificate provisioning. Bootstrap no longer depends on a TLS pin. The endpoint list, planned in ADR-007 for HA, is brought forward to V1 and enables simultaneous access through several paths.

Intermediaries that terminate TLS are reduced to traffic observers. Cloudflare Tunnel is acceptable as the default public path, with the declared metadata residue; Funnel or a VPS of one's own are direct substitutes by changing only the endpoint list.

## Acceptance criteria

1. Capture on the origin side of a tunnel that terminates TLS: only opaque frames; no readable identifiers, credentials or operation types.
2. Handshake against an endpoint with a different Noise key: visible rejection without sending frames.
3. Endpoint list with a lower sequence or an invalid signature: rejection; switchover LAN → tailnet → public without intervention as each path fails.
4. Replay of the first `IK` message: no effect on the server.
5. Malformed or oversized frames, or incomplete fragmentation: bounded close without unlimited consumption.
6. Reconnection after a cut with durable cursors: no loss or visible duplicates.
7. Administration via a public endpoint: rejected even if the credential is valid.

## Reopen

If a polling HTTP carrier proves necessary in production; if a need arises for a sender unauthenticated to the relay, which would require a different profile; or if the ADR-007 study selects a shared-state cluster and frames need to be routed between nodes.

References: [protocol](../PROTOCOL.md#endpoints-and-carriers), [architecture](../ARCHITECTURE.md#6-homelab-and-operations), [threat model](../THREAT_MODEL.md), [ADR-007](ADR-007-optional-realm-redundancy.md), [Noise Protocol Framework](https://noiseprotocol.org/noise.html), [RFC 8949 — CBOR](https://www.rfc-editor.org/rfc/rfc8949).
