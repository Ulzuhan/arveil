# Install and try Arveil

[Español](es/INSTALLATION.md).

**Current availability (September 15, 2026):** there are no published GitHub
releases yet. A [packaging command](CLIENT_RELEASES.md) prepares experimental
macOS ZIP and Android APK candidates. The GUI supports invitation enrollment
and is still missing pairing, recovery-kit and messaging screens. Use disposable
test profiles at this stage.

## Choose your starting point

| I want to… | Available path | What remains before a downloadable release |
|---|---|---|
| Run a relay | Build with Docker Compose, or use the rootless Podman staging helper | Versioned Linux x86-64/ARM64 container images and a tested installation/update guide |
| Try the macOS app | Experimental ZIP from a maintainer, or build from source | Public release and acceptance of a fresh downloaded installation |
| Try the Android app | Experimental APK from a maintainer, or build from source | Public release and physical-phone installation/update acceptance |
| Use an iPhone | Separate, later platform milestone | Native acceptance and a supported signing/distribution route |

## Relay: first local start with Docker Compose

Prerequisites: Git, Docker and the Docker Compose plugin. Run from the
repository root after cloning:

```sh
git clone https://github.com/Ulzuhan/arveil.git
cd arveil
docker compose -f relay/compose.yaml up -d --build
docker compose -f relay/compose.yaml ps
docker compose -f relay/compose.yaml exec arveil-relay /arveil-relay healthcheck -admin http://127.0.0.1:9090
```

A working relay answers `ok` to the health check. Get its connection data and
create a one-use invitation for a test profile:

```sh
docker compose -f relay/compose.yaml logs --no-log-prefix arveil-relay
docker compose -f relay/compose.yaml exec arveil-relay /arveil-relay invite -data-dir /data
```

The `bootstrap:` line identifies the relay. Give it and the invitation to the
intended client privately. The app's enrollment form asks for both.

**This default is local-only.** The published port and advertised address use
loopback. On a phone, `127.0.0.1` means the phone itself. Before testing from
another device, configure a reachable endpoint using [Running a realm](OPERATIONS.md).
The private-network route with authenticated SSH, Tailscale and persistent
rootless Podman is described step by step in [Podman staging](PODMAN.md).
All participating devices must be able to reach the chosen network.

Stop the local relay with `docker compose -f relay/compose.yaml stop`; start
it again with `up -d`. Its named volume holds persistent data. Follow the
[backup](OPERATIONS.md#backups) and [upgrade](OPERATIONS.md#upgrading) instructions
before replacing a version. Backups contain private realm keys.

## Install an experimental app package

Client releases use tags named `clients-v…` and include `BUILD-macos.json`,
`BUILD-android.json` and `SHA256SUMS-clients.txt`. A single-platform local
candidate instead includes `BUILD.json` and `SHA256SUMS.txt`.
Public downloads will be listed on
[GitHub Releases](https://github.com/Ulzuhan/arveil/releases) when published.
Installing these packages does not require Flutter, Rust, Xcode or Android Studio.

### macOS: Apple silicon, macOS 12 or newer

1. Open the `macos-arm64.zip` archive and drag `arveil.app` to Applications.
2. Open Arveil. This experimental build has an ad-hoc signature and is **not
   notarized by Apple**. If macOS blocks a trusted download, use the per-app
   **Open Anyway** option in System Settings → Privacy & Security, following
   [Apple's instructions](https://support.apple.com/guide/mac-help/mh40616/mac).
3. Select **Abrir perfil**. macOS stores its key in the login Keychain. If it
   asks, authorize this app's access; a rebuilt app may ask again. A locked or
   denied Keychain is reported by the app, with no plaintext fallback.
4. Paste the relay connection data and one-use invitation, then complete enrollment.

**Update:** quit Arveil, replace the app in Applications with the newer version,
and reopen it. Keep the existing profile and Keychain entry. Do not use an app
cleaner to remove its data. If the key cannot be accessed, preserve the profile
and resolve Keychain access before continuing.

The classic login Keychain does not provide the same device-binding protection
as the iOS Data Protection Keychain. It is not synchronized by Arveil, but
manual Keychain backups/migration are outside the app's control. Existing
profiles made with the former Data Protection backend are not automatically
migrated. See [platform behavior and acceptance](PLATFORMS.md).

### Android: ARM64, Android 7.0 / API 24 or newer

1. Download the `android-arm64.apk` file on the phone and open it.
2. If prompted, permit **Install unknown apps** for the browser or file manager
   used to open this APK. Install Arveil; you can turn that permission off afterward.
3. Open Arveil, select **Abrir perfil**, and enter the relay data and invitation.
   A private relay requires the phone to be connected to its network.

**Update:** open the newer APK and choose the update/install option over the
existing app. It must use the same signing certificate and a higher build number.
**Do not uninstall or clear app storage to update:** that deletes the local
profile/key. An APK signed with another key (including a developer's debug
build) cannot update this installation. Preserve the current installation if
Android reports a conflict. Check `BUILD.json` for version and certificate details.

### First use and limits

The current interface is in Spanish. A completed enrollment shows the profile
summary. On a connection failure, close/reopen and retry with the **same relay
and invitation**; successful enrollment does not need another invitation on
reopen. Pairing, recovery-kit and conversation screens are still pending.

## Build from source

The [Flutter README](https://github.com/Ulzuhan/arveil/blob/main/clients/flutter/README.md)
and [platform matrix](PLATFORMS.md) describe the native build and its tested
scope. Building currently requires Flutter, Rust and the platform SDKs;
downloadable app packages must remove that requirement for end users.

- **macOS:** from `clients/flutter`, run `flutter pub get` and
  `flutter run -d macos`. A local build does not require a paid Apple account
  to launch and open a profile: it uses the classic login Keychain described
  above. Xcode must have its license accepted to compile.
- **Android:** enable USB debugging for development, connect and authorize the
  phone, then run `flutter devices` and `flutter run` from `clients/flutter`.
  Install the platform SDK/NDK required by the project first. Select the Android
  device if Flutter asks. Emulator acceptance has passed; physical-device
  acceptance remains pending. This development route is not the planned
  download-and-install APK experience.
- **iOS:** a runnable Flutter source tree is not an accepted iPhone release.
  Follow the separate milestone in the [client plan](PHASE3B.md).

Keep invitations, endpoints, signing material and test output out of Git and
public screenshots. The repository provides generic examples, never the
maintainer's machine configuration.

## Installation is part of the deliverable

Every user-facing release must provide an English and Spanish route from the
README to the correct artifact and guide:

1. **Server:** a recommended Docker/Podman path, explicit prerequisites,
   versioned x86-64 and ARM64 images, persistent storage, reachable endpoint,
   invitation, health check, startup after reboot, backup, update and recovery.
2. **macOS:** a packaged app such as a ZIP/DMG, supported systems/architectures,
   documented first launch and signing/notarization status, encrypted profile
   reopening and an update that preserves access. The initial development
   path must work without purchasing Apple Developer membership. Do not claim
   classic Keychain has the same device-binding guarantees as Data Protection
   Keychain; record the behavior actually verified.
3. **Android:** an installable APK, supported Android versions/ABIs, clear
   installation permissions, a stable private release signing key and a tested
   update over the previous version. Debug signing is only for development.
4. **First use:** create/join a test profile from the GUI using the relay data
   and invitation, show understandable errors, and link to recovery guidance.
5. **Verification:** a person starting with a clean machine/phone follows only
   the published guide, installs, enrolls, restarts and updates successfully.
   Record the release, OS, architecture and blockers. Ordinary app installation
   must not require Flutter, Rust, Xcode or Android Studio.

Publish version identifiers, checksums and release notes with those artifacts.
CI must verify what it packages. Private configuration stays outside the
repository. These are delivery requirements, not claims that the packages or
all acceptance runs already exist; see [phase 3b](PHASE3B.md).
