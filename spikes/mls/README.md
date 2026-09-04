# MLS spike (Phase 0, milestone M0.5)

Throwaway crate. Nothing here ships. Its only purpose is to answer two questions from [docs/PHASE0.md](../../docs/PHASE0.md) with test evidence, for both candidate libraries:

- **Q1** Can the library persist group state in the *same transaction* as our outbox and event log? Issue [#15](https://github.com/Ulzuhan/arveil/issues/15).
- **Q2** Can the library *inspect and reject* a commit before merging it, enough to enforce a committer policy? Issue [#16](https://github.com/Ulzuhan/arveil/issues/16).

The written comparison and the ADR-002 update are issue [#17](https://github.com/Ulzuhan/arveil/issues/17).

## Layout

| File | Contents |
|---|---|
| `src/openmls_spike.rs` | OpenMLS 0.9 baseline (2-member group, one message) and Q2: a valid commit from an unauthorized member is inspected as a `StagedCommit` and dropped before merge. |
| `src/openmls_sqlite.rs` | OpenMLS Q1: `StorageProvider` generated from the in-memory reference, writing to a key-value table on the application's connection; create + add + merge inside one transaction commit or roll back together with an outbox row. |
| `src/mlsrs_spike.rs` | mls-rs 0.56 baseline and the explicit-write model: `load_group` fails before `write_to_storage()` and succeeds after. |
| `src/mlsrs_sqlite.rs` | mls-rs Q1: `GroupStateStorage` over the shared connection; `write_to_storage` inside the application's transaction. |
| `src/mlsrs_policy.rs` | mls-rs Q2: `CommitterPolicy` implementing `MlsRules`; a valid commit from a non-authorized leaf fails in `process_incoming_message`, epoch unchanged, group still usable. |
| `src/main.rs` | Runs every experiment and prints the outcomes. |

## Running

```bash
cargo test
```

```bash
cargo run
```

All seven tests pass and none is ignored. The written comparison is [docs/spikes/M0.5-mls-library-comparison.md](../../docs/spikes/M0.5-mls-library-comparison.md).

## Notes to carry into the comparison

- Crypto providers used here are RustCrypto-based for both libraries because they build without system dependencies. mls-rs marks its RustCrypto provider as experimental; its stable providers are OpenSSL and AWS-LC. Provider choice for mobile is a separate check, not part of Q1/Q2.
- OpenMLS forbids `content-debug` and `crypto-debug` in distributed builds ([ADR-002](../../docs/adr/ADR-002-mls.md)); verify transitive features when the winner is integrated.
- Both libraries support custom GroupContext extensions, which the committer policy needs. Neither enforces our policy by itself.
