# Application foundation: implemented status

Status: local implementation reviewed during the September 5, 2026 iterations. This is neither a release nor a security audit. [Versión española](es/CLIENT_FOUNDATION.md).

## Architecture and evidence

CLI → `arveil-app` → `arveil-core`; the planned Flutter/bridge will call the same application layer. `arveil-app` coordinates operations and returns structured results; core retains identity, MLS, persistence and delivery primitives. Noise/WebSocket connects to the independent Go relay, which does not hold client E2EE keys. A Flutter client and its bridge now exist and open, query and close a profile; no messaging interface does.

| Change | Implementation and verification |
|---|---|
| CLI extraction | [Application](https://github.com/Ulzuhan/arveil/blob/main/core/crates/arveil-app/src/lib.rs) owns conversations, sending, sync, revocation and attachments; [chat](https://github.com/Ulzuhan/arveil/blob/main/core/crates/arveil-cli/src/chat.rs) adapts arguments and presentation. |
| Structured contract | `ClientCommand`, `CommandOutput`, `ApplicationError`, `StateChange`, `MessageReceipt`; errors retain `partial_result()`, local acceptance follows commit and categories do not depend on error text. |
| Delivery correlation | [Delivery](https://github.com/Ulzuhan/arveil/blob/main/core/crates/arveil-core/src/delivery.rs) pending rows include `event_id`; cursor updates use the maximum of current/new values. |
| Explicit profile configuration | `ProfileConfig` carries directory, key, TLS authority and expiry policy; the library reads no environment variable. The CLI translates its own. `Debug` redacts the key, and a malformed key is refused before anything is created. |
| Session lifetime | A second independent open of one canonical directory returns `AlreadyOpen`, whatever key it offers; sharing means cloning the handle. `open` opens the database, so a wrong key fails there instead of at the first command. `close` stops admission, waits for running work and joins the worker, which owns the lock; dropping the last handle takes the same path. |
| A panic ends its session | A command that panics is caught at the boundary: the caller gets a typed failure naming the operation, everything queued behind it is answered rather than left waiting, and nothing else runs on that session. A transaction interrupted by an unwind rolls back, since `unit_of_work` now ends its transaction from `Drop`. The profile is untouched on disk and opens again once the session is closed. This holds where the build unwinds; a build that aborts on panic ends the process and no contract survives it. |
| Progress while work runs | A bounded projection reaches subscribers as each change is recorded, not when the operation answers: message queued and received, publication, delivery state, transfers, sync, pairing and enrollment steps. A subscriber that falls behind loses events and is told how many, so it re-reads instead of trusting a partial view; the durable result still carries everything. |
| Paged history | `QueryHistoryPage` takes a conversation, a cursor and a capped limit; identifiers only grow, so a page never shifts when events arrive while a caller reads backwards. Summaries read a count and the newest row instead of every body. Local reads no longer require an enrolled realm. |
| Bounded admission | Work is counted per kind: two syncs, thirty-two other mutations, a hundred and twenty-eight queries. Beyond that a command is refused with a typed `Busy` that started nothing; slots return when the work finishes, not when a caller walks away. Queries keep room of their own, so they answer while syncs are saturated. |
| Profile executor | Canonical paths share a single-thread runtime that multiplexes network waits without interleaving synchronous MLS/SQLite segments. Events use operation context; the public call remains blocking. |
| Operation exclusion | One active sync per profile; `CompleteLink`/`ConfirmPairing` share separate exclusion. Local queries can progress during network waits. |
| Transactions | [SharedConn](https://github.com/Ulzuhan/arveil/blob/main/core/crates/arveil-core/src/storage.rs) holds a reentrant mutex throughout transactions, allowing MLS storage callbacks. `Client.conn` is private. |
| Transport | [Carrier](https://github.com/Ulzuhan/arveil/blob/main/core/crates/arveil-app/src/carrier.rs) bounds connection, handshake, requests and close. Request timeout discards websocket/Noise and requires reconnection. |
| Resumable downloads | Transport failure retains `file-pending` and `.part` for subsequent sync; it is not treated as permanent unavailability. |
| Reusable onboarding | [Onboarding](https://github.com/Ulzuhan/arveil/blob/main/core/crates/arveil-app/src/onboarding.rs) owns identity, enrollment, grants and pairing; [CLI link](https://github.com/Ulzuhan/arveil/blob/main/core/crates/arveil-cli/src/link.rs) presents results. |
| Explicit/resumable pairing | Sessions identify start/wait/approve/query/confirm/cancel. Code/expiry are checked before finalization; cancellation after commitment returns `AlreadyCommitted`. Direct grants and confirmation share persisted `Committing`→`Complete` phases with retry-grant identity checks. |
| Cross-process exclusion | `ProfileGuard`/`Application` acquire an OS lock on `.arveil-profile.lock` after canonicalization. CLI also protects legacy commands. Another process receives `ProfileInUse`; unlocking does not delete the file. |

GUI and CLI may alternate ownership, not access the profile concurrently. Future simultaneous use would require single ownership with IPC, outside the initial plan. Source links follow repository `main`; merge this local implementation record in the same PR/merge as its source changes, or afterwards. Do not publish a documentation-only PR first with links to files still absent from `main`: Pages deploys independently and strict MkDocs does not check external targets. Before publication, verify every linked path exists in the target commit; a SHA/tag is useful only if already published and containing those files.

## Test provenance

The last workspace `cargo test --workspace --locked` run passed 72 tests, including a helper process test, with one ignored; demo, interop, q3-capture and phases 1–4 also ran locally. The M3b.0 acceptance flow ran on the device on macOS and on an Android emulator (Android 15, API 35, arm64); no physical phone yet. The [platform matrix](PLATFORMS.md) records the pinned toolchain and the commands. `git diff --check` passed. These are local-checkout results at that time, not cross-platform or remote CI certification.

Coverage includes `overlapping_pairing_confirmations_share_one_mailbox_and_route`, `direct_grant_completion_resumes_after_network_failure`, and `late_response_cannot_contaminate_a_second_request`. [Application lock tests](https://github.com/Ulzuhan/arveil/blob/main/core/crates/arveil-app/tests/profile_lock.rs) cover normal closure, abrupt termination, distinct profiles and Unix symlink aliases; [CLI tests](https://github.com/Ulzuhan/arveil/blob/main/core/crates/arveil-cli/tests/profile_lock.rs) cover legacy protection.

The implementer also reported Clippy and phases 1–4 passing in earlier iterations. The last review did not rerun them; record fresh acceptance against a specific commit before release.

## Remaining limits

- The graphical client opens, queries and closes a profile and nothing else: enrollment, pairing, conversation, attachments and device management have no interface. No graphical installers, and no validation on a physical mobile device.
- Only the CLI reads environment variables now, and it still chooses an unencrypted profile when no key is set. Platform key stores remain pending (M3b.1).
- Blocking API requires an asynchronous Dart adapter. Events return at operation completion; streaming and general cancellation need contracts.
- File/membership events need further correlation identifiers. Progress is a projection: changes it does not model reach a caller only in the durable result.
- Actual MLS rejoin/recovery remains pending; the fictitious `recover_conversation` was removed. Sync does not solve desynchronization.
- Coordinator succession relies on verified revocations, not automatic election on disconnection.
- Relay SQLite pool/per-connection configuration needs independent follow-up.
- Recovery/archive/contact legacy commands still need application APIs where required by GUI.

Next: [Flutter plan](PHASE3B.md), [ADR-009](adr/ADR-009-flutter-first.md).
