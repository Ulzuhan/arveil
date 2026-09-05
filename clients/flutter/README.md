# Arveil client

The Flutter client for [Arveil](../../README.md). It calls the Rust
application layer through `core/crates/arveil-flutter`, a thin adapter
generated with flutter_rust_bridge; identity, MLS, delivery and persistence
stay in Rust, and this project holds navigation, presentation and screen
state only ([ADR-009](../../docs/adr/ADR-009-flutter-first.md)).

## What exists today

A profile opens with an explicit key, answers a query and closes. That is
the whole surface: enrollment, pairing, conversation, attachments and
device management belong to later milestones of the
[phase 3b plan](../../docs/PHASE3B.md). The screen is a technical one, not
a design.

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

`integration_test/profile_test.dart` is the M3b.0 acceptance flow, and it
runs on the device rather than in a test harness: explicit key, typed query
failure, refusal of a second session, malformed key, close, reopen, wrong
key. Run it on Android with `-d <device>` once an emulator or a phone is
attached.

## Regenerating the bindings

After changing the Rust API, from `core/crates/arveil-flutter`:

```bash
flutter_rust_bridge_codegen generate
```

Both the Rust and the Dart generated files are committed, so a review sees
what the generator produced.
