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
and encrypted identity-kit export/restore are implemented. Conversation
screens and GUI KeyPackage exhaustion remain pending in the
[phase 3b plan](../../docs/PHASE3B.md). The conversation
button currently queries only the local count. The classic macOS login
Keychain works with ad-hoc signing; physical Android and fresh downloaded
macOS acceptance remain open.

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
