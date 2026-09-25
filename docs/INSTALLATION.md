# Install and try Arveil

[Español](es/INSTALLATION.md).

**Current availability (September 25, 2026):** there are no published GitHub
releases yet. A [packaging command](CLIENT_RELEASES.md) prepares experimental
macOS ZIP and Android APK candidates. The current source supports invitation enrollment,
pairing and encrypted identity-kit export/restore, verified groups, paginated
history, offline text and sync, saved contacts, attachments, device revocation
and encrypted history export/import. Candidates `0.1.0+10` include these features
and a fix for native save-dialog key handling. The Android emulator retained its
profile across updates and passed native history save/open, repeated import and
restart checks; macOS profile reopening remains pending for this build. See the
[acceptance record](PLATFORMS.md#corrected-package-and-archive-dialog-acceptance-september-25-2026).
The previous `0.1.0+5` candidates passed Mac ↔ Android-emulator messaging.
Earlier experimental packages may contain only invitation enrollment; check
the package revision and release notes. Use disposable test profiles at this stage.

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
and resolve Keychain access before continuing. Do not replace the app with an
older version: newer builds may change the profile in ways an older one cannot
read. Builds after `0.1.0+11` detect a profile from a newer version and refuse
to open it without changing it; earlier builds do not check.

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
reopen. Current source also supports pairing, recovery kits and conversations.

To try conversations with disposable profiles on the same relay using the
current source or a package containing it:

1. Select **Abrir conversaciones**, then **Mi ruta** to share this device's route
   privately with your contact. Each person can obtain their route here.
2. Open **Contactos → Añadir contacto**, paste a route, give it an optional local
   name and choose **Preparar contacto**. Compare the full safety number through
   an independent channel; both people can preview the other's route.
3. Confirm the comparison and **Guardar contacto**, or save it unverified and
   use **Verificar contacto** later. A name never verifies an identity. **Guardar
   nombre** edits the alias locally; an empty name removes it. Import another
   route through **Añadir contacto**; an empty name preserves an existing alias.
4. Open **Nueva conversación → Elegir contactos guardados**. Select verified
   contacts and choose **Usar contactos** to create the group with their saved,
   non-revoked devices (up to 16). Your contact uses **Sincronizar** to receive it.
   The original route-paste and comparison flow remains available.
5. Open the conversation and send text. Offline messages remain saved locally;
   **Sincronizar** retries publication. Relay acceptance does not confirm reading.

Automatic sync runs while the conversation screen is in the foreground. Push,
background receipt and general group membership controls are still pending.
The existing experimental packages may precede these source changes; check their
recorded revision before expecting these screens.

### Attachments (available since `0.1.0+7`)

In a conversation, choose **Adjuntar archivo** (the paperclip), select a file smaller
than 25 MiB, and confirm. The private queued copy survives restart. If offline,
use the file's **Enviar / reanudar** button when connectivity returns; reattaching
would create another message. Incoming files download only when you choose
**Descargar**. Use **Guardar copia…** to choose an external destination explicitly.
That exported copy is outside Arveil's encrypted profile and may be backed up
by its destination. Cancelling an unfinished transfer discards its local data;
it does not recall a sent message. Request another copy if the relay reports
expiry.

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


## Manage your devices (available since `0.1.0+8`)

Open **Gestionar dispositivos** from the profile. Compare the full device ID
with the other device before revoking it. Only the administrator can revoke
another device; the current device cannot revoke itself. A linked profile may
show a partial inventory because it has not learned the other device IDs.

**Sincronizar dispositivos** resumes confirmed revocations after a network
failure or restart. Until the relay accepts the manifest, the device may still
connect; conversations also need to remove its MLS membership. The screen
reports those stages separately. Revocation does not erase copies/history or
prove that other participants received the notice. See the
[implementation and limits](CLIENT_FOUNDATION.md#own-devices-and-resumable-revocation-third-m3b4-slice).

Update the relay from the same source revision when trying this feature. Older
relays return 409 on repeated manifest publication; this relay accepts an
identical retry and commits revocation with the manifest atomically.

## Save and recover history (available since `0.1.0+9`)

1. In the profile, open **Historial cifrado**, acknowledge that this copy can
   reveal past messages and select **Guardar historial cifrado**. If the native
   dialog returns before the app regains focus, select **Mostrar clave del archivo
   guardado** after returning (fixed in `0.1.0+10`). Save its key separately,
   for example in a password manager. The key disappears when you
   leave or switch apps; export again if you lose it. Review the count of files
   without a copy: pending downloads and legacy CLI files are not fetched.
2. After losing a device, first restore the same identity with its latest kit
   and that kit's separate key. A history archive cannot recover your identity.
3. Open **Historial cifrado**, choose the encrypted history file, enter its own
   key and select **Importar como historial**. Existing records stay unchanged.
   Imported attachments stay encrypted in the profile until **Guardar copia del
   adjunto**; the chosen destination may keep or back up that readable copy.
4. Read the imported history on this separate screen. Importing neither resends
   messages nor rejoins old groups. Exchange the recovered device's route with a
   contact and explicitly start a new conversation for new messages.

These steps are included in the `0.1.0+10` candidates. Files are limited to
64 MiB and 10,000 records; see
[implementation limits](CLIENT_FOUNDATION.md#encrypted-history-and-loss-recovery-fourth-m3b4-slice).

When saving an identity kit, the equivalent action is **Mostrar clave del kit
guardado**. A save completed in the background requires this explicit reveal
after returning. Once back in the app, switching away again discards the pending
key as well; export another copy if needed. Neither key is stored by Arveil.
