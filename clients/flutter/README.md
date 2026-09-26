# Arveil for macOS and Android

The Flutter app for [Arveil](../../README.md). It calls the Rust application
layer through `core/crates/arveil-flutter`, a thin adapter generated with
[flutter_rust_bridge](https://github.com/fzyzcjy/flutter_rust_bridge).
Identity, MLS, delivery and persistence stay in Rust; this project holds
navigation, presentation and screen state only
([ADR-009](../../docs/adr/ADR-009-flutter-first.md)).

## What the app does

- **Getting in.** Opens an encrypted profile, enrolls with the relay's
  connection data and a one-use invitation, and resumes an interrupted
  enrollment. It can also join by pairing with another device or restore
  from an identity kit.
- **Conversations.** A chat list with search, unread counts and a sync
  indicator. Conversations have paged history, per-device delivery states,
  offline sending, explicit encrypted attachments and search within the
  conversation.
- **Contacts and trust.** Saved contacts with local names, safety numbers to
  compare, and a notice in the conversation when a contact's devices change.
- **Devices and recovery.** Linking and revoking devices, identity-kit export
  and restore, KeyPackage availability for new groups, and encrypted history
  archives.
- **Look and accessibility.** English and Spanish, light and dark themes, six
  accents, conversation backgrounds and text size. Screen reader labels, text
  at 200 % without overflow and reduced motion.
- **Help.** A diagnostic report with the version, system, profile state and
  recent error codes, never names, messages, keys or paths.

The profile database is encrypted with SQLCipher. Its key is generated in
Rust and kept by the Keychain on macOS or the Keystore on Android, without
synchronization and with no plaintext fallback. Only the appearance settings
live outside the profile, in `appearance.json`. The
[implementation record](../../docs/CLIENT_FOUNDATION.md) describes each change
with its evidence, and the [platform record](../../docs/PLATFORMS.md) says
what was accepted on which device.

On desktop, the primary modifier is ⌘ on macOS and Ctrl elsewhere:

| Shortcut | Action |
|---|---|
| ⌘N | New conversation |
| ⌘K | Search chats |
| ⌘F | Search in the open conversation |
| ⌘, | Settings |
| Alt+↑ / Alt+↓ | Previous or next conversation |
| Enter | Send (Shift+Enter for a new line; phones insert a new line) |
| Esc | Close the search or the conversation |

## Installing versus developing

See the [installation guide](../../docs/INSTALLATION.md)
([español](../../docs/es/INSTALLATION.md)) for availability and the end-user
installation requirements. No app release has been published yet. The
commands below are for developers; the macOS package and the Android APK
install without Flutter or Rust. The macOS development path works without a
paid Apple Developer membership, using the login Keychain. To build the ZIP
and APK, see [client packages](../../docs/CLIENT_RELEASES.md).

## Running it

With the pinned toolchain (Flutter 3.44.1 and Rust 1.98.1, see
[the platform record](../../docs/PLATFORMS.md)):

```bash
flutter pub get
flutter run -d macos            # or -d <android-device>
```

The native library is built by `rust_builder`, which points at the adapter
crate; there is nothing to build by hand. Launcher icons are committed; see
[brand assets](../../assets/brand/README.md) for their sources and the
maintainer-only export command.

## Project layout

```text
lib/
├── main.dart          App, theme, language and text scale
├── l10n/              ARB files (Spanish is the template) and generated code
└── src/
    ├── design/        Tokens, accents, typography, theme, layout, components
    ├── rust/          Generated bindings (do not edit)
    └── *.dart         Screens, controllers and platform adapters
test/                  Widget, unit and golden tests (test/goldens/)
integration_test/      Native tests against the real bridge and key store
```

## Development checks

```bash
flutter analyze
flutter test
flutter gen-l10n        # CI fails if the generated code differs or a string is untranslated
```

Tests run in Spanish (`test/flutter_test_config.dart`); `test/l10n_test.dart`
checks English and that both ARB files have the same keys.
`test/hygiene_test.dart` keeps colours and user-facing text inside the design
system and the ARB files. After a visual change, update the goldens with
`flutter test --update-goldens`. `../../scripts/update_screenshots.sh`
regenerates the screen goldens and copies the documentation screenshots, which
are rendered from invented test data.

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


## Device management acceptance

Source `0.1.0+8` added device management, now under **Settings › Manage
devices**: current/known own devices, partial-inventory warnings and administrator-only revocation with
explicit target confirmation. Offline revocations survive reopening and resume
with sync. Publication, remaining group leaves and undelivered notices have
separate states; no remote erasure or automatic MLS rejoin is promised.

```sh
python3 scripts/test_client_conversations.py --device macos --scenario devices
python3 scripts/test_client_conversations.py --device emulator-5554 --scenario devices
```

Run from the repository root with Flutter (and `adb` for the disposable emulator)
on PATH. The helper creates a private temporary relay, invitations and test
profiles; it exports no identity kit. The scenario checks pairing, offline
revocation through the UI, encrypted reopen, relay refusal of the revoked device,
MLS removal and text with a surviving participant. No private diagnostics are
committed. Use [the platform record](../../docs/PLATFORMS.md) for actual coverage.

## Encrypted history acceptance

Source `0.1.0+9` adds encrypted history export/import, read-only imported records
and explicit copies of available archived attachments. Restore the matching
identity first after device loss. The archive and its key are separate from the
identity kit and its key; importing never restores MLS sessions or resends text.
See [installation steps](../../docs/INSTALLATION.md#save-and-recover-history-available-since-0109).

```sh
python3 scripts/test_client_conversations.py --device macos --scenario archives
python3 scripts/test_client_conversations.py --device emulator-5554 --scenario archives
```

Run from the repository root. This scenario exports only disposable identity
kits/history into memory, deletes its source profile, restores into a new
platform-held key, imports/reopens, verifies attachment bytes and duplicate
handling, and exchanges text in a newly created conversation. It does not test
the native save/open dialogs or export any real user's identity/history.
