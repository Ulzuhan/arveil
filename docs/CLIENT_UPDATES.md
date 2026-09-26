# Signed Android updates

Arveil can check for updates, download a verified APK and ask Android to install
it over the existing app. The identity and conversations stay in app storage.
**Never uninstall or clear storage to update.** An older client without this
screen needs one manual installation over the existing app to gain it.

Updates are independent of the realm. A distributor chooses an HTTPS feed and
an Ed25519 public key at build time. An ordinary source build has no feed and
does not contact a project-operated service. macOS still uses manual replacement;
Sparkle and automatic update-key rotation are not implemented by this change.

*Español: [Actualizaciones firmadas](es/CLIENT_UPDATES.md).*

## User experience and privacy

Open **Settings → Updates**, or the update icon on the closed-profile screen.
Checking is manual by default. The optional foreground check runs at most once
per day, including failed attempts and restarts. It displays an in-app notice;
there is no push service, background polling or notification while the app is
closed. Enabling the option does not install anything.

A check requests the complete feed with no installed version, profile ID,
cookie or identifying user agent. The feed host/CDN still sees the IP and time.
Downloading an update also contacts the APK host. Both actions work without
opening a profile or connecting to a realm.

The app verifies the announcement before showing its release notes. Download
size and SHA-256 must match. **Install update** may first require Android's
per-app permission to install packages; return to Arveil and press Install
again. A `PackageInstaller` session verifies the package ID, increasing build
number and the current signing certificate. On Android 12+, the session
explicitly requires user action. Android performs the final APK verification
and asks the user to confirm. No uninstall, downgrade or data-clear fallback is
offered. An expired announcement must be refreshed before installation.

## Configure a distribution

Use [client packaging](CLIENT_RELEASES.md) and retain the existing Android
release key. Create a **different**, offline update key once, with OpenSSL 3:

```sh
python3 scripts/client_updates.py init-key --key .local/update-signing/update.pem
```

Back it up encrypted, separately from the APK key. It never belongs on the
website, relay or CI. The command refuses to overwrite it and prints only the
public key. Keep the following file in `.local/distribution.json`, mode 0600:

```json
{
  "ARVEIL_UPDATE_URL": "https://project.example.org/updates/clients-beta.json",
  "ARVEIL_UPDATE_PUBLIC_KEY": "BASE64_32_BYTE_PUBLIC_KEY",
  "ARVEIL_UPDATE_CHANNEL": "beta"
}
```

Replace the public-key placeholder with the printed value. Only these three
fields are accepted. Use `stable` or `beta`; each has its own feed and sequence.
Never add a realm hostname, bootstrap, invite, private key or tunnel token to
this file. The URL, **public** key and channel are embedded in the app and
recorded in its public `BUILD.json`; their local file path is not.

```sh
python3 scripts/package_clients.py build android \
  --signing-config .local/signing/android-signing.json \
  --update-config .local/distribution.json --build-number 18
```

The build number is illustrative: always choose one higher than every build
already distributed under that Android signing key. Commit the source first;
dirty candidates can be tested locally but cannot be announced by the signing
command. The feed is a distribution choice, not a dependency of self-hosting.

## Announce a release

Prepare the immutable `clients-v*` GitHub release and verify its artifacts as
described in the [release guide](CLIENT_RELEASES.md). Write concise plain-text
release notes in a private file. Sign a new announcement locally:

```sh
python3 scripts/client_updates.py sign \
  --key .local/update-signing/update.pem \
  --config .local/distribution.json \
  --package dist/clients/0.1.0+18/android \
  --sequence 1 --valid-days 30 \
  --notes .local/release-notes.txt \
  --asset-url https://github.com/example/arveil/releases/download/clients-v0.1.0-beta.1/arveil-0.1.0-18-android-arm64.apk \
  --notes-url https://github.com/example/arveil/releases/tag/clients-v0.1.0-beta.1 \
  --output .local/releases/clients-beta-1.json
```

Keep a private publication ledger of sequence numbers. **Every changed payload,
including an expiry extension for the same APK, needs a higher sequence.** The
tool checks package hashes, clean-build metadata, distribution/key agreement
and an immutable GitHub asset URL, then verifies its own OpenSSL signature.
It writes a new file exclusively; it never publishes or overwrites one.

Publish the verified APK first, attach the signed announcement under its
unique sequence filename, and atomically serve those same bytes at the feed's
fixed URL. Do not redirect the feed or put a browser login/challenge in front
of it. The client requests `Accept-Encoding: identity` and rejects compressed
responses. Use `Content-Type: application/json`, no content compression, and
`Cache-Control: no-cache` or a short cache lifetime; purge an old cached feed
when publishing. Downloads may follow at most five HTTPS redirects because
GitHub assets use a storage host. Never use `releases/latest` or replace an
existing APK. Check the public feed against the locally signed bytes after
publication. Serve the feed separately from any personal realm.

The default expiry is 30 days (maximum 90). Refresh it with a new sequence
before it expires, even when there is no new APK. Expiry prevents offering
updates from a stale announcement; it does not disable messaging. A host can
still withhold a newer announcement while an older signed one is valid, and
device-clock tampering is outside the rollback protection.

## Wire format and local state

The envelope is JSON with `schema: 1`, base64 `payload` and base64 `signature`.
Sign the UTF-8 bytes `arveil-client-updates-v1\n` followed by the **exact decoded
payload bytes**, using Ed25519. No JSON reserialization is used for verification.
The payload contains:

```json
{
  "schema": 1,
  "channel": "beta",
  "sequence": 1,
  "expires": "2030-01-01T00:00:00Z",
  "platforms": {
    "android-arm64": {
      "version": "0.1.0",
      "build": 18,
      "minimum_sdk": 24,
      "application_id": "io.github.ulzuhan.arveil",
      "url": "https://github.com/example/arveil/releases/download/clients-v0.1.0-beta.1/app.apk",
      "size": 123,
      "sha256": "64-lowercase-hex-characters",
      "notes": "Plain-text release notes.",
      "notes_url": "https://example.org/releases/18"
    }
  }
}
```

The feed is limited to 64 KiB and the APK to 512 MiB. Timeouts and streamed
size checks bound downloads. Invalid/partial downloads are removed. Android
hashes the bytes again while copying them into the installation session.

`updates.json` in application support stores the opt-in choice, last attempt,
and highest accepted sequence plus payload digest, bound to the update key
and channel. It contains no profile information. Atomic replacement must
succeed before an announcement is offered. Repeating the exact announcement
is allowed; a lower sequence or a changed payload at the same sequence is not.
A failed read/write fails closed instead of resetting that protection. App
storage deletion or a privileged local attacker can reset this state.

Key rotation and switching a previously configured installation between
channels require a separately reviewed migration; do not just replace the
compiled key, reset update state or tell users to reinstall from scratch.
The current Android certificate check intentionally requires the same current
signers and does not implement APK signing-key lineage migration.

## Verification

`flutter test test/updates_test.dart test/update_transport_test.dart` covers
signatures (including an independent OpenSSL fixture), expiry, sequence reuse
and rollback, disabled checks, daily scheduling, package tampering and redirects.
`python3 -m unittest discover -s scripts -p 'test_client_updates.py'` exercises
the offline signing boundary. Android `app:testDebugUnitTest` checks the exact
session bytes, application ID, version and certificate policy.

For the actual system installer, use the private
`integration_test/update_installer_acceptance.dart` entry point on a disposable
emulator. Build a debug APK with `ARVEIL_TEST_UPDATER=before`, then one with
`ARVEIL_TEST_UPDATER=after` and a higher build number, signed with the same test
key. The first creates an encrypted native profile and retains its key in
Android Keystore. Put the second APK in the app's private `cache/updates/update.apk`
and its `build`, `size`, `sha256` in `cache/updates/acceptance.json`. Grant the
per-app installation permission, tap **Install test update**, and verify the
system confirmation. After installation, launch again and require
`ARVEIL_TEST_UPDATER_OK:profile:after`. Also test denial, cancel, a wrong
certificate and tampering; each must preserve the installed app. Do not use
`adb install -r` for the second APK in this test: the point is to exercise the
app's own `PackageInstaller` path. Never distribute either acceptance APK.
