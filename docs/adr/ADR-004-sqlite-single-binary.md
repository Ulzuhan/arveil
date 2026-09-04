# ADR-004 — SQLite and filesystem in a single server binary

- **Status:** proposed.
- **Date:** 2026-09-04.
- **Documentation edition:** v0.3; verification scope in the [index](../README.md#references-and-traceability).

*Versión en español: [../es/adr/ADR-004-sqlite-single-binary.md](../es/adr/ADR-004-sqlite-single-binary.md)*

## Context

The target user hosts a small circle in a homelab. The simplicity of installing, copying, updating and repairing matters as much as performance. A mandatory broker, external database and object storage add points of failure before proving they are necessary.

## Decision

Use one Go process with SQLite in WAL for memberships, public material, access control and queues. Store immutable encrypted blobs on the local filesystem. Package one server binary per platform and an optional image with a persistent directory.

One realm per instance, one logical writer, short transactions and backpressure. The database uses compatible local disk; no NFS/SMB for WAL and no shared writing by several instances. The TLS proxy and the observability tools are optional, not mandatory data dependencies.

The compatibility of the SQLite driver with static builds, licenses, maintenance, durability parameters and platforms must be validated before choosing it. A distributable binary does not require the whole ecosystem to use a single language or process.

## Verified durability requirements

**Engine:** require SQLite 3.51.3 or later, or a documented backport of the WAL-reset fix, such as 3.44.6 or 3.50.7. The bug affects certain races between writing and checkpointing. Verify the version actually embedded by the driver and by SQLCipher, not just the wrapper package. [Source: SQLite, WAL-reset](https://sqlite.org/wal.html).

**Commit:** use `journal_mode=WAL` and `synchronous=FULL` on the connections that perform durable writes. With `NORMAL`, a power loss can lose an already committed transaction. Also review the operating-system-specific synchronization options; the guarantee depends on storage and VFS honouring their contract. [Source: SQLite, synchronous](https://sqlite.org/pragma.html#pragma_synchronous).

These conditions are design requirements for the server and for local cryptographic state. A benchmark cannot relax them without explicitly changing the semantics offered to the user. Tests must distinguish killing the process from losing power on the host.

## Alternatives

| Alternative | Advantage | Reason to defer |
|---|---|---|
| PostgreSQL | Write concurrency and multi-instance operation | Adds a service and an independent backup without demonstrated need |
| Redis/RabbitMQ | Advanced queue features | SQLite offers sufficient durability as an initial hypothesis |
| Mandatory S3/MinIO | Object scale/management | Increases dependencies for the files of a household group |
| In-memory-only database | Superficial simplicity | Would lose pending deliveries on restart |

## Operational consequences

Write and disk performance set the limit; WAL does not offer unlimited concurrent writers. The Standalone profile does not promise high availability. Persistence latency, locks, fan-out, WAL size and GC are measured before expanding scope.

V1 offers offline backup of the complete directory after a clean stop. A future online copy must coordinate SQLite snapshot, blobs and cleanup. Blobs are uploaded to staging and committed with a documented persistence order; a reconciler removes orphans after a safe window.

The server backup contains metadata and operational secrets and needs external encryption and access control. It does not replace the personal identity kit or the history archive. Restoring does not authorize rolling back the clients' cryptographic state.

Migration with backup and exclusive access; rollback via a compatible snapshot. Retention, quotas and expiry are shown to the operator and the client. Exhausted space produces an error, never a non-durable acceptance of delivery.

## Acceptance criteria

Install and start without an external DB; test process kill, full disk, large WAL, expiry and isolated backup/restore. Measure representative load on household hardware, without claiming Raspberry Pi performance before measuring it. Validate directory permissions and upgrade between two schema versions.

Reopen when metrics demonstrate sustained saturation or when it is decided to study HA. [ADR-007](ADR-007-optional-realm-redundancy.md) records that possibility after V1, without replacing this decision for Standalone. Choosing PostgreSQL or rqlite would require reviewing adapters, atomic operations and operation; a transparent migration is not guaranteed and no distributed profile is added preemptively.

References: [architecture](../ARCHITECTURE.md), [SQLite WAL](https://sqlite.org/wal.html), [backup](https://sqlite.org/backup.html). Review scope: [index](../README.md#references-and-traceability).
