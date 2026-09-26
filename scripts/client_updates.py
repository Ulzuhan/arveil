#!/usr/bin/env python3
"""Create an offline Ed25519 update key and sign Android release announcements.

Requires OpenSSL 3. Private keys never enter argv, logs, CI or the repository.
This command only creates local files; it does not publish or upload anything.
"""
import argparse
import base64
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from urllib.parse import urlparse

DOMAIN = b"arveil-client-updates-v1\n"
PUBLIC_DER_PREFIX = bytes.fromhex("302a300506032b6570032100")
MAX_BYTES = 512 * 1024 * 1024


def openssl(tool, *args, data=None):
    return subprocess.run([tool, *args], input=data, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, check=True).stdout


MAX_NOTES = 8000


def https_url(value, *, query=True):
    uri = urlparse(value)
    # The app's Uri counts a bare "?" or "#" as a query or fragment, so check
    # the text rather than the parsed parts, which are empty then.
    if uri.scheme != "https" or not uri.hostname or uri.username or uri.password or "#" in value:
        raise ValueError("Update URLs must be HTTPS, without credentials or fragments.")
    if not query and "?" in value:
        raise ValueError("The feed URL must not contain query parameters.")
    return value


def check_notes(notes):
    # Code points, as the app counts them (Dart's runes), not UTF-16 units.
    if len(notes) > MAX_NOTES:
        raise ValueError(f"Release notes must be at most {MAX_NOTES} characters.")
    return notes


def read_config(path):
    config = json.loads(path.read_text())
    fields = {"ARVEIL_UPDATE_URL", "ARVEIL_UPDATE_PUBLIC_KEY", "ARVEIL_UPDATE_CHANNEL"}
    if set(config) != fields:
        raise ValueError("Update configuration must contain only the three documented public distribution fields.")
    https_url(config["ARVEIL_UPDATE_URL"], query=False)
    if len(base64.b64decode(config["ARVEIL_UPDATE_PUBLIC_KEY"], validate=True)) != 32:
        raise ValueError("The update public key must be 32 bytes, base64 encoded.")
    if config["ARVEIL_UPDATE_CHANNEL"] not in ("stable", "beta"):
        raise ValueError("The update channel must be stable or beta.")
    return config


def public_key(tool, key):
    der = openssl(tool, "pkey", "-in", str(key), "-pubout", "-outform", "DER")
    if len(der) != len(PUBLIC_DER_PREFIX) + 32 or not der.startswith(PUBLIC_DER_PREFIX):
        raise ValueError("Expected an Ed25519 update key.")
    return base64.b64encode(der[len(PUBLIC_DER_PREFIX):]).decode()


def private_output(path, data):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with open(path, "xb", opener=lambda p, f: os.open(p, f, 0o600)) as output:
        output.write(data)


def init_key(args):
    # Exclusive creation first: even OpenSSL must not overwrite an existing key.
    private_output(args.key, openssl(args.openssl, "genpkey", "-algorithm", "ED25519"))
    print("Update key created. Back it up securely, separately from the Android key.")
    print("Public key (safe to distribute): " + public_key(args.openssl, args.key))


def sign(args):
    if args.key.stat().st_mode & 0o077:
        raise ValueError("The update key must be private (chmod 600).")
    config = read_config(args.config)
    if public_key(args.openssl, args.key) != config["ARVEIL_UPDATE_PUBLIC_KEY"]:
        raise ValueError("Signing key does not match the client's configured public key.")
    build = json.loads((args.package / "BUILD.json").read_text())
    if build.get("dirty_source") is not False or build.get("platform") != "android" or build.get("architecture") != "arm64":
        raise ValueError("Only a clean, packaged Android arm64 release may be announced.")
    if build.get("update_config") != config:
        raise ValueError("The APK was not built for this exact update distribution.")
    if not re.fullmatch(r"[0-9a-f]{64}", build.get("certificate_sha256", "")):
        raise ValueError("The build is missing its Android signing certificate fingerprint.")
    artifacts = list(args.package.glob("*.apk"))
    if len(artifacts) != 1:
        raise ValueError("Expected exactly one APK in the package directory.")
    apk = artifacts[0]
    # Check the packaging manifest before signing, including BUILD.json itself.
    sums = {}
    for line in (args.package / "SHA256SUMS.txt").read_text().splitlines():
        digest, name = line.split("  ", 1)
        if Path(name).name != name or name in sums or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise ValueError("Malformed package checksums.")
        sums[name] = digest
    for file in (apk, args.package / "BUILD.json"):
        if hashlib.sha256(file.read_bytes()).hexdigest() != sums.get(file.name):
            raise ValueError("A package no longer matches its release checksums.")
    if not 1 <= apk.stat().st_size <= MAX_BYTES:
        raise ValueError("APK size is outside the supported range.")
    if not 1 <= args.sequence <= 9007199254740991 or not 1 <= args.valid_days <= 90:
        raise ValueError("Use a positive sequence and an expiry of 1–90 days.")
    if not re.fullmatch(r"\d+\.\d+\.\d+", build["version"]) or not 1 <= build["build"] <= 2100000000:
        raise ValueError("Invalid Android version or build.")
    if not 21 <= build["minimum_sdk"] <= 1000:
        raise ValueError("Invalid minimum Android SDK.")
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+", build.get("application_id", "")):
        raise ValueError("Missing or invalid Android application ID.")
    notes = check_notes(args.notes.read_text(encoding="utf-8"))
    url = https_url(args.asset_url)
    parsed = urlparse(url)
    # No mutable /latest links, arbitrary websites or versionless download URLs.
    if parsed.hostname != "github.com" or parsed.query or not re.fullmatch(
            r"/[^/]+/[^/]+/releases/download/clients-v[^/]+/" + re.escape(apk.name), parsed.path):
        raise ValueError("Use this APK's immutable clients-v* GitHub release asset URL.")
    expires = (datetime.now(timezone.utc) + timedelta(days=args.valid_days)).isoformat().replace("+00:00", "Z")
    payload = json.dumps({
        "schema": 1, "channel": config["ARVEIL_UPDATE_CHANNEL"], "sequence": args.sequence,
        "expires": expires,
        "platforms": {"android-arm64": {
            "version": build["version"], "build": build["build"], "minimum_sdk": build["minimum_sdk"],
            "application_id": build["application_id"], "url": url, "size": apk.stat().st_size,
            "sha256": sums[apk.name], "notes": notes, "notes_url": https_url(args.notes_url),
        }},
    }, ensure_ascii=False, separators=(",", ":")).encode()
    with tempfile.TemporaryDirectory(prefix="arveil-update-sign-") as temporary:
        source = Path(temporary) / "payload"
        private_output(source, DOMAIN + payload)
        signature = openssl(args.openssl, "pkeyutl", "-sign", "-rawin", "-inkey", str(args.key), "-in", str(source))
        if len(signature) != 64:
            raise ValueError("Unexpected Ed25519 signature length.")
        public = Path(temporary) / "public.der"
        private_output(public, PUBLIC_DER_PREFIX + base64.b64decode(config["ARVEIL_UPDATE_PUBLIC_KEY"]))
        signed = Path(temporary) / "signature"
        private_output(signed, signature)
        openssl(args.openssl, "pkeyutl", "-verify", "-rawin", "-pubin", "-keyform", "DER",
                "-inkey", str(public), "-in", str(source), "-sigfile", str(signed))
    envelope = json.dumps({"schema": 1, "payload": base64.b64encode(payload).decode(),
                           "signature": base64.b64encode(signature).decode()}, indent=2).encode() + b"\n"
    if len(envelope) > 65536:
        raise ValueError("Signed manifest exceeds the client's size limit.")
    private_output(args.output, envelope)
    print("Signed manifest verified locally. Publish it only after the immutable release assets are available.")


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--openssl", default="openssl", help="OpenSSL 3 executable")
    commands = parser.add_subparsers(required=True)
    init = commands.add_parser("init-key")
    init.add_argument("--key", type=Path, required=True)
    init.set_defaults(action=init_key)
    signed = commands.add_parser("sign")
    for field in ("key", "config", "package", "notes", "output"):
        signed.add_argument("--" + field, type=Path, required=True)
    signed.add_argument("--asset-url", required=True)
    signed.add_argument("--notes-url", required=True)
    signed.add_argument("--sequence", type=int, required=True)
    signed.add_argument("--valid-days", type=int, default=30)
    signed.set_defaults(action=sign)
    args = parser.parse_args()
    try:
        args.action(args)
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        print(str(error) if isinstance(error, ValueError) else
              "Update signing failed; check local inputs and OpenSSL 3. Nothing was published.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
