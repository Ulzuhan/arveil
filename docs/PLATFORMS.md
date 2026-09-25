# Platform matrix

What is pinned, what was built, and what was actually run. [Versión española](es/PLATFORMS.md).

A platform counts as **tested** only where the acceptance flow ran on that system. Compiling for a target proves the toolchain, not the product; distribution is a separate claim that nothing here makes yet.

## Pinned toolchain

| Component | Version | Where it is pinned |
|---|---|---|
| Rust toolchain | 1.98.1 | `core/rust-toolchain.toml` |
| Flutter SDK | 3.44.1 (stable channel) | this document, until CI pins it |
| Dart | 3.12.1 | bundled with the Flutter SDK |
| flutter_rust_bridge | 2.13.0 (runtime and generator) | `core/crates/arveil-flutter/Cargo.toml` (`=2.13.0`) |
| Android NDK | 28.2.13676358, minimum API 24 | Android SDK installation |
| Android SDK | compile SDK 37, minimum API 24 | Android SDK installation |
| Xcode | 27.0 | host installation; macOS deployment target 12.0 |
| `openssl-src` | 300.6.1+3.6.3 | `core/Cargo.lock` |
| `libsqlite3-sys` | 0.38.2 (`bundled-sqlcipher-vendored-openssl`) | `core/Cargo.lock` |

## Matrix

| Platform | Rust target | Built | Tested | Distributed |
|---|---|---|---|---|
| macOS (Apple silicon) | `aarch64-apple-darwin` | yes | yes — acceptance run on the host | no |
| Android | `aarch64-linux-android`, `x86_64-linux-android` | yes — application and bridge | emulator only — Android 15 (API 35), arm64; no physical device yet | no |
| iOS | `aarch64-apple-ios` | core and application layer only | no | no |
| Linux | — | no | no | no |
| Windows | — | no | no | no |

SQLCipher and its vendored OpenSSL cross-compile for Android without the fallback ADR-009 kept in reserve: the built objects are `elf64-littleaarch64` for both `libcrypto` and `sqlite3`.

## Protecting a profile, and what recovers what

Three things are deliberately kept apart, because conflating them is how a
promise becomes false:

| | Protects | Recovers |
|---|---|---|
| **Profile key** | the local database at rest | nothing. Losing it loses local history, and that is accepted on purpose |
| **Identity kit** | the identity's root, exported by the user | the identity. Not conversations, not MLS group state |
| **History export** | an explicit encrypted archive the user asks for | conversations, imported into a **new** profile under a **new** local key. A later milestone; nothing here depends on it |

The profile key is 32 random bytes from the operating system's generator,
made in Rust with the same call the rest of the client uses, and handed to
the platform store. It is never derived from anything a person types and
is not synchronized by Arveil. The future history export will use its own
key. On macOS, a manual backup/migration of the classic login Keychain is
outside the application’s control; do not claim that this backend is device-bound.

Backups are refused rather than trusted:

- **Android** — `android:allowBackup="false"`, `fullBackupContent="false"`
  and a `data-extraction-rules` file that excludes every domain from both
  cloud backup and device transfer. A transfer is as much a copy as a
  backup. The stored key is not carried into a backup either.
- **Apple** — the profile directory is marked `isExcludedFromBackup` on
  every start, since an attribute set once does not survive a directory
  being replaced. iOS uses the device-bound Data Protection Keychain. macOS
  uses the classic login Keychain with app access control; neither backend
  requests synchronization. [Apple TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)
  describes the different protection models.

Exclusion is not encryption and does not replace it. It keeps an encrypted
database out of an account whose protection this project does not control.

### Where the key store stands

| Situation | How it is checked | State |
|---|---|---|
| First install: no key, no profile | `integration_test/profile_key_test.dart` | verified on the Android emulator |
| Second start: the key comes back | same test | verified on the Android emulator |
| Key gone, profile present | same test | verified: reported, never replaced silently |
| A different key on an existing profile | same test | verified: refused at open |
| Reinstall | manual: uninstall, install, start | **not done.** An uninstall does not necessarily take secure-store entries with it, and the two platforms differ; this must be observed, not assumed |
| Restore from cloud backup or device transfer | manual, on hardware | **not done** |
| macOS login Keychain | `profile_key_test.dart` with `ARVEIL_REQUIRE_SECURE_STORAGE=true`, ad-hoc build | verified on the local Apple silicon Mac: write/read, encrypted reopen, missing/wrong-key rejection; package upgrade verified below, fresh download still pending |

## Reproducing it

The Rust workspace, on the host:

```bash
cargo fmt --all --manifest-path core/Cargo.toml -- --check
cargo clippy --manifest-path core/Cargo.toml --workspace --all-targets --locked -- -D warnings
cargo test --manifest-path core/Cargo.toml --workspace --locked
```

Cross-compiling the application layer for Android, with the NDK toolchain named explicitly:

```bash
NDK=$HOME/Library/Android/sdk/ndk/28.2.13676358
BIN=$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin
ANDROID_NDK_ROOT=$NDK PATH="$BIN:$PATH" \
  CC_aarch64_linux_android=$BIN/aarch64-linux-android24-clang \
  AR_aarch64_linux_android=$BIN/llvm-ar \
  CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER=$BIN/aarch64-linux-android24-clang \
  cargo build --manifest-path core/Cargo.toml -p arveil-app --target aarch64-linux-android --locked
```

Regenerating the bindings, from `core/crates/arveil-flutter`:

```bash
flutter_rust_bridge_codegen generate
```

The client, from `clients/flutter`:

```bash
flutter analyze
flutter test integration_test/profile_test.dart -d macos
flutter build apk --debug --target-platform android-arm64
```

## What the acceptance run covers

`integration_test/profile_test.dart` runs on the device itself: a profile opens with an explicit 64-hexadecimal-character key, the conversation query answers with an empty list and a malformed history identifier returns a typed `Domain` error, a second independent open is refused with `AlreadyOpen`, a malformed key is refused with `BadKey` before anything is created, and after `close` the same directory opens again while a wrong key fails at open with `Unusable`.

Record every run against a commit, an operating system and a device. A run on an emulator is written down as an emulator run: it exercises the same binaries, not the same hardware, and M3b.5 still owes a physical device.

## Invitation UI acceptance (September 15, 2026)

The invitation-enrollment changes are recorded in the commit accompanying
this document. `integration_test/onboarding_test.dart` passed on an Android
15/API 35 arm64 emulator against an ARM64 Podman staging relay. It exercises
the form, real platform key storage, native Rust/SQLCipher, unreachable
endpoint, close/reopen, same-identity retry and completed-profile reopen.
This does not cover a physical phone, an OS restart, app reinstall or cloud
restore. Pairing and recovery-kit were outside that acceptance run. Reproduction and
private fixture handling are in the [Flutter README](https://github.com/Ulzuhan/arveil/blob/main/clients/flutter/README.md).

## Experimental package acceptance (September 15, 2026)

Client packages `0.1.0+2` were built from clean commit
`a1d954c7a13ae9a2f189ba19e49d2f52e8fd5b19`. Each includes revision metadata and
checksums; ZIP/APK signatures, architecture and decompressed-content privacy
checks passed. The macOS ZIP is ad-hoc signed, with no Developer ID/notarization.
The Android APK uses a persistent private release key.

- macOS Apple silicon, Xcode 27: native login-Keychain acceptance passed with
  unavailable storage treated as failure. The packaged app opened its encrypted
  profile, reopened it after quitting, and opened the same profile after replacing
  build 1 with build 2 at the same location. Keychain may request authorization
  for a rebuilt app. A fresh download on another Mac is still unverified.
- Android 15/API 35 ARM64 emulator: the release APK installed and cold-started.
  The separate native upgrade harness creates a test identity with a platform
  key and verifies that identity after APK replacement; it never reads or
  replaces the normal app profile. Both create/reopen signals passed across
  build 1 → production APK 2 → verifier 2, without uninstalling or clearing data.
  Physical-phone acceptance is still pending.

These are local experimental results, not beta acceptance or a production
security review. The [packaging guide](CLIENT_RELEASES.md) explains reproduction
and the [installation guide](INSTALLATION.md) explains end-user installation.

## Pairing and recovery acceptance (September 23, 2026)

`integration_test/pairing_recovery_test.dart` passed natively on Apple silicon
macOS with Xcode 27 and the classic login Keychain, and on a disposable
Android 15/API 35 ARM64 emulator with Keystore, against a disposable local
relay. Three encrypted profiles exercise enrollment, pairing, wrong comparison,
reopen before confirmation, encrypted kit export, wrong recovery key, restore,
repeat, reopen and empty recovered conversation history. The current source
is client `0.1.0+3`; this run does not rebuild or publish the `0.1.0+2` alpha.

The 16 widget/unit tests cover presentation using a file-dialog substitute.
Native save/open/cancel dialog interaction, cross-device Mac–Android pairing,
a physical phone and a fresh downloaded installation remain outside this run.

## KeyPackage GUI acceptance (September 23, 2026)

The `0.1.0+4` source accompanying this record passed
`integration_test/key_packages_test.dart` on Apple silicon macOS with Xcode 27
and the login Keychain, and on a disposable Android 15/API 35 ARM64 emulator
with Keystore, against a disposable local relay. The real GUI checks
exhaustion, replenishes and reopens the persisted count and timestamp. The
fixture marks the initial five packages consumed in its own relay database;
the final inventory is 15 total, five consumed, ten available. Phase 4
separately verifies actual MLS group consumption and CLI replenishment.
The [Flutter README](https://github.com/Ulzuhan/arveil/blob/main/clients/flutter/README.md)
provides a self-contained helper. Neither this run nor widget tests cover
physical hardware, cross-device pairing or native file-dialog interaction.

## Conversation GUI acceptance (September 23, 2026)

The `0.1.0+5` source accompanying this record passed
`integration_test/conversations_test.dart` natively on Apple silicon macOS
with Xcode 27 and the login Keychain, and on a disposable Android 15/API 35
ARM64 emulator with Keystore. The isolated helper creates two encrypted
profiles and drives verified group creation, duplex text, relay shutdown,
offline acceptance, profile reopen, pagination and reconnect with 55 events
and no duplicates. It also checks cancellation before watcher dispatch.

The peer runs through the native bridge inside the test app. Text input is
injected by Flutter's test framework. This is not Mac–Android cross-device,
physical-phone, native keyboard/IME or clean-download acceptance. The earlier
`0.1.0+2` experimental packages are unchanged. Reproduce with the
[Flutter README](https://github.com/Ulzuhan/arveil/blob/main/clients/flutter/README.md).

## Cross-platform package acceptance (September 24, 2026)

Normal release packages `0.1.0+5`, built from clean commit
`4d4362b5f27d3782d992254fc494cd9967f37417`, passed a conversation test between
two separate apps: macOS 26.6.2 on Apple silicon (Xcode 27.0, build 27A266a)
and an Android 15/API 35 ARM64 emulator (Pixel 7 device definition).
Both used an ARM64 Podman staging relay over a private network. This run used
the packaged `lib/main.dart` applications, not integration-test entry points.

| Package | SHA-256 |
|---|---|
| `arveil-0.1.0-5-macos-arm64.zip` | `5ac26a37b64c82c7d2a58427739de4e4a5056bf29b9215babd984a5a36997ae9` |
| `arveil-0.1.0-5-android-arm64.apk` | `c275634f32f91d7fa25c35603ca52493d232149c1de0aaafb43ec2f3f9bc17e3` |

The packages retain ad-hoc macOS signing (no Developer ID/notarization) and
the persistent Android release certificate used for build 2. Both revision
metadata files report `dirty_source: false`. Signature, architecture, checksum
and decompressed-content privacy checks passed. These candidates are not a
published release; the previous `0.1.0+2` packages are unchanged.

### Procedure and observed results

Use disposable test identities and a reachable relay. Keep invitations,
connection data, contact routes and raw UI diagnostics private.

1. Enroll a separate identity through each build 2 app's invitation form.
   Replace the Mac app at the same location and install APK 5 over APK 2,
   without uninstalling or clearing data. Both apps reopened their enrolled
   profiles after the upgrade. macOS requested login-Keychain access for the
   updated app; the user authorized it locally. A later restart required no
   additional prompt.
2. Exchange contact routes through the GUI. Compare both displayed safety
   numbers before confirming, then create one conversation on the Mac.
   The numbers matched and both apps opened the same conversation.
3. Send one text from each app. Both appeared on the peer. Enable airplane
   mode and disable Wi-Fi/mobile data only on the emulator. Send another
   Android text: it remained in local history with synchronization pending.
   Send another Mac text while Android is offline.
4. Stop and reopen the Android process while it is still offline. Its profile,
   earlier history and pending outgoing text survived; the new Mac text had
   not arrived. Restore connectivity and synchronize. Both apps then showed
   exactly four messages. Two further completed Android syncs created no
   duplicates and left no pending banner.
5. Quit and reopen the Mac app. The profile and all four messages remained
   accessible. Native Mac keyboard entry/paste worked. Tapping the Android
   on-screen keyboard entered and deleted a draft without sending it.

This verifies separate-app Mac ↔ Android-emulator messaging, profile retention
across upgrade, offline persistence and reconnect delivery. It does not verify
a physical phone, cross-device pairing, OS reboot/Doze, broad keyboard/IME
coverage, native kit save/open/cancel dialogs, or Gatekeeper on a fresh
download on another Mac. Those checks remain open; this is not beta acceptance
or an external security review.

## Saved-contact acceptance (September 24, 2026)

Client source `0.1.0+6` passed the native conversation integration test on:

| Platform | Source commit | Runner |
|---|---|---|
| macOS 26.6.2 Apple silicon, Xcode 27.0, login Keychain | `b176ab4f55a90f8e3b6e273081f8244bb945afd6` | `flutter test` |
| Android 15/API 35 ARM64 emulator, Keystore | `77206b85b4c24ff3b6abb7a652d28cba1388c23f` | `flutter drive --no-dds` |

The Android follow-up changes the host test runner and its documentation;
the client implementation and test scenario are unchanged. The isolated
helper creates a disposable local relay and two encrypted profiles. It
checks saving an unverified contact, explicit safety
number verification, encrypted profile reopen, conversation creation from
a saved contact without pasting its route again, and renaming the contact
with the updated alias shown in the conversation. Duplex text, offline
queue persistence, pagination across 55 events and reconnection without
duplicates also passed on both platforms.

The peer runs through the native bridge inside the same integration app;
Flutter injects text through its test channel. This record covers source
acceptance, not separate-app release-package, native keyboard/IME,
physical-phone or fresh-download acceptance for build 6. The existing
`0.1.0+5` package candidates and release draft are unchanged. Native kit
file-dialog acceptance remains open. Reproduction commands and local
Android test-tool workarounds are in the
[Flutter README](https://github.com/Ulzuhan/arveil/blob/main/clients/flutter/README.md).


## Attachment GUI acceptance (September 25, 2026)

Source client `0.1.0+7` passed these native checks:

| Platform and scenario | Client implementation revision |
|---|---|
| macOS 26.6.2 Apple silicon, Xcode 27.0, login Keychain: attachment transfers | `234406740fac64852d7583f77530305638987100` |
| Android 15/API 35 ARM64 emulator, Keystore: attachment transfers | `b943594b222c09a5c495b5c6c8fac3ab0f5303f7` |
| Same Android emulator: real attachment open/save dialogs | `6771842c387854f06abbebf5fe443e81c2403911` |

The transfer scenario uses two encrypted profiles, native Rust/SQLCipher and
an isolated local relay. It verifies confirmation, offline queueing, encrypted
reopen, upload resume without another event, opt-in download, verified export,
two files with the same name, cancellation and repeated sync without duplicates.
Selectors in that scenario are in-memory substitutes; it writes no plaintext
attachment download. The Android harness waits for transfer completion instead
of assuming that a settled frame means native I/O has finished.

The separate interactive Android test uses the real OS dialogs and a synthetic
37-byte document, without any profile, relay or identity kit. Selection,
cancel-open, cancel-save and explicit save passed. The exported file matched
the source bytes exactly, and no `file_picker` plaintext cache was created.
The two disposable documents were removed afterwards. Android reads the source
URI directly with a bounded stream; three JVM regressions cover empty/exact-limit
input, oversized unknown-length input and cancellation before reading.

All 43 Flutter tests and 99 Rust tests passed (one Rust test remains ignored),
as did static analysis and privacy checks. Reproduction commands are in the
[Flutter README](https://github.com/Ulzuhan/arveil/blob/main/clients/flutter/README.md).
This is source acceptance: macOS native attachment dialogs, physical Android,
fresh-download acceptance and attachments between separate release apps remain
unverified. The `0.1.0+5` candidate packages and release draft are unchanged.
