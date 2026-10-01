# Beta readiness

[Español](es/BETA_READINESS.md).

Status checked October 1, 2026. Publication and milestone acceptance are separate. [Phase 3b](PHASE3B.md) retains the normative acceptance criteria.

## Published beta 6

[Client beta 6, 0.1.0+27](https://github.com/Ulzuhan/arveil/releases/tag/clients-v0.1.0-beta.6) uses clean source `e4011f3f2781aa48888d7da35114aa475d6ff71e`. The release assets and tags remain immutable when source PRs are integrated by squash.

| Channel | Verified state |
|---|---|
| GitHub | Public prerelease, macOS ARM64 ZIP and Android ARM64 APK; uploaded hashes and build metadata verified |
| Google Play | Build 27, internal testing, available to internal testers on October 1; unreviewed, not production distribution |
| Homebrew | Cask `0.1.0-beta.6,27`; style and actual download/checksum passed |
| Signed announcement | Beta sequence 8; signature, live feed and download redirects verified |
| Compatible relay | `e4011f3f2781aa48888d7da35114aa475d6ff71e` deployed in the test environment; consistent backup, unchanged realm identity, active services and public Noise probe passed |
| Companion web | PR [#3](https://github.com/Ulzuhan/kaicorplabs-web/pull/3) merged and deployed; guides and signed downloads at `8cc3d8b`; both languages pass Lighthouse |

The direct APK retains its release certificate. The Play AAB uses the established upload key; Google Play signs delivery with its own app-signing certificate. macOS remains ad-hoc signed, without Apple notarization. Update through the same channel without uninstalling or clearing profile data.

| Artifact | SHA-256 |
|---|---|
| macOS ZIP | `b4eaa65d56e3d149d5a8dcec85ac5695cfa1670e4ceffd3d5966bf2b065b4fe4` |
| Android APK | `effaa5a496fd817b4338a24b627e184f4375b80c75a988c070378332a2e0864f` |
| Play AAB | `d0d90c2d5250e867db41952d385a1f96c529bdf724340d357369b7ff1e6d3ac3` |

The Android APK installed successfully in the disposable Android 15/API 35 arm64 emulator. The extracted Mac package opened and reported build 27. These package checks do not replace a fresh physical-phone or fresh downloaded Mac trial.

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
