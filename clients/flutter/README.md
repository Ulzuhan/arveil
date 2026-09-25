# Arveil client

The Flutter client for [Arveil](../../README.md). It calls the Rust
application layer through `core/crates/arveil-flutter`, a thin adapter
generated with flutter_rust_bridge; identity, MLS, delivery and persistence
stay in Rust, and this project holds navigation, presentation and screen
state only ([ADR-009](../../docs/adr/ADR-009-flutter-first.md)).

## What exists today

The Spanish-language setup screen opens an encrypted profile, creates an
identity and enrolls with relay bootstrap data and a one-use invitation.
Network failure preserves the Rust enrollment state. Reopening reads that
state; a pending enrollment asks for the same invitation again, while a
completed one goes directly to the profile summary. Duplicate submissions
are disabled. Tokens stay in memory and are cleared on success or close.

Pairing with manual code comparison, cancellation and resumed completion,
and encrypted identity-kit export/restore are implemented. The profile shows
dated KeyPackage availability and can replenish or resume a failed publication.
The conversation screen lists local groups, compares contact-route safety
numbers, creates groups, pages history, queues text offline and synchronizes.
Source `0.1.0+6` adds saved contacts and local aliases, explicit verification,
recipient selection and participant names. Aliases and routes stay in the
encrypted local profile; they are not synchronized to other devices.
The [phase 3b plan](../../docs/PHASE3B.md) keeps physical-device acceptance open. The classic macOS login
Keychain works with ad-hoc signing; physical Android and fresh downloaded
macOS acceptance remain open.

Source `0.1.0+7` adds explicit attachments: native file selectors, encrypted
private storage, per-message upload/download progress, resume/cancel and
explicit export. See the [installation guide](../../docs/INSTALLATION.md).

## Installing versus developing

See the [installation entry point](../../docs/INSTALLATION.md)
([español](../../docs/es/INSTALLATION.md)) for availability and the end-user
installation requirements. There are no downloadable app releases yet.
The commands below are for developers; the intended macOS app package and
Android APK must install without Flutter/Rust on the user's machine.
The initial macOS development path must work without paid Apple membership;
the login Keychain is selected explicitly, with no plaintext fallback.
For ZIP/APK creation, see [client packaging](../../docs/CLIENT_RELEASES.md).

## Running it

```bash
flutter pub get
flutter run -d macos
```

The pinned toolchain and the platform matrix live in
[docs/PLATFORMS.md](../../docs/PLATFORMS.md). The native library is built by
`rust_builder`, which points at the adapter crate; there is nothing to build
by hand.

## Acceptance

```bash
flutter analyze
flutter test integration_test/profile_test.dart -d macos
```

`integration_test/profile_test.dart` exercises the native profile lifecycle,
queries, typed errors, locking, encryption and reopening.
`integration_test/profile_key_test.dart` exercises the real platform key store:

```bash
flutter test integration_test/profile_key_test.dart -d <device> \
  --dart-define=ARVEIL_REQUIRE_SECURE_STORAGE=true
```

The flag makes unavailable key storage fail the run instead of skipping it.

`integration_test/onboarding_test.dart` drives the real form against a
**disposable test realm**. Create a private JSON file outside the checkout
containing `ARVEIL_TEST_BOOTSTRAP` and `ARVEIL_TEST_INVITE`, then run:

```bash
flutter test integration_test/onboarding_test.dart -d <device> \
  --dart-define-from-file="$ARVEIL_TEST_CONFIG"
```

It uses platform key storage, forces an unreachable endpoint, closes and
reopens the encrypted profile, retries through the valid endpoint, and
reopens the completed enrollment without an invitation. It deletes its
temporary local profile/key; the disposable membership remains in the relay.
The define file and test build contain connection data and a short-lived
invitation: keep them private and delete them after the run. Do not use
production credentials or publish that build. Host details and tokens never
belong in committed fixtures, screenshots or test logs.

## Regenerating the bindings

After changing the Rust API, from `core/crates/arveil-flutter`:

```bash
flutter_rust_bridge_codegen generate
```

Both the Rust and the Dart generated files are committed, so a review sees
what the generator produced.

## Pairing and identity-kit acceptance

With another fresh invitation in a disposable realm:

```sh
flutter test integration_test/pairing_recovery_test.dart -d <device> \
  --dart-define-from-file="$ARVEIL_TEST_CONFIG"
```

This uses three temporary encrypted profiles and real platform key storage:
invitation enrollment, pairing, wrong comparison, reopen before confirmation,
kit export, wrong key, restore/retry/reopen and empty recovered history. It
does not automate the native file chooser: widget tests inject file selection;
manual platform acceptance must also verify save/open/cancel dialogs. Never
publish a test build containing private defines. Clean the Flutter build before
packaging a public candidate.

The updated relay is required for safe lost-response recovery retries. Before
receiving a pairing comparison, an interrupted handshake needs a new code.
Cancelling local pairing does not revoke an authorization already issued by
the administrator. Export the newest kit after device changes and keep its
secret separate; identity recovery cannot restore old history or MLS state.

## KeyPackage acceptance

From the repository root, with the pinned Flutter SDK and Go on `PATH`:

```sh
python3 scripts/test_client_key_packages.py --device macos
# Alternatively, start a disposable Android emulator; put adb on PATH:
python3 scripts/test_client_key_packages.py --device emulator-5554
```

Use the serial of your disposable emulator. The helper builds and starts its
own loopback relay, creates a private invitation and runs
`integration_test/key_packages_test.dart` with real platform key storage.
It consumes the initial five packages directly in that disposable relay's
database, then drives the UI through exhaustion, replenishment and reopen.
It verifies 15 stored packages: five consumed and ten available. The CLI
`scripts/phase4.sh` separately covers consumption by multiple real MLS groups.

The helper removes the temporary relay, credentials and emulator port forward,
then runs `flutter clean`; do not run another Flutter build concurrently.
Failed Flutter diagnostics remain private under ignored
`.local/client-acceptance/` and may contain connection data or local paths.
It accepts no shared relay or physical-phone target. Physical-device acceptance
and native file-dialog interaction are separate checks.

## Conversation acceptance

From the repository root, with Flutter and Go on `PATH`:

```sh
python3 scripts/test_client_conversations.py --device macos
# Or a disposable Android emulator, with adb on PATH:
python3 scripts/test_client_conversations.py --device emulator-5554
```

The helper starts its own loopback relay and an authenticated loopback test
control service, creates two invitations, and drives the GUI with two temporary
encrypted profiles and platform key storage. It saves a contact, explicitly
verifies its safety number, reopens the encrypted profile, selects the saved
recipient without repasting a route, renames it and creates a group,
exchanges text, stops only its own relay, queues text offline, reopens the profile,
loads older messages and reconnects without duplicates. The peer uses the native
bridge within the test app; this is not a Mac–Android cross-device test.
Text is injected by the test framework, so native keyboard/IME behavior needs
separate hands-on acceptance.

The normal release packages `0.1.0+5` separately passed Mac ↔ Android-emulator
GUI messaging, upgrade from build 2, native keyboard input, offline process
restart and reconnect without duplicates on September 24, 2026. The
[dated platform record](../../docs/PLATFORMS.md#cross-platform-package-acceptance-september-24-2026)
records the exact revision, package hashes, steps and remaining hardware,
file-dialog and fresh-download checks.

Temporary credentials and port forwards are removed; the Flutter build is cleaned.
Do not run another Flutter build concurrently. Failed diagnostics stay in ignored
`.local/client-acceptance/`. Never publish an integration-test build.

### Local Android test tooling

The conversation helper uses `flutter test` on macOS and the official
`integrationDriver` through `flutter drive --no-dds` on Android. This avoids
Flutter's golden-file proxy connection failure on the local Android toolchain;
the same integration test runs and any failed assertion still fails the helper.
No golden comparisons are used in this scenario.

A local run with Android Studio's JDK 25 also needed a fresh Gradle process and
non-incremental, in-process Kotlin compilation after the file-picker module
could not resolve Java/Android classes. These options apply only to that command:

```sh
GRADLE_OPTS='-Dorg.gradle.daemon=false -Dorg.gradle.project.kotlin.compiler.execution.strategy=in-process -Dorg.gradle.project.kotlin.incremental=false' \
  python3 scripts/test_client_conversations.py --device emulator-5554
```

Use your disposable emulator's serial. The debug CargoKit build also compiles
x86/x86-64 bridge libraries, so a clean run can take several minutes even on
an ARM64 emulator. These test-tool settings do not alter release signing or
add configuration to the app.


## Attachment acceptance

Use the same isolated helper with the attachment scenario:

```sh
python3 scripts/test_client_conversations.py --device macos --scenario attachments
# Or the disposable Android emulator:
python3 scripts/test_client_conversations.py --device emulator-5554 --scenario attachments
```

This exercises GUI confirmation, offline queue/reopen, send, explicit download,
export confirmation, identical filenames, cancellation and repeated sync with
the native bridge and encrypted storage. The two peers run inside the same
test app. File selectors are replaced by in-memory fixture adapters: this does
not verify the native open/save/cancel dialogs or write exported test files.
The Rust suite separately injects lost upload acknowledgements, interrupted
downloads and cancellation during a network request. Private fixture cleanup
and the Android tool settings above apply to both scenarios.

### Android native attachment dialogs (interactive)

On a disposable emulator, put `arveil-picker-fixture.txt` in Downloads with
exactly `Arveil attachment picker acceptance.` followed by a newline. Set
`ANDROID_DEVICE` to that emulator's serial. From this directory, run:

```sh
flutter drive --no-dds -d "$ANDROID_DEVICE" \
  --driver test_driver/integration_test.dart \
  --target integration_test/attachment_picker_test.dart \
  --dart-define=ARVEIL_TEST_NATIVE_PICKER=true
```

Select that fixture, cancel the second open dialog, cancel the first save
dialog, then save `arveil-picker-export.txt` in Downloads. The test checks the
selected bytes, cancellation results and absence of a `file_picker` plaintext
cache. Compare the exported bytes with the fixture separately, then delete
those two disposable files. No identity profile, relay or kit is used.
The test is skipped unless explicitly enabled. Keep raw diagnostics private
and run `flutter clean` afterwards; never distribute this integration build.

The bounded Android reader also has JVM regressions, run in CI. Generate the
local Gradle wrapper and SDK properties first, without building an APK:

```sh
flutter build apk --debug --config-only
cd android
./gradlew --no-daemon app:testDebugUnitTest -Ptarget-platform=android-arm64 \
  -Pkotlin.compiler.execution.strategy=in-process -Pkotlin.incremental=false
```

The fresh process avoids reusing a Gradle/Kotlin daemon that retains the
packager's temporary SDK alias after that directory has been removed.
