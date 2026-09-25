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

- The graphical client opens encrypted profiles and supports invitation enrollment, retry and durable setup state on reopen. Pairing and identity-kit interfaces are implemented. Conversation creation, paginated history, text sending and sync are implemented. Contacts, explicit attachments and device management are implemented; encrypted history export/import is implemented. Experimental ZIP/APK packaging exists; physical-mobile acceptance remains pending.
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
now includes the history and loss/recovery slice described below; physical-device acceptance remains open.


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

## Encrypted history and loss recovery (fourth M3b.4 slice)

Source `0.1.0+9` adds **Historial cifrado** to the profile. CLI and GUI share
`Application::export_archive` / `import_archive`; the bridge also exposes a
bounded read-only page and explicit attachment export. The archive is an age
file with a fresh, separate secret. It contains neither identity/device private
keys nor active MLS state. The UI reveals the secret only after a successful
save and hides it on leaving/backgrounding, without copying it to the clipboard.

Exports include live and previously imported history. Available managed files
are authenticated before inclusion. Pending/cancelled/expired attachments and
legacy CLI downloads have metadata only; export never fetches from the relay or
reads a path recorded in a message. Imports sanitize filenames and discard old
attachment descriptors/paths. Imported file bytes, including empty files, stay
in SQLCipher until the user explicitly chooses a destination for a copy.

Import requires the same identity (restore its kit first after loss), validates
the entire archive before writing, and commits records/files in one transaction.
Existing `(group_id, event_id)` records are retained unchanged and counted as
duplicates. No outbox, live event or MLS state is created. The paginated archive
screen has no composer; imported text is historical data, not authenticated
proof of authorship or delivery. Direction labels include locally queued messages;
the archive does not preserve delivery receipts. Re-export preserves imported
records and available files.

Limits: 64 MiB encrypted input, 10,000 records per archive, 1 MiB per text,
the existing attachment limit below 25 MiB, and a conservative 48 MiB export
payload budget. Oversized exports fail as a whole; no silent truncation or
automatic splitting. v1 archives remain readable; the optional `file_present`
field distinguishes available empty files in new exports. Older archives with
an empty byte array cannot establish whether an empty file was present.

Rust tests cover a different profile key, wrong identity/secret, tampering,
transaction rollback, duplicate preservation, pagination, re-export and corrupt
attachment refusal. Widget tests cover consent, cancellation, hidden secrets,
bounded reads and sanitized errors. The native `archives` scenario destroys a
disposable source profile, restores its identity under a new platform-held key,
imports from memory, reopens, checks no resend or automatic rejoin, and exchanges
text through an explicitly created new conversation. It never exports real user
data. See [platform evidence](PLATFORMS.md) for completed native runs.

## Profile schema versioning (September 25, 2026)

The profile database records its schema version in `PRAGMA user_version`, and
`arveil_core::schema` applies ordered migrations when a connection opens.
Before this, every open reapplied `CREATE TABLE IF NOT EXISTS` statements. That
adds new tables but cannot change an existing one: the Phase 4 `contacts.name`
column had been added by editing the table text, so a profile from before it
lacked the column.

- A profile without a version, as written by every build up to `0.1.0+11`, is
  version 0. Migration 1 adds any missing baseline table, adds `contacts.name`
  when absent and compares every table's columns with the baseline. Any other
  difference is refused as an unsupported development profile, and the
  rollback leaves its tables and rows unchanged.
- Each migration commits together with the version it sets. A failure keeps
  the previous version, and the next open resumes from there.
- A profile with a newer version is refused before the connection writes
  anything, including the journal-mode pragma. The application reports
  `ProfileTooNew`; the GUI asks for an app update and states that the profile
  was not changed. A wrong key is still reported as before.
- Builds up to `0.1.0+11` do not read the version. Version 1 changes no existing
  table beyond that repair, so they still open an adopted profile, but a later
  migration may not stay compatible with them. Do not install an older app over
  a newer one; Android already refuses a lower build number.
- The baseline texts (`MLS_SCHEMA`, `CLIENT_SCHEMA`, `DELIVERY_SCHEMA`) are
  frozen. A schema change is a new migration at the end of the list, with a
  test that starts from the previous version.

Evidence: the `schema` tests in `arveil-core` cover new, adopted, repaired,
unsupported, newer (plain and SQLCipher), negative-version, interrupted and
resumed, and reopened profiles. `arveil-app` checks that `Application::open`
refuses a newer profile and releases it, and a Flutter test checks the message.
A local run used real `main` binaries to create an encrypted and a plain CLI
profile with a live MLS conversation. The new CLI adopted both and the
conversation continued without loss. The old CLI still read the adopted
profile, and a copy marked as version 2 was refused without byte changes.
Workspace tests, Clippy, the MLS spike and the demo and phase scripts passed.
Upgrading packaged apps with populated profiles on Android and macOS is still
an acceptance step of the [client redesign](PHASE3B.md).

## Message senders and times (September 25, 2026)

Every history event now says who wrote it and when this device recorded it.
Migration 2 adds `sender_device` and `sender_identity` to `events`. Both are
nullable, so builds up to `0.1.0+11` still read and write a version 2 profile;
a CLI run confirmed it.

- Processing an MLS application message (text or attachment announcement)
  stores the device behind the sending leaf, which MLS has just
  authenticated. It also stores the identity this profile knows for that
  device: its own for this device and the devices it authorized, or a peer's
  from that conversation's roster. Messages this device writes are stored as
  its own.
- Reading history resolves what was unknown on arrival: a device learned later
  is named from the roster at read time. Events recorded before version 2 keep
  empty senders, except that this device's own sent kinds are its own. A
  received row is never attributed by guessing.
- `HistoryEventView` gains four fields:
  - `created_at`: Unix seconds when this device recorded the event, which is
    arrival for received events and creation for sent ones. It is not when the
    sender wrote it; the protocol does not carry that time.
  - `sender_identity`: the identity that wrote the event, when known.
  - `sender_label`: the local contact name or a short identifier, absent for
    own events and for unknown senders.
  - `own`: written by this identity, from any of its devices.
- The conversation screen:
  - Aligns own messages to the own side, including those from another device
    of the same identity.
  - Names the author of received messages when more than one other identity
    writes in the conversation.
  - Shows the recorded time.

  The complete redesign of this screen is a later step of the
  [client plan](PHASE3B.md).
- Imported history records carry their time but not yet their sender. Changing
  the archive format is a separate step.

Evidence:

- Core tests cover the sender round trip, the device-to-identity lookup and
  migration 2.
- An application test uses a real in-process MLS group. It covers another
  identity learned only after its message, another device of the same
  identity, older rows and a contact rename.
- The bridge conversion and Flutter widget tests cover the new fields,
  author naming, own-side alignment and time formatting.
- An upgrade run from `main` binaries adopted a profile to version 2. The next
  received message carried the peer's device and identity, the next sent
  message was own, earlier rows stayed empty, and the old CLI still read the
  profile.

## Conversation summaries and unread counts (September 25, 2026)

Each conversation row now carries three things: its newest event, how many
messages are unread, and when the conversation was last active. The bridge
orders the GUI list by that activity. The application layer keeps the order in
which conversations were started, because the command line lists them that way
and the Phase 4 acceptance script picks conversations by position.

- Migration 3 adds `read_markers`, one cursor per conversation. Conversations
  that existed before it count as read up to their newest event, so an update
  does not turn old messages into new ones.
- `mark_read(group, cursor)` only moves a marker forward, and never past the
  newest event. A stale screen or an overreaching caller therefore cannot hide
  what arrives later. The call returns the marker in effect and the remaining
  unread count.
- Unread counts the events after the marker that another identity wrote. It
  never counts this device's own kinds or messages from another device of the
  same identity. Received rows from before sender attribution count when they
  come after the marker.
- `ConversationView` gains three fields:
  - `last_event`: the kind, a one-line text preview of at most 120 characters,
    the attachment name, the sender label, whether it is own, the time and the
    delivery states.
  - `unread`: the number of unread messages.
  - `last_activity`: the time of the newest event, or when this device started
    keeping the conversation.

  GUI rows are ordered by activity. Event order breaks ties within a second,
  and a full tie keeps the start order. As in history, only text bodies cross
  the bridge.
- The GUI marks the open conversation read up to the newest event it shows. It
  does so only in the foreground and once per cursor. A failure leaves the
  marker where it was, and the next read retries. Rows show the preview (with
  the author in groups and "Tú:" for own messages), the time and an unread
  count that screen readers announce as part of the row.

Evidence:

- A bridge test covers ordering by activity and its tie-breaking.
- Core tests cover markers that only move forward and stop at the newest event,
  unread counts that exclude own kinds and own devices, and migration 3.
- An application test goes through the executor. It covers the start order,
  previews, stale marks, markers after reopening, and new messages becoming
  unread again.
- A bridge test checks that the preview cuts multibyte text safely, stays on
  one line and never exposes a non-text body.
- Flutter tests cover marking once, row previews and unread counts.
- An upgrade run from `main` binaries adopted a CLI profile to version 3. What
  it held before counted as read, the first message after the update was
  unread, and the old CLI still read the profile.

## Kit reminder, device notices and sync status (September 25, 2026)

- **Identity kit state.**
  - Migration 4 adds `kit_exports`. Exporting a kit records it as pending,
    together with the manifest sequence it carries. Only `confirm_kit_saved`,
    which the GUI calls when the user states that the file and its key are
    stored, makes it the saved kit.
  - The setup status reports `kit_saved_at` and `kit_stale` on the
    administration device. A kit is stale when the device manifest advanced
    after it was saved.
  - The ready screen reminds the user when no kit was saved or the kit is
    stale. "Más tarde" hides the reminder until the profile is opened again.
  - The CLI export does not confirm anything.
- **Device-change notices.**
  - Migration 5 keeps the active device set of each contact manifest this
    profile accepted. The next accepted manifest yields how many devices it
    added and removed. The first manifest learned is a baseline and
    announces nothing.
  - A changed manifest, whether it arrived through a group or from the relay,
    records a local `devices-changed` notice in every conversation shared
    with that identity. The notice commits in the same transaction as the
    manifest.
  - Notices carry counts, never device identifiers. They have one stable
    identifier per conversation and manifest sequence, never count as unread
    and are left out of history archives.
  - The GUI shows a centred note. It points to the verified identity's
    signature when the contact is verified, and suggests comparing safety
    numbers otherwise. `chat history` in the CLI prints notices on one line.
- **Sync status.** The conversation controller keeps a presentation-only
  projection: never synced, syncing, synced (with the time of the last
  success), offline or refused. Only a typed transport error counts as
  offline; any other failure comes from a server that answered. The screen
  shows one line about the last successful sync and never claims delivery.

Evidence:

- An application test goes through the executor. It covers pending and
  confirmed kits, a device authorization that makes the kit stale, and a new
  confirmation that clears it.
- Core tests cover device changes from real contact manifests (baseline, a
  repeated manifest, a linked device, a revoked device), notices never
  counting as unread and stable notice identifiers.
- An application test with a real in-process MLS group covers a baseline
  manifest with no notice and a linked device announced in both shared
  conversations, with no unread count and no duplicate on repetition.
- Flutter tests cover the kit reminder and its confirmation, notice wording
  and the verified and unverified variants, and the sync projection
  distinguishing offline from refused without exposing diagnostics.
- A CLI run against a real relay: bob learned alice's baseline manifest with
  no notice. After alice linked a laptop, bob's history showed one notice for
  one added device, and a further sync did not repeat it. An upgrade run from
  `main` binaries adopted profiles to version 5, and the old CLI still read
  them.

## Authors in the encrypted history (September 25, 2026)

Exported history records now name their author when the exporting device
knew it, as it does for live history: the identity stored with the event,
the roster identity for its device, or this identity for what it sent.

- The author is an optional `sender_identity` inside archive format version
  1, following the `file_present` precedent, instead of a new format version.
  A record without an author writes exactly the bytes it wrote before.
  Earlier archives import without authors, and builds that predate the field
  ignore it.
- Migration 6 adds `sender_identity` to `archived_events`. Importing keeps the
  first copy of a record, so a later archive naming another author for the
  same record is a duplicate and changes nothing. An author that is not a
  32-byte identity is refused, and nothing from that archive is imported.
- The encrypted-history page and imported conversations show the author by
  local name or short identifier, marked as the archive's account ("según el
  archivo"): an archive is user-supplied history, not proof of authorship.
- Device-change notices never enter an export. The exporter refuses unknown
  kinds, so leaving notices out also keeps exports working after a notice.

Evidence: a core test reads and writes the format in both directions. An
application test exports authored, own, unattributed and notice rows,
imports them into a restored profile, checks labels in the archive page and
imported conversations, confirms that a later conflicting author is ignored,
and refuses a malformed author. A Flutter test covers the label. The Phase 2
archive flows pass with the CLI, and an upgrade run from `main` binaries
adopted profiles to version 6.

## Design foundation (September 25, 2026)

The client now draws with its own design system instead of a seeded Material
scheme and system fonts.

- **Fonts.** Newsreader, Instrument Sans and IBM Plex Mono are bundled
  unmodified (SIL OFL 1.1) from `google/fonts` at a recorded commit, with
  their SHA-256 in `clients/flutter/assets/fonts/README.md`. Their licenses
  are registered on Flutter's license page. Nothing is fetched at runtime.
  Weights of the variable fonts are set through their axes.
- **Tokens.** `ArveilColors` carries the plan's light and dark tokens, plus
  avatar and sender colours chosen stably by identity. `lineStrong` was
  added for control borders, and `onDanger`, `dangerSoft` and
  `onDangerSoft` for error states. `ArveilTheme` maps the tokens onto
  Material, and the app follows the system light or dark setting.
- **Components.** Brand mark (from the icon's own path), avatar, verified
  mark, unverified chip, unread badge, delivery icon, date separator,
  notice chip, status banner, sync line, safety-number grid, empty state,
  settings group and row, chat bubble with runs, conversation tile and
  composer. Icons are Material's outlined set, already bundled with
  Flutter.
- **Launch screen.** On Android, the icon's pine green shows with the
  ribbon mark, through the system splash API from Android 12. Behind the
  first Flutter frame the window uses the ground colour, so nothing
  flashes white. macOS has no launch screen.

Evidence:

- A unit test checks WCAG AA contrast for every text/background pair and
  3:1 for control borders, in both themes.
- Goldens of a conversation sheet and an identity sheet, in light and
  dark, render the bundled fonts and icons. The comparator tolerates at
  most 0.5 % differing pixels.
- Behaviour tests cover the delivery mapping (never "read"), initials,
  spoken labels, and components fitting a 390 px phone at 200 % text.

The existing screens only pick up the new colours and type; the redesigned
screens are the C packages of the [client plan](PHASE3B.md).
