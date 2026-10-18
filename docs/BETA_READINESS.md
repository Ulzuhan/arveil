# Beta readiness

[Español](es/BETA_READINESS.md).

Status checked October 18, 2026. Publication and milestone acceptance are separate. [Phase 3b](PHASE3B.md) retains the normative acceptance criteria.

## Published beta 7

[Client beta 7, 0.1.0+28](https://github.com/Ulzuhan/arveil/releases/tag/clients-v0.1.0-beta.7) uses clean source `2c43970f40476803201c831c077f65dffd5da1c8`. Activity notices now come from the user's own relay ([ADR-014](adr/ADR-014-relay-activity-notices.md)): Android keeps a watch-only connection in a foreground service and macOS waits for the relay's notice instead of polling every ten seconds. The ntfy receiver and settings are gone; upgrading from beta 5 or 6 clears the old relay hint and keeps notices on if they were. The release assets and tags remain immutable when source PRs are integrated by squash.

| Channel | Verified state |
|---|---|
| GitHub | Public prerelease, macOS ARM64 ZIP and Android ARM64 APK; uploaded hashes, build metadata and the signed announcement's sizes and hashes verified |
| Google Play | Build 28, internal testing, available to internal testers on October 18; unreviewed, not production distribution |
| Homebrew | Cask `0.1.0-beta.7,28` |
| Signed announcement | Beta sequence 9, expires November 16, 2026; live feed and `/download/android` and `/download/macos` redirects verified |
| Compatible relay | `d2417aaf5243042f32e14005332cc13f80701ef2` (relay schema 7) deployed in the test environment since 2026-10-16; public Noise probe passed. Beta 7 needs schema 7; beta 6 clients also work with it |
| Companion web | Guides and signed downloads at `fad9770`; Lighthouse passed on the Arveil pages |
| ntfy | The self-hosted ntfy server, its proxy, tunnel route and DNS name were retired from the test environment on October 18 |

The direct APK retains its release certificate. The Play AAB uses the established upload key; Google Play signs delivery with its own app-signing certificate. macOS remains ad-hoc signed, without Apple notarization. Update through the same channel without uninstalling or clearing profile data.

| Artifact | SHA-256 |
|---|---|
| macOS ZIP | `247be753a545a8818633a1f23630f45afb31227db9149ea0ad93c51264b89c1d` |
| Android APK | `98317760d3d8f67f7c1c88d3107599bc36515e85c361bf00ba7c0f3e757c48c8` |
| Play AAB | `a9b90e2631ea8e63ad5c6be51ec15151f93335a18792c081d91abf33b5047b0e` |

The Android notice service passed relay-to-emulator acceptance on Android 15/API 35 arm64 against a disposable relay (`scripts/test_android_watch.py`): subscription, persistent notification, generic notice on new mail and stop once the key is refused. Android notices remain experimental until a physical phone passes Doze, battery saver, network changes, reboot and force stop. Packaged Mac banners, taps and sleep/wake are not yet verified.

Beta 6 (0.1.0+27, source `e4011f3`, sequence 8) remains available as an immutable prerelease.

## Compatibility and integration

When beta 6 was published, the public relay/CLI release was [v0.1.0](https://github.com/Ulzuhan/arveil/releases/tag/v0.1.0). Those binaries predate contact credential lookup and personal invitations and must not be paired with beta 6. Use the recorded compatible relay source, or a later tested release whose notes declare compatibility. [#133](https://github.com/Ulzuhan/arveil/issues/133) records subsequent public relay/CLI distribution and package compatibility evidence; updating the private deployment alone does not establish either.

Relay schema 4→5 and profile schema 7→8 require consistent backups and a forward-compatible rollout. The prior-relay restoration drill passed with its matching earlier backup and preserved endpoint sequence. This is not an in-place schema downgrade or a client-profile rollback. Prefer a higher corrective build over replacing an immutable release.

PRs #139 (QR), #141 (files/notifications) and #142 (invitations) carry the beta changes. #138 reconciles their release records. Owner promotion of the intended existing administrator was explicitly performed through the host CLI; no identity or deployment secrets belong in public evidence. Full realm administration in the app (ADR-013) and shared chosen names (ADR-011) remain broader proposals.

## Acceptance still open

| Issue | Remaining exit evidence |
|---|---|
| [#133](https://github.com/Ulzuhan/arveil/issues/133) | Versioned public relay/CLI distribution and complete old/new package compatibility and update evidence |
| [#134](https://github.com/Ulzuhan/arveil/issues/134) | Physical Android and fresh downloaded Mac: installation/update, QR, incoming links, contacts, attachments, recovery and accessibility |
| [#135](https://github.com/Ulzuhan/arveil/issues/135) | Three external people complete the main journey with anonymized A/B/C results |
| [#136](https://github.com/Ulzuhan/arveil/issues/136) | Independent security review and verified resolution of blocking findings before production |
| [#137](https://github.com/Ulzuhan/arveil/issues/137) | Reviewed and implemented live MLS recovery/rejoin; identity/history restore does not restore live sessions |
| [#140](https://github.com/Ulzuhan/arveil/issues/140) | Packaged Mac alerts/taps/sleep-wake; physical Android file opening and complete relay→phone delivery, Doze, process death, network and battery behavior |

All required CI checks passed on the published source ([run](https://github.com/Ulzuhan/arveil/actions/runs/36853095121)). Nine real Go↔Rust scenarios include 22 persistence-failure boundaries, compatible relay backup/restore and a linked issuer. Native Mac and emulated Android cover creation, consent, offline close/reopen/resume and duplex chat. They do not close A01–A18 physical acceptance in the [invitation plan](INVITATION_ONBOARDING_PLAN.md).

The tester reported successful physical Android device linking after build 24; exact hardware/OS and the complete acceptance matrix remain unrecorded. The earlier beta 4 GitHub draft (build 23, sequence 6) was never published and is superseded by betas 5/6; it must not be published later with stale downloads. Windows/Linux and iOS remain M3b.6/M3b.7.

Notification delivery remains experimental and best effort; ordinary synchronization on foreground/reopen is the baseline. Record results against package hashes, OS/device and source revision in [the platform record](PLATFORMS.md). No independent security audit or complete external trial has occurred.
