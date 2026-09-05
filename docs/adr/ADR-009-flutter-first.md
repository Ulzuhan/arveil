# ADR-009: Flutter first, shared Rust core

Status: accepted implementation direction; GUI not implemented. [Versión española](../es/adr/ADR-009-flutter-first.md).

## Context

The maintainer primarily uses macOS and Android, knows Flutter and values a possible future SwiftUI interface. iOS, Windows and Linux also matter. Starting with two interfaces and bridges would delay product validation.

## Decision

Build Flutter for all five platforms through a thin `flutter_rust_bridge` adapter on `arveil-app`. Prioritize macOS/Android beta, then validate Windows/Linux and iOS separately. Framework compilation support alone does not establish Arveil support.

Keep identity, MLS, delivery, persistence and domain decisions in Rust. Flutter owns navigation, presentation and temporary screen state. Platform integration supplies keys, permissions, notifications and file access through explicit contracts.

Embed Rust as a library; retain the Go relay architecture and responsibility. M3b.2 permits a bounded enrollment-contract/persistence correction so the enrollment sequence—`InviteRedeem` redemption and mailbox creation—is resumable and idempotent under concurrency and lost responses, with authorization, single-consumption and compatibility tests. This does not imply a general protocol redesign. No local HTTP server or GUI/CLI IPC in the initial phase. SwiftUI/UniFFI remains optional future work driven by observed needs, without promising Dart screen reuse. Application/core contracts must remain independent of Dart types.

## Consequences and alternatives

One initial UI and bridge reduce maintenance, but mobile/desktop layouts and signing, distribution, secure storage, background behavior and push still need platform work. Explore versions during the spike; pin Flutter, bridge, native toolchains, targets and minimum OS versions before accepting M3b.0. Mobile SQLCipher compatibility remains unproven until tested.

Push provider and iOS extension architecture are not selected. Decide and verify them before promising background reception.

SwiftUI + Compose + Rust offers platform-specific interfaces but does not use the maintainer's primary UI expertise. SwiftUI + Flutter + Rust remains possible later; defer the second frontend until a working product is validated.

## References and acceptance

- [Flutter platforms](https://docs.flutter.dev/reference/supported-platforms).
- [Flutter Rust Bridge](https://cjycode.com/flutter_rust_bridge/guides/cross-platform/overview).
- [UniFFI](https://mozilla.github.io/uniffi-rs/latest/) as a possible future Apple adapter.
- [Implementation plan and exit criteria](../PHASE3B.md).
