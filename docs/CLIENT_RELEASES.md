# Building experimental client packages

For installation without development tools, see [Install and try](INSTALLATION.md).
This page is for maintainers. Packaging does not publish a GitHub release.

For signed in-app Android updates, pass a private `--update-config` file and
follow [Signed Android updates](CLIENT_UPDATES.md). That guide adds a dedicated
offline manifest key and a signed announcement to the release process; realm
configuration never enters the client package.

## Requirements

Use the pinned [Flutter/Rust toolchain](PLATFORMS.md), Python 3.10 or newer,
and a clean committed checkout. macOS packages require an Apple silicon Mac,
Xcode with its license accepted and CocoaPods. Android packages require Java,
the Android SDK/NDK and build tools (`apksigner` and `aapt2`); set `JAVA_HOME`
and `ANDROID_HOME` for your installation. Put Flutter and Java tools on `PATH`.

The initial package targets are Apple silicon macOS and Android ARM64.
The helper records the minimum OS/SDK in `BUILD.json`. Builds are experimental:
the current GUI supports invitation enrollment, pairing and identity-kit
export/restore, KeyPackage replenishment, conversations with offline text and
sync, saved contacts, attachments, device revocation and encrypted history
export/import. Existing candidates are tied to
their recorded source revision; these changes do not update old binaries.

## Android: create the signing key once

From the repository root:

```sh
python3 scripts/package_clients.py init-android-key
```

This creates `.local/signing/android-release.keystore` and
`.local/signing/android-signing.json`, with private permissions. The directory
is ignored by Git. Passwords are randomly generated and never passed in command
arguments. The certificate contains only project metadata.

Keep an encrypted backup of **both files** outside the checkout before publishing.
Reuse this key for every update; losing it prevents updates to installed APKs.
Do not recreate it per build, commit it, attach it to a release, or share build
logs containing signing configuration. The command refuses to replace an
existing signing directory. See [Android app signing](https://developer.android.com/studio/publish/app-signing).

## Build packages

```sh
python3 scripts/package_clients.py build android \
  --signing-config .local/signing/android-signing.json
python3 scripts/package_clients.py build macos
```

The version and default build number come from `clients/flutter/pubspec.yaml`.
For the next update, increment its build number, or pass `--build-number 3`.
Keep Android build numbers increasing. `--flutter` accepts an explicit Flutter
executable. `--allow-dirty` is only for unpublished local candidates and is
recorded in their metadata. The version and commit also reach the app
(`--dart-define`), which shows them in its diagnostic report; a local build
without the script says "local build".

`apksigner` needs a Java runtime: if the system has none, point `JAVA_HOME` at
Android Studio's JDK (`/Applications/Android
Studio.app/Contents/jbr/Contents/Home`) before building.

Android release builds refuse missing signing configuration. CI can supply
`ARVEIL_ANDROID_KEYSTORE`, `ARVEIL_ANDROID_STORE_PASSWORD`,
`ARVEIL_ANDROID_KEY_ALIAS` and `ARVEIL_ANDROID_KEY_PASSWORD` as private
environment variables instead of the JSON file. Never use a debug or disposable
CI key for a public APK.

The helper copies Git-visible source into an isolated temporary directory,
resolves the committed lockfile, builds `lib/main.dart` in release mode,
remaps native source paths, removes native debug symbols and scans decompressed
package contents for private home paths and test configuration markers. A failed
build or audit produces no output package. This targeted audit supplements the
repository secret scan; it is not an exhaustive malware or secret detector.

Output is under `dist/clients/<version>+<build>/<platform>/`:

- The `.apk` or `.zip` containing `arveil.app`.
- `BUILD.json`: source revision, version, architecture, minimum OS and signing status.
- `SHA256SUMS.txt`: hashes of the package and metadata.

Logs, debug symbols and unverified audit candidates stay under `.local/client-builds/`. Only the three output
files belong in a release. Output directories are never overwritten. macOS
packages have ad-hoc signatures, with no Developer ID or Apple notarization.
Android packages are checked for a valid release certificate, ARM64 support,
network permission and a non-debuggable manifest.

CI exercises both packaging paths. Its Android signing key is disposable and
its test APK is not uploaded. Public APKs must always use the maintained key.

`clients/flutter/integration_test/profile_upgrade_acceptance.dart` is a private
release-mode acceptance entry point for a disposable Android installation.
Build it with `ARVEIL_TEST_UPGRADE=create`, install and launch it, then build
with `ARVEIL_TEST_UPGRADE=reopen` and a higher build number using the same signing
key. Install with `adb install -r` and launch again. Its fixed
`ARVEIL_TEST_UPGRADE_OK:<stage>` signal confirms that native SQLCipher opens
the same stored identity with the retained platform key across processes and
APK replacement. Never publish this test build; rebuild the normal main entry
point with the packaging helper afterward.

## Prepare the GitHub draft

Client releases use **`clients-v<version>`** tags, for example
`clients-v0.1.0-alpha.1`. The `v*` namespace belongs to the CLI/relay workflow;
client tags do not match that trigger, including at older source revisions.
The [GitHub tag filter](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#onpushbranchestagsbranches-ignoretags-ignore)
and the publication script both keep these releases separate.

1. Verify each platform's local `SHA256SUMS.txt` from its output directory with
   `shasum -a 256 --check SHA256SUMS.txt`. Check that both `BUILD.json` files
   report the same committed revision and version/build, with `dirty_source: false`.
2. Copy the tested ZIP and APK to a new, empty staging directory. Copy their
   metadata as `BUILD-macos.json` and `BUILD-android.json`, without changing its
   contents. Keep build logs, signing files and debug symbols outside that directory.
3. In the staging directory, create and verify the combined client manifest:

   ```sh
   shasum -a 256 arveil-*-macos-arm64.zip arveil-*-android-arm64.apk \
     BUILD-macos.json BUILD-android.json > SHA256SUMS-clients.txt
   shasum -a 256 --check SHA256SUMS-clients.txt
   ```

4. Create a **draft prerelease** using the client tag. Set its target to the exact
   source commit recorded in both metadata files, not a moving branch. Attach
   only the two packages, the two metadata files and `SHA256SUMS-clients.txt`.
   Record the scope and acceptance evidence below in its notes. The signed
   update announcement is attached too ([signed updates](CLIENT_UPDATES.md)).
5. Once the release is published, update the
   [Homebrew tap](https://github.com/kaicorplabs/homebrew-tap): in
   `Casks/arveil.rb`, set `version` to the public version and the build
   (`0.1.0-beta.2,20`) and `sha256` to the ZIP's, then run `brew style` and
   `brew fetch --cask arveil` against the published file.

The CLI/relay workflow publishes `SHA256SUMS-cli-relay.txt` with an explicit
binary list and refuses to overwrite existing release assets. A repeated upload
with duplicate names fails; investigate the existing release before retrying.
Do not use `--clobber` to replace a distributed package with a different build.

For a still-unpublished draft prepared under `v*`, first confirm no tag exists,
rename the draft tag to `clients-v*`, and rename its combined manifest to
`SHA256SUMS-clients.txt`. Update its notes and recheck remote asset hashes.
Preserve the original package bytes and source revision. A workflow fix on a
newer branch does not change the workflow stored at an older release commit.
Do not move a published tag to make its source appear newer.

## Acceptance before publication

Record the commit, package checksum, OS/device and each result:

1. Follow [the installation guide](INSTALLATION.md) on a clean user environment.
2. Open a profile, enroll in a disposable reachable relay, close and quit the app.
3. Reopen it and confirm the same enrollment without reentering the invitation.
4. Build the next version, install it over the existing app and reopen the profile.
5. On macOS, record any Keychain prompt and whether the user can grant access.
   Do not broaden an item's ACL to all applications to make a test pass.
6. On Android, verify the signing certificate is unchanged and the build number
   increased. Do not uninstall or clear data to pass an update test.
7. Review `BUILD.json`, checksums, artifact contents, documentation and repository
   hygiene. Publish only committed, tested artifacts with release notes stating
   the experimental scope and actual acceptance results.

An emulator result does not replace physical-phone acceptance. Local macOS
testing does not establish Gatekeeper behavior on a fresh downloaded install.
Keep invitations, live endpoints, screenshots containing them and test builds
private. See [the platform matrix](PLATFORMS.md) for recorded results.
