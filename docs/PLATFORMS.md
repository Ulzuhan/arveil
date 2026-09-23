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
| macOS login Keychain | `profile_key_test.dart` with `ARVEIL_REQUIRE_SECURE_STORAGE=true`, ad-hoc build | verified on the local Apple silicon Mac: write/read, encrypted reopen, missing/wrong-key rejection; fresh-download and upgrade acceptance are separate |

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
macOS with Xcode 27 and the classic login Keychain against a disposable local
relay. Three encrypted profiles exercise enrollment, pairing, wrong comparison,
reopen before confirmation, encrypted kit export, wrong recovery key, restore,
repeat, reopen and empty recovered conversation history. The current source
is client `0.1.0+3`; this run does not rebuild or publish the `0.1.0+2` alpha.

The 16 widget/unit tests cover presentation using a file-dialog substitute.
Native save/open/cancel dialog interaction, cross-device Mac–Android pairing,
a physical phone and a fresh downloaded installation remain outside this run.
