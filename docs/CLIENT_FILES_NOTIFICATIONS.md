# Opening attachments and receiving notifications

**Source increment, September 30, 2026; not yet a published client release.**
Tracked in [issue 140](https://github.com/Ulzuhan/arveil/issues/140).
Android notification direction: self-hosted delivery without Google/FCM.

*Versión en español: [es/CLIENT_FILES_NOTIFICATIONS.md](es/CLIENT_FILES_NOTIFICATIONS.md)*

## Open a file from the conversation

Choose **Download and open** on an incoming attachment, or **Open** on a file
already available locally. PNG, JPEG and WebP images open inside Arveil with
zoom. Opening an already available file works offline. **Save copy…** remains a
separate export action; previewing does not add a file to Downloads or Photos.

The viewer gets authenticated bytes from Rust's existing `exportAttachment`
API, which checks availability, decryption and integrity. Despite its name,
that API returns bytes and does not write an exported file. The image decoder
uses content signatures, owns and disposes its image, and avoids Flutter's shared
image cache. Encoded size stays under the attachment limit; decoded source
dimensions are limited to 16,384 per side and 64 million pixels, with the display
image scaled to at most 4,096 per side and 4 million pixels. Only the first frame
is displayed. HTML/SVG are not rendered as web content.

PDF and other formats currently use **Open with…**, following an explicit
confirmation that another application receives decrypted bytes. Android uses a
`FileProvider` scoped to `cache/attachment-open`, a content URI and temporary
read permission. macOS opens a private temporary file through `NSWorkspace`.
Each opening gets its own random directory. Copies expire after one hour, with
cleanup every 30 seconds while running and on the next launch after expiry.
Android revokes URI grants during cleanup; Mac directories/files use 0700/0600
and are excluded from backup. External applications can retain their own copies;
cleanup cannot erase those copies or promise secure deletion.

An internal PDF renderer remains a separate increment. It must be reviewed for
plaintext staging, resource limits and renderer isolation before adoption.

## macOS notifications and background operation

**Settings → Notifications** offers two independent, off-by-default options:

- **Show notifications on this Mac** requests the system's alert/sound permission.
  Notices are generic; no name, message text, filename or conversation identifier
  is passed to the operating system.
- **Keep Arveil running in the background** keeps the profile unlocked and syncs
  every ten seconds. Closing the window hides it; the menu-bar item can reopen
  Arveil or quit it. Closing the profile removes the background menu and notices.

The same Rust profile and conversation coordinator own synchronization and read
state. Window focus, route visibility and sync eligibility are separate: hidden
activity is not marked read. New unread activity in the visible conversation is
silent; own activity, unchanged snapshots and the initial history snapshot are
also silent. Several new conversations in one snapshot produce one generic
notice. A tap selects a known conversation; a token no longer known opens the inbox.

Presentation receipts are SHA-256 hashes of a group/cursor pair, bounded to 512
entries in the nonsynchronizing login Keychain. They contain no previews or
read markers. A receipt is saved before presenting, so a crash in that interval
can miss a banner; it cannot change unread messages. The mapping from notice
tokens to conversations exists only in memory.

Explicit Quit, a closed profile or a sleeping Mac stops this local delivery.
macOS Focus/notification settings can silence it. Opening/waking catches up
through normal sync. This does not provide delivery into a terminated process
or use APNs. Packaged-app permission, menu/window behavior, click handling and
sleep/wake delivery still require interactive acceptance before a release promise.

## Android: self-hosted experiment

```mermaid
flowchart LR
  R[Relay] -->|Generic mailbox hint| N[Self-hosted ntfy]
  N -->|Connection from phone| D[Android ntfy distributor]
  D -->|UnifiedPush callback| A[Arveil generic notification]
  A -->|Open existing profile and sync| R
```

The Mac mini can host ntfy beside the relay. This source increment adds an
experimental Android receiver using the official UnifiedPush connector 3.0.10
and the ntfy distributor as a second application. Install ntfy's F-Droid flavor,
configure its default server to your own HTTPS server, then enter the same base
address in **Arveil → Settings → Notifications** and enable activity notices.
Grant Android's notification permission. A returned endpoint must belong to that
server and path; the public ntfy.sh service is rejected. HTTP loopback is allowed
only in debug builds for disposable acceptance.

Registration, rotation and removal run through the already-open Rust profile
executor. Offline changes are retained and retried on resume or every 30 seconds
while active. Disabling immediately suppresses local notices even if remote
removal is pending. A revision guards against an older network response marking
a newer endpoint as applied. Opening a different identity unregisters the old
local subscription. This does not promise remote removal from a closed profile.

The native receiver stores its delivery capability encrypted with a separate
Android Keystore key. It never starts Flutter, opens a profile, decrypts a message
or changes read state. It accepts only the exact generic marker and coalesces
notices until a successful foreground sync. A hint received while visible remains
eligible for one notice when Arveil goes into the background before sync finishes;
an already displayed or dismissed notice is not replayed on each transition.
A tap opens Arveil's inbox after
unlock. Generic notices can arrive with the profile closed; disable them before
closing if that is unwanted. Endpoint changes received in the background ask
the person to open Arveil to finish registration.

This is specifically ntfy's plaintext generic-marker path, supported by the
connector's plaintext fallback. It is **not** a general WebPush/VAPID sender;
the modern UnifiedPush encrypted-payload path remains separate work. Hints are
untrusted activity, never proof of a sender or a message count. The connector's
Tink dependency performs local cryptography; no FCM or Google Play Services
dependency is added to Arveil.

ntfy documents that self-hosted subscriptions avoid Firebase and its F-Droid
flavor omits Firebase entirely: [Android/UnifiedPush documentation](https://docs.ntfy.sh/subscribe/phone/).
The deployment needs a stable HTTPS address reachable from mobile data, no
Firebase key or upstream relay, and the publisher/subscriber permissions in
[ntfy's UnifiedPush configuration](https://docs.ntfy.sh/config/#example-unifiedpush).
Do not expose the acceptance test's anonymous loopback configuration publicly.
Endpoints are capabilities: keep them out of logs and protect subscriber access.
Self-hosting still reveals endpoint/IP/timing metadata to the host and any TLS proxy.

The relay already accepts a device's hint URL and sends only `arveil-hint/v1`
when its mailbox becomes nonempty. The reproducible experiment is:

```sh
cd core && cargo build -p arveil-cli
cd ..
python3 scripts/test_ntfy_hints.py --ntfy /path/to/server-capable/ntfy
# Or forward a disposable remote ntfy instance to a local port:
python3 scripts/test_ntfy_hints.py --ntfy-url http://127.0.0.1:2586
```

The first form creates its own ntfy configuration and also tests restart/outage.
The second does not stop or reconfigure the supplied server. Both build a fresh
loopback relay, use synthetic profiles and a random topic, check the fixed marker,
coalescing, acknowledgement and unregistration, then remove local test data.
Failure diagnostics remain private in ignored `.local/ntfy-acceptance`.
The official Darwin ntfy archive is client-only; its source has a
`make cli-darwin-server` target for this experiment. Verified with ntfy v2.28.0.

### Remaining reliability and integration work

- Hints are currently best effort: one attempt, five seconds, no retry. A missed
  hint does not trigger again while mail stays pending; normal sync recovers it.
  HTTP error responses also currently count as sent. A retry/coalescing policy
  would change the timing policy in [Phase 3](PHASE3.md) and needs an explicit design.
- Before accepting general delivery endpoints, constrain destinations, resolved
  addresses and redirects, with intentional operator exceptions; bound delivery
  concurrency. Scheme validation alone is not an outbound network policy.
- Verify the complete relay → real ntfy Android distributor → Arveil path with
  endpoint rotation, process death and notification taps. The instrumented
receiver test uses a disposable distributor fixture, not a real ntfy app.
- Test screen-off/Doze, battery saver, Wi-Fi/mobile switching, restart, process death,
  Recents swipe and force-stop/reopen on a physical phone. Measure delay and battery.
  A server cannot bypass [Android's background limits](https://developer.android.com/training/monitoring-device-state/doze-standby).
- An embedded receiver could later remove the second app, but needs a legitimate
  service lifecycle. A `dataSync` service cannot be assumed to run indefinitely;
  see [Android foreground service limits](https://developer.android.com/develop/background-work/services/fgs/timeout).

## Evidence and limits

The implementation passes Flutter analysis and 298 unit/widget tests, including
preview bounds, external-sharing confirmation, failed verification, notification
deduplication, permission denial and hidden read-marker protection. Debug builds
passed on macOS and Android. Disposable native macOS acceptance checks encrypted
transfer/reopen, offline sent/received image preview, cancellation, duplicate
filenames and the explicit export boundary.

The local ntfy v2.28.0 run passed marker/coalescing/unregistration, restart and
missed-hint catch-up. A disposable Linux ARM64 ntfy on the Mac mini also passed
marker/coalescing/unregistration over an authenticated loopback SSH forward;
its service and data were removed afterwards. Neither run used Firebase or an
upstream provider. The remote run did not test its server's restart/outage.

The Android receiver passes native emulator instrumentation through the official
connector, Keystore and notification manager: unknown-token/wrong-marker rejection,
server mismatch rejection, generic delivery, coalescing and local disable. A
regression test also covers a foreground hint followed by a background transition
without another push, repeated transitions and dismissal before sync. Five
Dart tests cover registration, rotation races, offline removal, foreground-only
sync and preserving a hint after failed sync. These are separate from the ntfy
transport experiment; they do not establish physical-phone delivery.
Native macOS profile acceptance also passed relay registration, exact marker
delivery, endpoint rotation/removal and reopening the encrypted profile.

Separate macOS native acceptance passed window hiding/reopening, real external
text-file opening, 0700/0600 temporary permissions and expiry cleanup. With Arveil's
notification permission enabled in macOS settings, notification-center delivery
and removal on profile close also pass. The test reopens the window before
closing the profile, so removing the last background keep-alive does not terminate
the acceptance process. Packaged permissions, visible banners, taps, sleep/wake
and physical Android are still release gates.
Contact testing is deferred to the next iteration.
