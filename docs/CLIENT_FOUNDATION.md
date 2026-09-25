# Application foundation: implemented status

Status: implementation record updated September 23, 2026; earlier acceptance results retain their original scope. This is neither a release nor a security audit. [Versión española](es/CLIENT_FOUNDATION.md).

## Architecture and evidence

CLI → `arveil-app` → `arveil-core`; Flutter calls the same application layer through its Rust bridge. `arveil-app` coordinates operations and returns structured results; core retains identity, MLS, persistence and delivery primitives. Noise/WebSocket connects to the independent Go relay, which does not hold client E2EE keys. The Flutter client opens encrypted profiles, enrolls by invitation, pairs devices and exports/restores encrypted identity kits through the Rust bridge. Durable progress survives reopening; verified group creation, paginated history, offline text and sync are implemented.

| Change | Implementation and verification |
|---|---|
| CLI extraction | [Application](https://github.com/Ulzuhan/arveil/blob/main/core/crates/arveil-app/src/lib.rs) owns conversations, sending, sync, revocation and attachments; [chat](https://github.com/Ulzuhan/arveil/blob/main/core/crates/arveil-cli/src/chat.rs) adapts arguments and presentation. |
| Structured contract | `ClientCommand`, `CommandOutput`, `ApplicationError`, `StateChange`, `MessageReceipt`; errors retain `partial_result()`, local acceptance follows commit and categories do not depend on error text. |
| Delivery correlation | [Delivery](https://github.com/Ulzuhan/arveil/blob/main/core/crates/arveil-core/src/delivery.rs) pending rows include `event_id`; cursor updates use the maximum of current/new values. |
| Explicit profile configuration | `ProfileConfig` carries directory, key, TLS authority and expiry policy; the library reads no environment variable. The CLI translates its own. `Debug` redacts the key, and a malformed key is refused before anything is created. |
| Session lifetime | A second independent open of one canonical directory returns `AlreadyOpen`, whatever key it offers; sharing means cloning the handle. `open` opens the database, so a wrong key fails there instead of at the first command. `close` stops admission, waits for running work and joins the worker, which owns the lock; dropping the last handle takes the same path. |
| Enrollment resumes | One enrollment at a time per profile, with its phase written down as each step becomes durable and the invite kept as a hash rather than a token. A repeat of the same enrollment continues where it stopped and keeps one identity, one mailbox and one route; a different realm or invite is refused and leaves the recorded enrollment untouched. |
| Redeeming an invite twice | The relay records what a redemption produced - token, identity and credential - inside the same transaction that consumes the use, and answers a repeat of that exact triple with the result it recorded rather than a conflict. Another credential for the same identity still conflicts: hash equality is not authorisation. A repeat consumes no further use, and a database written by a newer relay is refused before anything is modified. Mailbox creation now reuses the persisted request and capabilities. The initial KeyPackage batch and its private MLS state are committed together before publication; a lost acknowledgement resends the same bytes, and completion prevents another batch. The relay applies quota after deduplication and never revives consumed packages. |
| The profile key belongs to the platform | 32 random bytes from the operating system, generated in Rust and kept by Keychain or Keystore, without synchronization. iOS/Android use device-bound protection; macOS uses the classic login Keychain and its app access controls. Never derived from a passphrase. A profile whose key is gone is reported, never given a new one: that would answer "nothing here" to someone whose history is on disk. Android refuses cloud backup and device transfer; Apple marks the profile directory excluded on every start. Denied key-store access is reported; no plaintext fallback is used. |
| A panic ends its session | A command that panics is caught at the boundary: the caller gets a typed failure naming the operation, everything queued behind it is answered rather than left waiting, and nothing else runs on that session. A transaction interrupted by an unwind rolls back, since `unit_of_work` now ends its transaction from `Drop`. The profile is untouched on disk and opens again once the session is closed. This holds where the build unwinds; a build that aborts on panic ends the process and no contract survives it. |
| Progress while work runs | A bounded projection reaches subscribers as each change is recorded, not when the operation answers: message queued and received, publication, delivery state, transfers, sync, pairing and enrollment steps. A subscriber that falls behind loses events and is told how many, so it re-reads instead of trusting a partial view; the durable result still carries everything. |
| Paged history | `QueryHistoryPage` takes a conversation, a cursor and a capped limit; identifiers only grow, so a page never shifts when events arrive while a caller reads backwards. Summaries read a count and the newest row instead of every body. Local reads no longer require an enrolled realm. |
| Bounded admission | Work is counted per kind: two syncs, thirty-two other mutations, a hundred and twenty-eight queries. Beyond that a command is refused with a typed `Busy` that started nothing; slots return when the work finishes, not when a caller walks away. Queries keep room of their own, so they answer while syncs are saturated. |
| Profile executor | Canonical paths share a single-thread runtime that multiplexes network waits without interleaving synchronous MLS/SQLite segments. Events use operation context; the public call remains blocking. |
| Operation exclusion | Sync, network KeyPackage checks and replenishment share one exclusion per profile; `BeginPairing`/`CompleteLink`/`ConfirmPairing` share exclusion, pairing waits/approvals are serialized, and enrollment/recovery share another exclusion. Local queries can progress during network waits. |
| Transactions | [SharedConn](https://github.com/Ulzuhan/arveil/blob/main/core/crates/arveil-core/src/storage.rs) holds a reentrant mutex throughout transactions, allowing MLS storage callbacks. `Client.conn` is private. |
| Transport | [Carrier](https://github.com/Ulzuhan/arveil/blob/main/core/crates/arveil-app/src/carrier.rs) bounds connection, handshake, requests and close. Request timeout discards websocket/Noise and requires reconnection. |
| Resumable downloads | Transport failure retains `file-pending` and `.part` for subsequent sync; it is not treated as permanent unavailability. |
| Reusable onboarding | [Onboarding](https://github.com/Ulzuhan/arveil/blob/main/core/crates/arveil-app/src/onboarding.rs) owns identity, enrollment, grants and pairing; [CLI link](https://github.com/Ulzuhan/arveil/blob/main/core/crates/arveil-cli/src/link.rs) presents results. |
| Explicit/resumable pairing | Sessions identify start/wait/approve/query/confirm/cancel. Code/expiry are checked before finalization; cancellation after commitment returns `AlreadyCommitted`. Direct grants and confirmation share persisted `Committing`→`Complete` phases with retry-grant identity checks. |
| Cross-process exclusion | `ProfileGuard`/`Application` acquire an OS lock on `.arveil-profile.lock` after canonicalization. CLI also protects legacy commands. Another process receives `ProfileInUse`; unlocking does not delete the file. |

GUI and CLI may alternate ownership, not access the profile concurrently. Future simultaneous use would require single ownership with IPC, outside the initial plan. Source links follow repository `main`; merge this local implementation record in the same PR/merge as its source changes, or afterwards. Do not publish a documentation-only PR first with links to files still absent from `main`: Pages deploys independently and strict MkDocs does not check external targets. Before publication, verify every linked path exists in the target commit; a SHA/tag is useful only if already published and containing those files.

## Test provenance

The original foundation `cargo test --workspace --locked` run passed 72 tests, including a helper process test, with one ignored; demo, interop, q3-capture and phases 1–4 also ran locally. The M3b.0 acceptance flow ran on the device on macOS and on an Android emulator (Android 15, API 35, arm64); no physical phone yet. The [platform matrix](PLATFORMS.md) records the pinned toolchain and the commands. `git diff --check` passed. These are local-checkout results at that time, not cross-platform or remote CI certification.

Coverage includes `overlapping_pairing_confirmations_share_one_mailbox_and_route`, `direct_grant_completion_resumes_after_network_failure`, and `late_response_cannot_contaminate_a_second_request`. [Application lock tests](https://github.com/Ulzuhan/arveil/blob/main/core/crates/arveil-app/tests/profile_lock.rs) cover normal closure, abrupt termination, distinct profiles and Unix symlink aliases; [CLI tests](https://github.com/Ulzuhan/arveil/blob/main/core/crates/arveil-cli/tests/profile_lock.rs) cover legacy protection.

The implementer also reported Clippy and phases 1–4 passing in earlier iterations. The last review did not rerun them; record fresh acceptance against a specific commit before release.

## Remaining limits

- The graphical client opens encrypted profiles and supports invitation enrollment, retry and durable setup state on reopen. Pairing and identity-kit interfaces are implemented. Conversation creation, paginated history, text sending and sync are implemented. Contacts, explicit attachments and device management are implemented; history archive UI remains pending. Experimental ZIP/APK packaging exists; physical-mobile acceptance remains pending.
- Only the CLI reads environment variables now, and it still chooses an unencrypted profile when no key is set. Platform key storage is tested on an Android emulator and the ad-hoc macOS build with its login Keychain. Physical-phone and fresh-download acceptance remain pending.
- The Rust bridge runs blocking calls off the UI thread and exposes incremental progress streams. General operation cancellation and full platform lifecycle acceptance remain pending.
- File/membership events need further correlation identifiers. Progress is a projection: changes it does not model reach a caller only in the durable result.
- Actual MLS rejoin/recovery remains pending; the fictitious `recover_conversation` was removed. Sync does not solve desynchronization.
- Coordinator succession relies on verified revocations, not automatic election on disconnection.
- The relay applied its pragmas once, so only the connection that ran them had a busy timeout or enforced foreign keys; they now travel in the connection string, and a test holds several connections and checks each. Write transactions also reserve the writer before reading (`BEGIN IMMEDIATE`), preventing read-to-write upgrade failures under cleanup or concurrent requests; WAL readers remain concurrent. See the [contention regression](PHASE1.md#storage-contention-regression). Pool sizing itself is still unbounded and remains open.
- Identity-kit CLI commands use the application service. Archive legacy commands still need application APIs where required by GUI; the GUI contact API is described below.

Next: [Flutter plan](PHASE3B.md), [ADR-009](adr/ADR-009-flutter-first.md).

## Invitation enrollment

The invitation form keeps its token only in memory and clears it on completion or profile close. The profile executor answers a typed onboarding snapshot after open and enrollment attempts. Malformed relay/invitation input is rejected before identity creation. UI errors use fixed categories without interpolating paths or remote diagnostics. The tests cover retry, duplicate submission, late-open cleanup and failure-message redaction. This covers the invitation slice of M3b.2. The pairing and identity-kit additions below do not close the milestone: physical-device acceptance and native file-dialog checks remain open. The KeyPackage implementation is recorded below.

## Pairing and identity kits (September 23, 2026)

The setup offers invitation, linking and restore. A linked device compares the
short code manually before applying its grant; a wrong code cannot finalize it.
An interrupted wait **before receiving the comparison** needs cancellation and
a new pairing code. Once the comparison is stored it survives reopening; once
confirmation commits, finalization resumes using the same device/mailbox.
Cancellation is local and does not revoke authorization already issued by the
administrator. The administration screen states this before issuing a grant
and keeps the comparison visible afterwards. Its network wait is bounded to
90 seconds; cancelling that administration wait is not implemented.

Kit export uses a native save dialog for ciphertext only. The separate secret
appears only after a successful save, disappears on leaving/backgrounding the
screen, and is never saved by Arveil. Explicit deferral displays the recovery
risk. Restore requires an empty profile, the kit, its key and the original
relay bootstrap; the user confirms revocation and loss of previous history.
Use the latest kit, exporting again after changing devices. Old kits can be
refused when the relay already knows a newer manifest. Recovery restores
identity, not history or MLS group state.

CLI and GUI share atomic local preparation and a durable recovery journal.
A transport failure preserves the same credential and offers resume without
reimporting the file. The relay records the exact signed recovery request and
its original manifest sequence in one transaction; an identical authenticated
retry succeeds, while changed, expired or revoked credentials are refused.
This requires the updated relay (schema 4); older relays do not provide lost
recovery-response idempotency. Back up before upgrading; a downgrade refuses
the newer schema. Rollback warnings persist across restart.

Tests cover UI consent, wrong/expired comparison, cancellation during wait,
cancelled export, secret removal on background, atomic preparation rollback,
and recovery retries after client/relay restart. Native test reproduction is
in the [Flutter README](https://github.com/Ulzuhan/arveil/blob/main/clients/flutter/README.md).
These changes do not publish or replace the existing alpha candidate.

Fresh checks for this change: 87 Rust tests passed (one ignored), Go tests with
the race detector, Flutter analysis and 16 widget/unit tests, native macOS
and Android-emulator acceptance, phases 2, 3 and 3b acceptance, and strict bilingual documentation
build. These are local results; see the platform matrix for the precise scope.

## KeyPackage availability and replenishment (September 23, 2026)

The profile screen shows a dated observation of the relay's available
one-use keys. Opening a profile reads local state without a network request;
unknown availability is distinct from zero. A failed refresh keeps the last
observation with a visible warning. Exhaustion blocks other devices starting
new conversations with this device, not existing conversations.

At three or fewer available packages, replenishment prepares enough for a
target of ten. Public retry bytes and private MLS state commit together before
publication. CLI sync and the GUI share that journal and serialize their
network operations. After a lost acknowledgement, reopening and retrying sends
the same batch; relay deduplication never revives consumed keys. If all keys
in that batch were consumed before retry, acknowledgement clears the journal
and another explicit replenishment can create fresh keys. A fresh status query
after publication supplies the displayed count, allowing for concurrent claims.

Current checks: 89 Rust tests passed (one ignored), Clippy, 20 Flutter
widget/unit tests, and native macOS and Android-emulator acceptance. The local phase 4 script passed,
including actual MLS group consumption and CLI replenishment; its Docker build
was skipped because Docker was unavailable. Native GUI fixture consumption and
platform evidence are described in the [platform matrix](PLATFORMS.md).
Physical-phone and native file-dialog acceptance remain open. Source version
is `0.1.0+4`; the existing alpha candidate is unchanged.

## Conversation interface (M3b.3)

Source client `0.1.0+5` adds an adaptive list/detail screen, explicit sharing of
this device's route, comparison of each peer's safety number, verified group
creation, history pages and text composition. Editing routes invalidates the
comparison. Rust validates route sizes, duplicate devices and the exact compared
numbers before pinning contacts. This uses the existing identity/MLS protocol;
it is not an independent security assessment.

`QueueMessage` commits the MLS state, event and encrypted outbox before returning
its receipt, without network access. Flutter clears only the accepted draft;
sync publishes the saved envelopes. Creation failures after commit return the
saved group plus a warning so the UI does not create it again. The CLI shares
the same local send transaction. Text is limited to 32 KiB of UTF-8.

History stays queryable during sync. The screen refreshes local projections from
progress and completed operations; while foregrounded it also syncs every ten
seconds and on resume, with manual retry. This is foreground polling, not push
or background delivery. A refresh reconciles the displayed history in pages of 50, retaining the older
pages the user opened and stopping if the screen or selection changes. Presentation distinguishes local storage,
relay acceptance, unavailable delivery and receipt on this device. It does not
claim human reading, authenticated author labels or message timestamps. Contact names and attachment actions are implemented in M3b.4 below; group
membership controls remain later work.

Regression coverage includes symmetric route comparison and all-or-nothing
contact confirmation, queue/reopen without a relay, post-commit bridge results,
blocked sync with responsive history, joined sync callers, cancelled watcher dispatch, stale selections, pagination with arrivals,
route-edit invalidation, received text, draft retention and duplicate submission.
Lifecycle regressions cover backgrounding during startup and retaining the
conversation controller and draft when Flutter rebuilds its route.
The [platform record](PLATFORMS.md) gives the native acceptance scope; the
[Flutter README](https://github.com/Ulzuhan/arveil/blob/main/clients/flutter/README.md)
provides the isolated reproduction command.

## Local contacts and recipient selection (first M3b.4 delivery)

Source client `0.1.0+6` adds an address book, local aliases, explicit safety-number
verification and creation from saved contacts. Conversations use participant
names and expose a participant list with identity/device identifiers and
verification/revocation status. These labels do not authenticate individual
message authors and do not synchronize to other profiles.

Routes (including mailbox capabilities) are stored in an additive `contact_routes`
table inside the GUI's encrypted profile. List projections expose identifiers
and revocation flags, not route capabilities. Saving, renaming and verifying
run through the profile executor; contact, alias, route and optional verification
commit atomically. Editing a route clears the UI comparison. Reimporting the
same device updates its route without duplicating it; an empty import name
preserves the existing alias, while explicit rename can clear it.

Creation accepts saved identity/device identifiers. Rust reloads their routes
and requires verified contacts, matching identity/root/device bindings, distinct
devices and no locally known revocation before network creation. The existing
post-commit receipt/warning behavior still prevents a retry from inviting the
user to recreate a saved group. Up to 16 saved devices can be selected; unknown
revocations and stale routes still depend on sync and relay validation.

Existing contacts learned from conversations can be named and verified; if no
route was saved, import one before selecting that contact. Alias and verification
survive profile reopen. The conversation acceptance helper now exercises this
flow before its duplex-text, offline/reconnect and pagination checks. M3b.4
still owes history archive UI and the complete loss/recovery demonstration.


## Explicit attachments (second M3b.4 slice)

Source client `0.1.0+7` adds file selection, confirmation, durable local queueing,
explicit download, progress, cancellation and explicit export. The limit is
25 MiB including the 16-byte encryption tag (26,214,384 source bytes). Files
are identified by conversation and `event_id`, so equal names never select or
overwrite another private copy. Native selectors grant access to the chosen
source/destination; their paths and URIs are not persisted with the message.
Android reads the selected document directly through the
[Storage Access Framework](https://developer.android.com/training/data-storage/shared/documents-files)
into bounded memory on a worker thread, without the general picker's plaintext
cache or persistent URI grants. The stream limit applies even when a provider
omits or misreports the size. macOS streams the selected file. A provider may
keep its own source copy; Arveil does not control that provider's storage.

The GUI opts into manual attachment handling. Sync receives descriptors but
never downloads their blobs automatically. Descriptors, transfer state and
ciphertext chunks live in additive tables on the same SQLCipher connection
as events and MLS. No decrypted download is written by the GUI. Export checks
size, hash and AEAD authentication before returning bytes to the platform
save dialog. File-event bodies are stripped at the Flutter bridge: neither
capabilities, file keys nor legacy filesystem paths reach history widgets.

Queueing allocates one durable event before network work. Upload resumes
from the relay's offset; a lost acknowledgement or application reopen does
not allocate another message. The final MLS send unit commits the existing
event, outbox and transfer completion together. Retry after that point only
synchronizes the stored message. Downloads persist contiguous ciphertext
chunks and verify the complete file before exposing export. One transfer
runs at a time per profile; history and cancellation remain responsive
while it waits for the network. Interrupted files require an explicit resume.

Cancellation is checked after each network wait and prevents later local
writes or message commitment. It discards unfinished local data. It cannot
recall a committed message or immediately erase bytes already uploaded to
the relay; remote cleanup follows its existing expiry policy. A cancelled
incoming download can be requested again. A 410 is shown as expired; a 403
is unavailable/access denied, not proof of expiry. Neither action renews
capabilities. Legacy CLI-downloaded files remain outside this managed flow.

Rust regressions cover lost upload acknowledgements, interrupted download
and encrypted reopen, cancellation during an outstanding request, duplicate
names, conversation scoping, invalid sizes/authentication, expiry and denial.
Widget tests cover confirmations, retrying the existing event, save-dialog
cancellation, changing conversation during file selection and phone layouts.
The native attachment scenario uses two profiles and a disposable relay,
with in-memory selector substitutes. Actual OS picker dialogs, a physical
phone and cross-app release-package acceptance remain separate checks.
Android JVM tests additionally cover exact-limit and empty input, oversized
unknown-length streams and cancellation before reading.


## Own devices and resumable revocation (third M3b.4 slice)

Source `0.1.0+8` adds **Manage devices** to the profile screen. The local
inventory identifies the current device, root-administrator authority and
known revoked devices. A linked or recovered profile may know credential
hashes without their device identifiers; the screen explicitly counts these
unknown entries rather than claiming a complete inventory. It reports the
local manifest version, not online presence or current relay state.

Only the administrator can revoke another known own device. Confirmation
shows its full identifier and explains permanent revocation, deferred relay
enforcement and preservation of copies/history already held by that device.
Rust rejects self-revocation, unknown identifiers and linked-device authority.
Replaying an old link request cannot reauthorize a known revoked device; a new
link requires a fresh profile and new device keys.

The manifest, revoked peer flags and revocation journal commit together.
A retry reuses the existing revocation; it never signs a new version merely
because a reply was lost. Each conversation journals its manifest notice
atomically with MLS state and sealed outbox entries. The designated committer
removes the leaf locally; other coordinators must apply removal separately
(the existing CLI `chat remove` remains available). Regular sync resumes
confirmed revocations, publishes the newest manifest before the outbox and
reuses sealed bytes and delivery IDs. Sync and revocation share one exclusion;
local queries remain available while network work waits.

The UI distinguishes local revocation, relay acceptance, conversations still
holding the leaf, queued notices, rejected/expired notices and missing routes.
Relay acceptance does not prove peer receipt. Missing routes are reported,
not repaired automatically. Known revoked leaves block new sends until removed;
offline participants may not yet know the revocation. This does not implement
remote erasure, automatic recovery, history import or MLS rejoin.

Rust regressions cover lost manifest/envelope ACKs, encrypted reopen, rejected
authority/targets, rollback of failed local units and a later device link while
publication is pending. Widget tests cover target confirmation/cancellation,
partial inventories, sanitized errors, retry by sync and closing during a wait.
The native `devices` scenario pairs disposable profiles, revokes offline from
the UI, reopens, synchronizes, checks the revoked handshake is refused and
exchanges text with a remaining peer after MLS removal. Platform results are
recorded separately in [PLATFORMS](PLATFORMS.md).

The relay in this change atomically stores the signed manifest and revokes its
credentials/capabilities. An identical latest manifest is acknowledged again
after a lost reply; a different manifest at the same version or an older
version remains rejected. Store regressions cover restart, rollback and an
interrupted publication left by an older relay. Update the relay together with
this client: earlier relays reject duplicate manifest publication with 409, so
they cannot complete this lost-ACK retry path.
