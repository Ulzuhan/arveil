# MLS spike (Phase 0, milestone M0.5)

Throwaway crate. Nothing here ships. Its only purpose is to answer two questions from [docs/PHASE0.md](../../docs/PHASE0.md) with test evidence, for both candidate libraries:

- **Q1** Can the library persist group state in the *same transaction* as our outbox and event log? Issue [#15](https://github.com/Ulzuhan/arveil/issues/15).
- **Q2** Can the library *inspect and reject* a commit before merging it, enough to enforce a committer policy? Issue [#16](https://github.com/Ulzuhan/arveil/issues/16).

The written comparison and the ADR-002 update are issue [#17](https://github.com/Ulzuhan/arveil/issues/17).

## Layout

| File | Contents |
|---|---|
| `src/openmls_spike.rs` | OpenMLS 0.9 baseline (2-member group, one message) and the Q2 flow: a valid commit from an unauthorized member is inspected as a `StagedCommit` and dropped before merge. Q1 is a stub: OpenMLS writes through the `StorageProvider` trait during every operation, so Q1 means implementing that trait over a SQLite connection that already holds our transaction. |
| `src/mlsrs_spike.rs` | mls-rs 0.56 baseline and the explicit-write model: `load_group` fails before `write_to_storage()` and succeeds after. Q2 is a stub: mls-rs applies incoming commits immediately; policy must go through `MlsRules` or the identity provider, and the spike has to show that a rejected commit leaves state untouched. |
| `src/main.rs` | Runs both baselines and prints epochs, for a quick eyeball check. |

## Running

```bash
cargo test
```

```bash
cargo run
```

Tests marked `#[ignore]` are the open questions. Removing the attribute and making them pass is the milestone.

## Notes to carry into the comparison

- Crypto providers used here are RustCrypto-based for both libraries because they build without system dependencies. mls-rs marks its RustCrypto provider as experimental; its stable providers are OpenSSL and AWS-LC. Provider choice for mobile is a separate check, not part of Q1/Q2.
- OpenMLS forbids `content-debug` and `crypto-debug` in distributed builds ([ADR-002](../../docs/adr/ADR-002-mls.md)); verify transitive features when the winner is integrated.
- Both libraries support custom GroupContext extensions, which the committer policy needs. Neither enforces our policy by itself.
