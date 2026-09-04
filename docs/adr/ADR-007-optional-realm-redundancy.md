# ADR-007 — Optional realm redundancy after V1

- **Status:** proposed for future exploration; out of V1, with no implementation commitment.
- **Date:** 2026-09-04.
- **Documentation edition:** v0.4.
- **Current decision:** keep Standalone as the default profile; study optional redundancy with **independent relays** as the preferred direction and a shared-state cluster as the alternative, without choosing a replication engine yet.

*Versión en español: [../es/adr/ADR-007-optional-realm-redundancy.md](../es/adr/ADR-007-optional-realm-redundancy.md)*

## Context and objective

A family may have several Raspberry Pis or mini PCs, in the same homelab or in different households. The goal is to explore having another machine continue deliveries when a machine, its connection or an entire household fails. This capability fits with sovereignty and service continuity, as long as the single-node household installation remains complete and simple.

High availability and load balancing are distinct objectives. The priority is to preserve and deliver messages in the face of failures; distributing load is justified later with measurements. The cluster replicates the same realm and does not introduce federation between communities.

## Proposed direction

| Profile | Possible scope | Commitment |
|---|---|---|
| Standalone | One server process, local SQLite and filesystem | Basis of V1; no tolerance to node loss |
| Backup | Recoverable copy or replica with controlled promotion | Lower complexity; possible loss of writes not yet replicated |
| Independent relays (preferred) | Several autonomous relays, each with its own key, its own SQLite and its own endpoint list; one `RouteBundle` per relay and delivery to all of the recipient's relays | No leader or consensus; duplicates resolved by the existing deduplication; attachments are uploaded to each relay or referenced with a known expiry |
| Shared-state cluster (alternative) | Several nodes, durable replica and automatic replacement of the primary | Requires additional coordination, operation and testing |

Independent relays fit the trust model: the truth lives in the clients, deliveries are idempotent and the channel of [ADR-008](ADR-008-carrier-independent-transport.md) makes each relay reachable through its own access path. The cost moves to the client, which manages several routes per contact and several cursors, and to fan-out, which multiplies by the number of relays. The loss of a relay does not require promotion: the other one keeps delivering.

For the shared-state cluster, a write leader with replicas and an existing mechanism for election and fencing of the old leader would be evaluated. Several instances can receive connections and forward requests to the leader; that does not imply allowing divergent writes. Do not build a consensus protocol of our own or share the SQLite file over a network filesystem.

The Standalone profile keeps the single-binary objective. The HA profile might need auxiliary processes; its packaging depends on the selected solution. Adding an optional configuration must not turn its dependencies into V1 requirements.

## What must survive the failure

The replica must cover queues, deduplication, ACKs and deletions, consumption of invitations and KeyPackages, manifests, revocations, capabilities, quotas and blob references. Encrypted attachments need their own replication policy; copying only the database does not preserve the files.

HA mode must fix, before being implemented:

- **RPO:** which confirmed data it may lose under each contemplated failure.
- **RTO:** how long it takes to recover delivery, including client reconnection.
- **Acceptance:** at what point an envelope or blob is considered sufficiently replicated.

The aspiration of synchronous HA is not to lose confirmed sends in the face of an individual failure covered by the design; it is not a current guarantee. If asynchronous replication is chosen, the loss window is declared. A local queue or an E2EE receipt is not confused with replication confirmation.

A file transfer cannot be announced as durable if its descriptor is replicated but its bytes exist only on the machine that just failed. Blob cleanup and deletion tombstones must be coordinated so as not to resurrect data or delete files that are still needed. Replication does not replace independent historical backups.

## Locations, majority and partitions

In a majority scheme, three voting nodes allow continuing with two available. Placing two in one house and one in another does not allow losing either house indistinctly: losing the first eliminates the majority. To tolerate the loss of any household with that topology, three independent locations would be studied, one per vote and with sufficient data to recover. The quorum and the set of replicas holding each blob must be considered separately.

Three machines with the same router, power supply and Internet access protect against some machine failures, but share other failures. An election witness does not replace a copy of the data either. With two nodes, a manual promotion or an additional fencing mechanism may be viable, but safe automatic replacement is not promised without resolving partitions.

The side that loses write authority leaves operations pending; the client keeps its local history and outbox. Two isolated houses are not allowed to confirm incompatible changes and merge them later by date. After reconnecting, the old primary must acknowledge its loss of authority before serving writes again.

## Client access and security

Availability requires multiple authenticated endpoints of the same realm or an equally redundant network entry point. A single load balancer, tunnel or router in the failed household would nullify the data redundancy. The client must reconnect, resume fetch and repeat idempotent deliveries; live WebSocket connections are not migrated between machines.

The association between endpoints and realm is resolved by the signed `RealmEndpointList` of [ADR-008](ADR-008-carrier-independent-transport.md), already in V1; with independent relays each relay publishes its own. Several replicas of a tunnel on the same domain give ingress failover to the shared-state cluster without a load balancer of its own. Internal communications need mutual authentication and node authorization; belonging to the realm as a user does not grant access to the cluster.

E2EE stays on the clients. Replicating does not introduce MLS members nor copy personal root keys or conversation secrets to the server. It does widen the exposure of metadata and operational secrets. Cluster nodes require mutual operational trust: we do not assume that majority election protects the availability or integrity of the service against malicious participants. If mutually distrusting operators are desired, independent relays would have to be studied as a separate architecture.

This mode does not recover a lost client device either, nor does it resolve the loss of the MLS commit coordinator. They are distinct failure domains.

## Options to evaluate, no selection

| Candidate | Evidence consulted | Implication for the project |
|---|---|---|
| rqlite | SQLite with Raft; writes coordinated by a leader and access via HTTP API; not a drop-in replacement for SQLite | Test adaptation of operations/transactions and acceptance semantics, in addition to the operational cost |
| PostgreSQL with replicas | Synchronous/asynchronous replication; failure detection and failover require external mechanisms | Advanced-profile alternative if its operation proves manageable |
| LiteFS | Asynchronous replication; Fly warns that it does not offer support or assistance for the product | Do not prioritize it as the basis of a promise to preserve confirmed sends |

Official sources consulted on 2026-09-04: [rqlite FAQ](https://rqlite.io/docs/faq/), [PostgreSQL replication](https://www.postgresql.org/docs/current/warm-standby.html), [PostgreSQL failover](https://www.postgresql.org/docs/current/warm-standby-failover.html), [LiteFS](https://fly.io/docs/litefs/) and [how LiteFS works](https://fly.io/docs/litefs/how-it-works/). Revalidate versions, maintenance, licenses and platforms when the prototype starts. An engine's documentation does not demonstrate the durability of our complete application.

## Reasonable preparation from V1

Keep persistence interfaces small, domain operations with explicit atomicity, idempotent delivery IDs, retries and retention limits. Separate blob access from queue logic. Do not implement leader election, cluster discovery, multiple drivers or placeholder configuration in advance. Switching storage is not guaranteed to be transparent: a distributed API may require redesigning transactions.

## Gates before adopting HA

1. Prototype of node loss during write, ACK, file upload and leader change; verify against the client's operation history which confirmed data survives.
2. Partitions between households, loss of majority and return of the old primary: no double writer and no rollback of known revocations.
3. Failure of the ingress endpoint, reconnection and retries: no visible duplicates and no feigned acceptance.
4. Consistency of DB and blobs, restore from backup and version upgrade with lagging replicas.
5. Measurement of RPO/RTO, WAN latency, bandwidth, consumption and space on representative household hardware; no assumed performance figures.
6. Installation experience, node join/leave and HA deactivation. Reducing a cluster to one node requires a procedure, not switching off the other machines.

For independent relays the gates are different: delivery to two relays with one down during the send, deduplication of envelopes received by both, per-relay cursors after reinstallation and attachments with one relay absent. The result of the prototype will decide whether independent relays, a shared-state cluster or backup only is adopted. That choice will update this ADR and the protocol and domain contracts before promising new compatibility or guarantees.

Related: [architecture](../ARCHITECTURE.md#9-possible-evolution-optional-realm-redundancy), [ADR-004](ADR-004-sqlite-single-binary.md), [threat model](../THREAT_MODEL.md#7-additional-threats-if-optional-ha-is-adopted), [current protocol](../PROTOCOL.md) and [recovery](ADR-006-local-first-recovery-first.md).
