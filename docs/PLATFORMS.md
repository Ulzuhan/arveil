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
| Android SDK | 36.1.0 | Android SDK installation |
| Xcode | 26.6 | host installation |
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
never leaves the device. That last part is why the future history export
does not need the profile key: it will carry its own, so recovery never
required weakening this one.

Backups are refused rather than trusted:

- **Android** — `android:allowBackup="false"`, `fullBackupContent="false"`
  and a `data-extraction-rules` file that excludes every domain from both
  cloud backup and device transfer. A transfer is as much a copy as a
  backup. The stored key is not carried into a backup either.
- **Apple** — the profile directory is marked `isExcludedFromBackup` on
  every start, since an attribute set once does not survive a directory
  being replaced. The key is stored device-bound and not synchronisable, so
  it never reaches iCloud Keychain.

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
| macOS Keychain | needs `keychain-access-groups`, which needs development signing | **not available in an unsigned build.** The application says so instead of keeping the key somewhere weaker; signing is a packaging decision for M3b.5 |

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

`integration_test/profile_test.dart` runs on the device itself: a profile opens with an explicit 64-hexadecimal-character key, a query answers with a typed `Domain` failure naming `query-conversations` because a fresh profile has no device yet, a second independent open is refused with `AlreadyOpen`, a malformed key is refused with `BadKey` before anything is created, and after `close` the same directory opens again while a wrong key fails at open with `Unusable`.

Record every run against a commit, an operating system and a device. A run on an emulator is written down as an emulator run: it exercises the same binaries, not the same hardware, and M3b.5 still owes a physical device.
