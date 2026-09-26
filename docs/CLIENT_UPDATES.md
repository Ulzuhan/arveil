# Signed Android updates

Arveil can check for updates, download a verified APK and ask Android to install
it over the existing app. The identity and conversations stay in app storage.
**Never uninstall or clear storage to update.** An older client without this
screen needs one manual installation over the existing app to gain it.

Updates are independent of the realm. A distributor chooses an HTTPS feed and
an Ed25519 public key at build time. An ordinary source build has no feed and
does not contact a project-operated service. On macOS the app checks the same
signed feed and, when there is a newer version, opens its download: the person
replaces the app, or runs `brew upgrade --cask arveil` (see
[On macOS](#on-macos)). Sparkle and automatic update-key rotation are not
implemented.

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
per-app permission to install packages (on Android 7, the global **Unknown
sources** setting, off by default on phones); return to Arveil and press
**Install update** again. Before creating a `PackageInstaller` session, the app
checks the package ID, a higher build number and the current signing
certificate, and hashes the bytes again as it copies them into the session. On
Android 12+, the session explicitly requires user action. Android performs the final APK verification
and asks the user to confirm. No uninstall, downgrade or data-clear fallback is
offered. An expired announcement must be refreshed before installation.

An offer that expires, or that a newer announcement overtakes, leaves the
screen. A check that fails, for lack of connection or because the service
answered badly, keeps an offer that is still valid, with its download. If
Android cannot take the package, for example for lack of space, the download
stays for another attempt; a package that is not the announced one is deleted.
Some Android versions send no answer when the confirmation is dismissed: back
in Arveil, the attempt then reads as cancelled after a moment, and **Install
update** starts again. The release notes link opens in the browser, which
contacts that site.

Only builds with a feed request Android's permission to install packages.
**Settings → Diagnostics** reports `updates:` followed by `none`, the channel,
or `invalid` when the build carries an update configuration the app refused;
such a build behaves as one without updates.

## On macOS

The Mac app has the same **Settings → Updates** screen, the same opt-in daily
check and the same verification: signature, channel, sequence and expiry. It
offers the `macos-arm64` entry of the announcement when its build is higher
than the app's own (`CFBundleVersion`) and the Mac meets `minimum_os`.
**Download in the browser** opens that entry's `url`, the ZIP in the GitHub
release; the app never downloads, unpacks or replaces anything itself. The
person quits Arveil and replaces the app in Applications, or runs
`brew upgrade --cask arveil` if they installed it with
[Homebrew](https://github.com/kaicorplabs/homebrew-tap). The profile stays in
the app's sandbox container either way. An announcement without a macOS entry
offers nothing on the Mac, and Android ignores the macOS entry.

The Mac package carries the update configuration like the APK: build it with
`--update-config`, and sign the announcement with `--macos-package` and
`--macos-asset-url` as well. Both packages must be the same version and build.

## Configure a distribution

Use [client packaging](CLIENT_RELEASES.md) and retain the existing Android
release key. Create a **different**, offline update key once, with OpenSSL 3:

```sh
python3 scripts/client_updates.py init-key --key .local/update-signing/update.pem
```

Back it up encrypted, separately from the APK key. It never belongs on the
website, relay or CI. The command refuses to overwrite it, saying that the key
already exists, and prints only the public key.

The command asks twice, in the terminal, for a passphrase of at least 12
characters and stores the key encrypted with it (PKCS#8, AES-256 and
PBKDF2-HMAC-SHA256 with 600,000 iterations); signing asks for it again.
Neither the passphrase nor the key passes through command arguments or
environment variables. Generate a long random passphrase and keep it in a
password manager, never beside the key. **Losing the passphrase is losing the
key:** the only way out is rotating the update key (see below), which takes a
new build signed with the Android key. For scripted use, `--passphrase-fd N`
reads the passphrase from the first line of the inherited file descriptor N
instead of the terminal, for example through a pipe from a password manager's
command-line tool. Without a terminal or that option, the tool stops rather
than read a passphrase that would be echoed.

A key created before this encryption existed is plain PEM. Signing still
accepts it, with a warning. Encrypt it once; the command checks that the public
key is unchanged and prints it. Then replace the file and destroy the plaintext
key and every unencrypted backup of it:

```sh
python3 scripts/client_updates.py encrypt-key \
  --key .local/update-signing/update.pem \
  --output .local/update-signing/update-encrypted.pem
mv .local/update-signing/update-encrypted.pem .local/update-signing/update.pem
```

Keep the following file in `.local/distribution.json`, mode 0600:

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
already distributed under that Android signing key. The packaging helper
checks that the APK's `versionCode` equals this build number, which
`BUILD.json` records and the announcement carries, and that the APK requests
Android's permission to install packages only when built with
`--update-config`. It refuses `--update-config` for macOS, which has no signed
updater yet. Commit the source first; dirty candidates can be tested locally
but cannot be announced by the signing command. The feed is a distribution
choice, not a dependency of self-hosting.

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
  --macos-package dist/clients/0.1.0+18/macos \
  --macos-asset-url https://github.com/example/arveil/releases/download/clients-v0.1.0-beta.1/arveil-0.1.0-18-macos-arm64.zip \
  --notes-url https://github.com/example/arveil/releases/tag/clients-v0.1.0-beta.1 \
  --output .local/releases/clients-beta-1.json
```

**Every changed payload, including an expiry extension for the same APK, needs
a higher sequence.** The tool keeps that record itself: `sequences.json`,
beside the key (here in `.local/update-signing/`, which Git ignores), lists
each signed sequence per channel with its version, build, expiry and the
SHA-256 of the signed file. Pass `--sequence` only for a channel's first
announcement: 1 for a new channel or, if announcements were signed before the
ledger existed, one higher than the last one published. Afterwards omit it;
the tool uses the next number and prints it. An explicit `--sequence` must be
higher than the last one recorded. A missing ledger, or a channel without
entries, means no earlier announcement. A malformed ledger stops signing and is
never reset: restore it from a backup or correct it by hand. The entry is
written atomically, mode 0600, only after the signature verifies and before the
output file, so a failed write can skip a number but never reuse one; clients
accept gaps. Back up the ledger with the key.

The tool checks package hashes, clean-build metadata, distribution/key agreement
and an immutable GitHub asset URL, then verifies its own OpenSSL signature.
It writes a new file exclusively; it never publishes or overwrites one.

Publish the verified APK first, attach the signed announcement under its
unique sequence filename, and atomically serve those same bytes at the feed's
fixed URL. Do not redirect the feed or put a browser login/challenge in front
of it. The client requests `Accept-Encoding: identity` and rejects compressed
responses, so its limits and hashes apply to the exact bytes. Use `Content-Type: application/json`, no content compression, and
`Cache-Control: no-cache` or a short cache lifetime; purge an old cached feed
when publishing. Downloads may follow at most five HTTPS redirects because
GitHub assets use a storage host. The app trusts the system's certificate
authorities plus ISRG Root X1: GitHub serves those assets under Let's Encrypt,
and Android 7.0 does not carry that root. Never use `releases/latest` or replace an
existing APK. Check the public feed against the locally signed bytes after
publication. Serve the feed separately from any personal realm.

If Cloudflare Browser Integrity Check rejects the updater's header profile,
use the [exact-path exception and re-enable procedure](TUNNEL.md#browser-integrity-check).
Keep the actual rule ID, scope, approval and reversal history in private operator
notes. Re-enabling BIC may block update checks again; the app must continue to
reject invalid signatures rather than bypassing verification to recover access.

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
    },
    "macos-arm64": {
      "version": "0.1.0",
      "build": 18,
      "minimum_os": "12.0",
      "url": "https://github.com/example/arveil/releases/download/clients-v0.1.0-beta.1/app.zip",
      "size": 123,
      "sha256": "64-lowercase-hex-characters",
      "notes": "Plain-text release notes.",
      "notes_url": "https://example.org/releases/18"
    }
  }
}
```

`macos-arm64` is optional; the Android entry is always present, so Android
clients from before it keep reading the feed. A malformed macOS entry rejects
the whole announcement, as a malformed Android entry does.

The feed is limited to 64 KiB and the APK to 512 MiB. Release notes are plain
text of at most 8,000 Unicode code points; the signer and the app count them
the same way, and `clients/flutter/test/fixtures/update-manifest-vectors.json`
keeps their rules in step. A download fails if it stalls for 30 seconds or
takes longer than 10 minutes plus one second per 16 KiB of package; streamed
size checks bound it too. Invalid/partial downloads are removed, and a
downloaded package is removed when the app next starts, so it never stays after
installing. The app hashes the bytes again while copying them into the
installation session.

`updates.json` in application support stores the opt-in choice, the last
attempt and, for each update key and channel, the highest accepted sequence
plus payload digest. A build with another key or channel starts its own
history at zero; the others keep their protection. It contains no profile
information. Atomic replacement must
succeed before an announcement is offered. Repeating the exact announcement
is allowed; a lower sequence or a changed payload at the same sequence is not.
A failed read/write fails closed instead of resetting that protection. Do not
clear the app's data to recover: that deletes the encrypted profile as well.
App storage deletion or a privileged local attacker can reset this state.

Switching an installation between channels needs nothing more: the new
channel keeps its own history. Rotating the update key means publishing a
build with the new public key, which people install by hand once, as
[ADR-010](adr/ADR-010-distribution-and-updates.md) describes; never reset
update state or tell users to reinstall from scratch. Losing the update key or
its passphrase leaves only this rotation, and that build must be signed with
the existing Android key.
The current Android certificate check intentionally requires the same current
signers and does not implement APK signing-key lineage migration.

## Verification

`flutter test test/updates_test.dart test/update_transport_test.dart` covers
signatures (including an independent OpenSSL fixture), expiry, sequence reuse
and rollback, disabled checks, daily scheduling, package tampering and redirects.
`python3 -m unittest discover -s scripts -p 'test_client_updates.py'` exercises
the offline signing boundary, including the sequence ledger and encrypted keys;
`test_package_clients.py` checks the APK's version code and installer
permission. Android `app:testDebugUnitTest` checks the exact
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

For the whole flow, use `integration_test/update_flow_acceptance.dart`. It runs
the real app with the real update controller, transport, Rust signature check
and installer; the only difference is one more trusted root, the disposable
authority of a local HTTPS test feed, passed as `ARVEIL_TEST_UPDATE_CA`. Build a
`before` and an `after` APK with the feed's URL and a disposable update key,
sign an announcement for the second with that key, serve both from the test
feed, and use **Settings → Updates** in the first: check, download, install
and confirm. The second must report `ARVEIL_TEST_UPDATER_OK:profile:after` and
its `ARVEIL_TEST_UPDATER_STATE` line the kept sequence and the removed package.
`ARVEIL_TEST_TRUST_PROBE` makes both report whether an HTTPS address is reached
with the system's roots and with the updater's.
