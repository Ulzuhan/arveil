# ADR-010 — Distribution and updates outside the app stores

- **Status:** accepted for Android; remaining platform integration proposed.
- **Implementation:** the Android check/download/PackageInstaller path and offline manifest signer are implemented; see [Signed Android updates](../CLIENT_UPDATES.md) for the exact wire format, tests and limitations. macOS/Sparkle and automatic key rotation remain pending. No public feed or personal relay is configured by committing this code.
- **Date:** 2026-09-26.
- **Scope:** how people who are not developers get the Android and macOS apps and their updates while Arveil is not in Google Play or the App Store; how the app learns that an update exists; what that check reveals. Part of M3b.8 in the [Flutter plan](../PHASE3B.md) ("signed updates").

*Versión en español: [../es/adr/ADR-010-distribution-and-updates.md](../es/adr/ADR-010-distribution-and-updates.md)*

## Context

The first packages are an Android APK and a macOS ZIP, published as `clients-v*` releases on GitHub with `SHA256SUMS-clients.txt` ([client releases](../CLIENT_RELEASES.md)). Neither goes through an app store, at least initially. For a developer that is enough. For the people Arveil is for, it is not: somebody's parent will not browse GitHub releases, compare checksums or remember to check for a new version, and an app that is never updated keeps its bugs and its vulnerabilities.

The project has a public website with an installation guide and, once there is a public release, direct download links. That solves the first installation. It does not solve the second one.

Three constraints shape any answer:

- **Updates are the most attractive attack path on an encrypted messenger.** Whoever can make a device install a modified client reads everything that device reads. The [threat model](../THREAT_MODEL.md#6-open-risks-that-block-strong-claims) already lists "signed updates from a channel independent of the realm" as an open risk.
- **The client does not phone home.** [Client design](../CLIENT_DESIGN.md) principle 6: nothing is downloaded at runtime, no analytics. Asking a server "is there a newer version?" reveals the device's IP address, the time and, unless designed otherwise, the installed version.
- **An update must never cost the profile.** Uninstalling or clearing storage deletes the local identity; installing an older build over a newer profile is refused since `0.1.0+11`. Android only accepts an update signed with the same key and a higher build number.

## Decision

**1. Binaries stay in GitHub Releases.** Every published package lives in its `clients-v*` release, immutable once published (no `--clobber`, as the release guide already requires). The website links to them; it does not host copies. One source of truth, the release's checksums, and no bandwidth or storage on the website's host.

**2. The current version is announced by a signed manifest, not by "latest".** GitHub's `releases/latest` ignores prereleases and cannot tell `v*` (relay and CLI) from `clients-v*`. A small JSON document, `clients.json`, lists for each platform the version, build number, minimum OS, download URL, size and SHA-256, plus a release-notes URL, a monotonically increasing `sequence` and an `expires` date. It is published on the project website and attached to the release.

**3. The manifest is signed with a dedicated update key.** An Ed25519 key used for nothing else: not the Android signing key, not any realm key. It is kept off the web server and off CI, backed up like the Android key, and the signature is made on the maintainer's machine at the same moment a release goes from draft to published. The public key is compiled into the app. A future key can be announced inside a manifest signed by the current one.

**4. The update channel is independent of the realm.** The app never asks the relay about updates and the relay never distributes binaries. A hostile or compromised realm can neither push a client nor hold one back; a compromised website can withhold updates (see `expires`) but cannot make the app accept a binary.

**5. Checking is opt-in and says nothing about the device.** Off by default, with a manual **Check for updates** in Settings and an option to check at most once a day. The request is a plain `GET` of the whole manifest: no version, identifier or cookie; the comparison happens on the device. The threat model states the residue: the website's operator and its CDN see an IP address and a time.

**6. Nothing installs silently.** The app verifies the manifest's signature, rejects a lower `sequence` or an expired manifest, downloads the package, checks its size and SHA-256, and only then offers it, with the release notes. The person confirms; the operating system performs the installation. A package that fails any check is deleted and never offered. A lower build number than the installed one is never offered.

**7. Phased by platform.**

| Platform | Phase | Mechanism |
|---|---|---|
| Android | Older clients | Website download plus the install guide, installed over the existing app once to gain the updater. Optionally [Obtainium](https://github.com/ImranR98/Obtainium) pointed at the GitHub repository with prereleases enabled and an asset filter for the APK; the OS still enforces the signing certificate |
| Android | Implemented | In-app check (decisions 5–6); the verified APK is handed to the system installer through a `PackageInstaller` session, which needs the `REQUEST_INSTALL_PACKAGES` permission and the user's confirmation |
| macOS | M3b.8 | [Sparkle](https://sparkle-project.org/) with an appcast generated from the same manifest and signed with the same update key (Sparkle's EdDSA is Ed25519). Until then: download and replace the app, as the install guide says |
| Windows, Linux | M3b.6 | Decided with those builds; the manifest format already has room for them |
| iOS | M3b.7 | There is no practical distribution outside Apple's (App Store or TestFlight); out of this decision |

## Threats and what each party can do

| Party | Can | Cannot |
|---|---|---|
| The realm operator | Nothing related to updates | Push, block or observe update checks |
| Website operator or its CDN | See IP and time of opt-in checks; withhold the manifest (detected when it expires); serve an old manifest (rejected by `sequence`) | Make the app accept a package: the signature and the hashes are checked on the device |
| GitHub | Withhold or replace a file | Replace it undetected: size and SHA-256 come from the signed manifest |
| Whoever steals the update key | Announce a package of their choosing. On macOS that is enough: with ad-hoc signing and no Developer ID there is no second barrier | Get Android to install it as an update without also holding the Android signing key; the two keys are kept apart for that reason |
| Whoever steals the Android signing key | Build an APK Android would accept as an update | Get the app to offer it without the update key |

## Alternatives

| Alternative | Reason not to adopt it now |
|---|---|
| Google Play and the App Store | Developer accounts, review cycles and a store in the path of every release. Not ruled out later; iOS will probably need it |
| The main F-Droid repository | Requires builds F-Droid can reproduce from source; a Rust + Flutter + SQLCipher toolchain makes that a project of its own. Worth revisiting |
| A self-hosted F-Droid repository | Static, with a signed index and existing clients; reasonable for Android users who already use F-Droid, and compatible with this decision. Not the default: most people do not have F-Droid |
| Obtainium only | No code and it works today, but it trusts whatever GitHub serves beyond the APK certificate, and it is one more app to install. Kept as an option |
| Updates delivered through the realm | The realm is untrusted by design ([ADR-003](ADR-003-zero-trust-server.md)); it must not be able to change the client |
| Serving the binaries from the website | Duplicates GitHub's immutable releases and moves bandwidth and availability onto the website's host |
| Automatic, silent updates | Contradicts consent and the no-phone-home principle, and hides exactly the change a person may want to delay |

## Consequences

A second long-lived secret appears: the update key, with its backup and its rotation. Losing it means publishing a build with a new public key that people install by hand, once.

Publishing a release gains a step: generate `clients.json`, sign it, publish it to the website and attach it to the release. The website's download section is generated from the same manifest, so the page and the app can never disagree about the current version.

The Android updater uses `REQUEST_INSTALL_PACKAGES`, a permission that some stores and device policies restrict; the system-installation test is recorded in the [platform record](../PLATFORMS.md#android-signed-updater-acceptance-2026-09-26). This implementation does not close the other M3b.8 requirements.

Opt-in means most installations will not check for updates on their own. The install guide and the release notes remain the main channel until the check proves itself.

## Acceptance criteria

1. A manifest with an invalid signature, a lower `sequence` than the last one seen, or past its `expires`, is rejected and nothing is offered.
2. A package whose size or SHA-256 differs from the manifest is deleted and not offered.
3. With checking off, a capture shows no request to the website or to GitHub from the app, at start-up or at any time.
4. An opt-in check sends no version, identifier or cookie.
5. With the realm down or hostile, the update check behaves the same.
6. On Android, an update over an existing installation keeps the profile; an APK signed with another key is refused by the system and the app reports it without offering to uninstall.
7. A build lower than the installed one is never offered.

## Open questions

- Whether signing can move to CI without putting the key where CI logs and third-party actions can reach it.
- How long a manifest stays valid (`expires`): long enough not to break phones that are offline for weeks, short enough to notice a withheld update.
- Whether to offer a beta channel for people testing with the maintainer.
