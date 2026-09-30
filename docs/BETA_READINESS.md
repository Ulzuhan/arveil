# Beta readiness

[Español](es/BETA_READINESS.md).

Status checked on September 30, 2026. This is the current release and acceptance
record; [Phase 3b](PHASE3B.md) retains the milestone criteria. Publishing an
experimental package does not close a milestone or establish production readiness.

## Available and prepared

| Delivery | Source | State |
|---|---|---|
| [Relay/CLI v0.1.0](https://github.com/Ulzuhan/arveil/releases/tag/v0.1.0) | `dc03eef` | Public binaries and checksums |
| [Client beta 3, 0.1.0+21](https://github.com/Ulzuhan/arveil/releases/tag/clients-v0.1.0-beta.3) | `9489ce6` | Public macOS ARM64 ZIP, Android ARM64 APK and signed update announcement |
| Candidate client beta 4, 0.1.0+23 | `cf7073823c4695c6246684061fedf47773107613` | GitHub draft with ZIP, APK and signed update announcement (sequence 6); uploaded hashes verified; not a public release |
| Google Play beta 4, versionCode 25 | `edbf30a0bd3798f9e5a97a1cde44946b6710ab71` | Replaced versionCode 24 in internal testing on September 30; Play Console confirms availability to internal testers, with status unreviewed |
| Local macOS beta 4, 0.1.0+25 | `edbf30a0bd3798f9e5a97a1cde44946b6710ab71` | Installed over build 24 with a verified encrypted-data backup; existing profile reopened and synced; rendered contact QR decoded locally and verified to carry the public WSS route |
| Companion relay release | `cf7073823c4695c6246684061fedf47773107613` | Source candidate; release build/publication and deployment acceptance remain open |

The client candidate adds QR codes, links, contact cards and requests
([ADR-012](adr/ADR-012-qr-codes-and-links.md)), the About screen and an AAB
packaging path. The AAB is a separate store artifact with an upload certificate
and no in-app updater. Building it does not establish approval, tester access
or availability on Google Play.

## Compatibility and rollout order

Beta 3 works with relay v0.1.0. The newer client calls `CredentialGet`, introduced
in `d26b5c5`, to check a contact route against its root-signed device credential.
Relay v0.1.0 has no such frame. The client refuses an unsupported server instead
of skipping verification. Test the complete next release pair at the selected
commit, not only that minimum frame introduction.

1. Build the companion relay/CLI and images from the selected tested commit;
   record version, commit, hashes and build provenance.
2. Back up the realm, upgrade its relay and verify health and an older client's
   enrollment, messaging and reconnect. Record the backup/rollback procedure.
3. Verify the candidate client against that relay: join, link/decline, contact
   requests, messaging, attachments, offline/reconnect and retained profile on
   update from beta 3. Confirm the old relay is refused clearly.
4. Review the signed client announcement and notes, then verify that
   beta 3 sees the update. Publish the compatible relay before announcing the
   dependent client, then verify downloads/feed and the supported update paths.
5. Record Google Play separately, including its track, versionCode, review state
   and tester eligibility. Do not assume sideload and Play builds can replace
   each other: compare their app-signing certificates first.

The existing client candidate was prepared with the release helper:

```sh
python3 scripts/release_clients.py prepare \
  --tag clients-v0.1.0-beta.4 --build 23 \
  --revision cf7073823c4695c6246684061fedf47773107613
```

`prepare` does not publish. The update announcement was signed and verified
on September 30 (sequence 6). All six draft assets match the local SHA-256
hashes. Release notes state the relay dependency and remaining acceptance.
The relay workflows require the repository's `release` environment approval;
a draft or local package is not evidence that those builds have run.

## Tracked work

| Work | Exit evidence |
|---|---|
| [Coordinated beta/relay release #133](https://github.com/Ulzuhan/arveil/issues/133) | Compatible version pair, upgrade evidence, signed announcement and verified distribution |
| [Physical Android and clean macOS acceptance #134](https://github.com/Ulzuhan/arveil/issues/134) | Device/OS and exact package hashes; camera, links, lifecycle, key storage and accessibility results |
| [Three-person external trial #135](https://github.com/Ulzuhan/arveil/issues/135) | Anonymized A/B/C results, kit restore before retaining an identity, blockers fixed and rechecked |
| [External security review #136](https://github.com/Ulzuhan/arveil/issues/136) | Scope and immutable commit, blocking findings fixed/verified, residual risks recorded before production |
| [Live MLS recovery #137](https://github.com/Ulzuhan/arveil/issues/137) | Reviewed recovery/rejoin design and verified behavior, without restoring old sending state |

[Shared chosen names (ADR-011)](adr/ADR-011-shared-display-names.md) and
[realm administration in the app (ADR-013)](adr/ADR-013-realm-administration-from-the-app.md)
remain proposals. Windows/Linux and iOS remain M3b.6/M3b.7.

## Evidence and limits

On September 30, the tester reported successful QR scanning/device linking from
the existing Mac identity to a physical Android phone after the build 24 update.
This is a user-reported result; the exact phone model/OS and a complete hardware
acceptance run remain unrecorded. All 16 CI jobs passed for `eae5ff7`.

A follow-up review found that contact QR/shared links and reopened server details
still copied the original enrollment URL. The correction and regression tests
in [PR #139](https://github.com/Ulzuhan/arveil/pull/139) are now packaged in build 25.
The signed AAB retains build 24's upload certificate; both build 25 packages have
verified checksums and clean source metadata. Local validation passed 158 Rust
tests, 284 Flutter tests, Flutter analysis and native pairing/recovery acceptance.
The next acceptance step is contact exchange,
messages, attachments and offline/reopen behavior on the physical phone, followed
by an isolated kit restore and the three-person trial.

On `cf70738`, [CI](https://github.com/Ulzuhan/arveil/actions/runs/36316913022)
completed all 15 jobs, including native bridge builds and phase acceptance.
The local September 29 review passed Go tests, 169 Rust tests (one ignored
vector-dump helper), 280 Flutter tests and Flutter analysis. The September 30
package audit checked the candidate files without rebuilding or changing them.

These checks do not establish complete physical Android acceptance, clean downloaded macOS,
VoiceOver, physical-device TalkBack, Doze, or the three-person external trial.
Record each acceptance result against a package hash, OS/device and source
commit in [the platform record](PLATFORMS.md). Keep live endpoints, invitations,
recovery material and participant details out of public evidence.

The beta promises foreground/on-reopen sync only. Identity kits recover identity;
history archives recover read-only history. Neither restores live MLS sessions.
There has been no independent security review.
