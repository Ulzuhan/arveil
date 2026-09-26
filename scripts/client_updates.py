#!/usr/bin/env python3
"""Create an offline Ed25519 update key and sign Android release announcements.

Requires OpenSSL 3. Private keys and their passphrase never enter argv, the
environment, logs, CI or the repository. This command only creates local
files; it does not publish or upload anything.
"""
import argparse
import base64
from datetime import datetime, timedelta, timezone
import fcntl
import getpass
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from urllib.parse import urlparse
import warnings

DOMAIN = b"arveil-client-updates-v1\n"
PUBLIC_DER_PREFIX = bytes.fromhex("302a300506032b6570032100")
MAX_BYTES = 512 * 1024 * 1024
MAX_SEQUENCE = 9007199254740991
# PKCS#8 with AES-256 and PBKDF2-HMAC-SHA256; OpenSSL's default is 2048 iterations.
KEY_ENCRYPTION = ("-v2", "aes-256-cbc", "-v2prf", "hmacWithSHA256", "-iter", "600000")
ENCRYPTED_KEY = b"-----BEGIN ENCRYPTED PRIVATE KEY-----"
MIN_PASSPHRASE = 12
MAX_PASSPHRASE = 1000  # UTF-8 bytes; OpenSSL reads fewer than 1024 from fd:N.
LEDGER = "sequences.json"
LEDGER_MALFORMED = ("The sequence ledger (sequences.json beside the update key) is malformed. "
                    "It was not changed; restore it from a backup or correct it by hand.")
KEY_EXISTS = "An update key already exists at that path; nothing was changed."
OUTPUT_EXISTS = "The output file already exists; choose a new name. Nothing was changed."


def openssl(tool, *args, data=None, passin=None, passout=None):
    """Run OpenSSL. A passphrase travels only through an inherited pipe (fd:N)."""
    command, descriptors, secret = [tool, *args], (), passin if passin is not None else passout
    if secret is not None:
        read, write = os.pipe()
        if read < 3:  # Possible with stdin closed; the child's stdin would replace it.
            low, read = read, fcntl.fcntl(read, fcntl.F_DUPFD_CLOEXEC, 3)
            os.close(low)
        descriptors = (read,)
        # Bounded by MAX_PASSPHRASE, it fits the pipe buffer before OpenSSL runs.
        with open(write, "wb") as pipe:
            pipe.write(secret + b"\n")
        command += ["-passin" if passin is not None else "-passout", f"fd:{read}"]
    # Never the caller's stdin: OpenSSL may misread a key when it is a socket.
    source = {"input": data} if data is not None else {"stdin": subprocess.DEVNULL}
    try:
        return subprocess.run(command, **source, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              check=True, pass_fds=descriptors).stdout
    finally:
        for descriptor in descriptors:
            os.close(descriptor)


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


def integer(value, low, high):
    return type(value) is int and low <= value <= high


def text(value, pattern):
    return isinstance(value, str) and re.fullmatch(pattern, value)


def read_config(path):
    config = json.loads(path.read_text(encoding="utf-8"))
    fields = {"ARVEIL_UPDATE_URL", "ARVEIL_UPDATE_PUBLIC_KEY", "ARVEIL_UPDATE_CHANNEL"}
    if not isinstance(config, dict) or set(config) != fields or not all(isinstance(v, str) for v in config.values()):
        raise ValueError("Update configuration must contain only the three documented public distribution fields.")
    https_url(config["ARVEIL_UPDATE_URL"], query=False)
    if len(base64.b64decode(config["ARVEIL_UPDATE_PUBLIC_KEY"], validate=True)) != 32:
        raise ValueError("The update public key must be 32 bytes, base64 encoded.")
    if config["ARVEIL_UPDATE_CHANNEL"] not in ("stable", "beta"):
        raise ValueError("The update channel must be stable or beta.")
    return config


def read_build(path):
    build = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(build, dict):
        raise ValueError("BUILD.json must contain a JSON object.")
    return build


def read_passphrase(args, *, new=False):
    """Read from --passphrase-fd or the terminal; never from argv or the environment."""
    if args.passphrase_fd is not None:
        with open(args.passphrase_fd, "rb") as source:
            line = source.readline(MAX_PASSPHRASE + 2).removesuffix(b"\n")
        try:
            value = line.decode()
        except UnicodeDecodeError:  # Its message would quote passphrase bytes.
            raise ValueError("The passphrase must be UTF-8 text.") from None
    else:
        with warnings.catch_warnings():
            # Without a terminal, getpass would read stdin with echo; refuse instead.
            warnings.simplefilter("error", getpass.GetPassWarning)
            try:
                value = getpass.getpass("New update key passphrase: " if new else "Update key passphrase: ")
                if new and getpass.getpass("Repeat the passphrase: ") != value:
                    raise ValueError("The passphrases differ; nothing was changed.")
            except (getpass.GetPassWarning, EOFError):
                raise ValueError("Enter the passphrase in a terminal, or use --passphrase-fd.") from None
    if not value or "\0" in value or len(value.encode()) > MAX_PASSPHRASE:
        raise ValueError(f"The passphrase must be 1–{MAX_PASSPHRASE} bytes, on one line.")
    if new and len(value) < MIN_PASSPHRASE:
        raise ValueError(f"Use a passphrase of at least {MIN_PASSPHRASE} characters; nothing was changed.")
    return value.encode()


def encrypted(key):
    with open(key, "rb") as source:
        return source.readline().strip() == ENCRYPTED_KEY


def public_key(tool, key, passphrase=None):
    der = openssl(tool, "pkey", "-in", str(key), "-pubout", "-outform", "DER", passin=passphrase)
    if len(der) != len(PUBLIC_DER_PREFIX) + 32 or not der.startswith(PUBLIC_DER_PREFIX):
        raise ValueError("Expected an Ed25519 update key.")
    return base64.b64encode(der[len(PUBLIC_DER_PREFIX):]).decode()


def private_output(path, data, exists=None):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        with open(path, "xb", opener=lambda p, f: os.open(p, f, 0o600)) as output:
            output.write(data)
    except FileExistsError:
        if exists is None:
            raise
        raise ValueError(exists) from None


def replace_private(path, data):
    """Write a private sibling file, flush it, then rename it over path."""
    descriptor, temporary = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with open(descriptor, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    except BaseException:
        Path(temporary).unlink(missing_ok=True)
        raise


def init_key(args):
    if os.path.lexists(args.key):
        raise ValueError(KEY_EXISTS)
    passphrase = read_passphrase(args, new=True)
    key = openssl(args.openssl, "genpkey", "-algorithm", "ED25519")
    protected = openssl(args.openssl, "pkcs8", "-topk8", *KEY_ENCRYPTION, data=key, passout=passphrase)
    # OpenSSL writes only to pipes. The key file is created afterwards,
    # exclusively and 0600, so an existing key is never replaced, even one
    # that appeared meanwhile.
    private_output(args.key, protected, KEY_EXISTS)
    public = public_key(args.openssl, args.key, passphrase)  # Also proves the passphrase opens it.
    print("Update key created and encrypted with its passphrase. Keep the passphrase in a password "
          "manager and back the key up securely, separately from the Android key.")
    print("Public key (safe to distribute): " + public)


def encrypt_key(args):
    """Write a passphrase-protected copy of a plaintext key created before encryption."""
    if encrypted(args.key):
        raise ValueError("The update key is already passphrase-protected; nothing was changed.")
    if os.path.lexists(args.output):
        raise ValueError(OUTPUT_EXISTS)
    public = public_key(args.openssl, args.key)
    passphrase = read_passphrase(args, new=True)
    protected = openssl(args.openssl, "pkcs8", "-topk8", *KEY_ENCRYPTION, "-in", str(args.key),
                        passout=passphrase)
    private_output(args.output, protected, OUTPUT_EXISTS)
    if public_key(args.openssl, args.output, passphrase) != public:
        raise ValueError("The encrypted copy does not match the original key; do not use it.")
    print("Encrypted copy verified; the public key is unchanged: " + public)
    print("Replace the plaintext key with it, then destroy the plaintext file and any unencrypted backup.")


def read_ledger(path):
    """Signed sequences per channel. No file, or no channel entry, means no earlier announcement."""
    try:
        ledger = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {"schema": 1, "channels": {}}
    except ValueError:  # Invalid UTF-8 or JSON; never reset the ledger.
        raise ValueError(LEDGER_MALFORMED) from None
    if not (isinstance(ledger, dict) and set(ledger) == {"schema", "channels"} and integer(ledger["schema"], 1, 1)
            and isinstance(ledger["channels"], dict) and set(ledger["channels"]) <= {"stable", "beta"}):
        raise ValueError(LEDGER_MALFORMED)
    for entries in ledger["channels"].values():
        if not isinstance(entries, list) or not entries:
            raise ValueError(LEDGER_MALFORMED)
        previous = 0
        for entry in entries:
            if not isinstance(entry, dict) or not integer(entry.get("sequence"), previous + 1, MAX_SEQUENCE):
                raise ValueError(LEDGER_MALFORMED)
            previous = entry["sequence"]
    return ledger


def last_sequence(ledger, channel):
    entries = ledger["channels"].get(channel)
    return entries[-1]["sequence"] if entries else None


def choose_sequence(ledger, channel, requested):
    last = last_sequence(ledger, channel)
    if requested is None:
        if last is None:
            raise ValueError(f"No {channel} announcement is recorded yet; pass --sequence once "
                             "(1 for a new channel, or one higher than the last one published).")
        requested = last + 1
    if not integer(requested, (last or 0) + 1, MAX_SEQUENCE):
        raise ValueError(f"The {channel} sequence must be higher than {last}, the last one signed, "
                         f"and at most {MAX_SEQUENCE}." if last else f"Use a sequence from 1 to {MAX_SEQUENCE}.")
    return requested


def record_sequence(path, channel, entry):
    # Read again, so a concurrent signature cannot be overwritten silently.
    ledger = read_ledger(path)
    if entry["sequence"] <= (last_sequence(ledger, channel) or 0):
        raise ValueError("The sequence ledger changed while signing; nothing was written.")
    ledger["channels"].setdefault(channel, []).append(entry)
    replace_private(path, (json.dumps(ledger, indent=2) + "\n").encode())


def sign(args):
    if args.key.stat().st_mode & 0o077:
        raise ValueError("The update key must be private (chmod 600).")
    config = read_config(args.config)
    channel = config["ARVEIL_UPDATE_CHANNEL"]
    ledger = args.key.parent / LEDGER
    sequence = choose_sequence(read_ledger(ledger), channel, args.sequence)
    if not 1 <= args.valid_days <= 90:
        raise ValueError("Use an expiry of 1–90 days.")
    build = read_build(args.package / "BUILD.json")
    if build.get("dirty_source") is not False or build.get("platform") != "android" or build.get("architecture") != "arm64":
        raise ValueError("Only a clean, packaged Android arm64 release may be announced.")
    if build.get("update_config") != config:
        raise ValueError("The APK was not built for this exact update distribution.")
    if not text(build.get("certificate_sha256"), r"[0-9a-f]{64}"):
        raise ValueError("The build is missing its Android signing certificate fingerprint.")
    artifacts = list(args.package.glob("*.apk"))
    if len(artifacts) != 1:
        raise ValueError("Expected exactly one APK in the package directory.")
    apk = artifacts[0]
    # Check the packaging manifest before signing, including BUILD.json itself.
    sums = {}
    for line in (args.package / "SHA256SUMS.txt").read_text(encoding="utf-8").splitlines():
        digest, name = line.split("  ", 1)
        if Path(name).name != name or name in sums or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise ValueError("Malformed package checksums.")
        sums[name] = digest
    for file in (apk, args.package / "BUILD.json"):
        if hashlib.sha256(file.read_bytes()).hexdigest() != sums.get(file.name):
            raise ValueError("A package no longer matches its release checksums.")
    if not 1 <= apk.stat().st_size <= MAX_BYTES:
        raise ValueError("APK size is outside the supported range.")
    if not text(build.get("version"), r"\d+\.\d+\.\d+") or not integer(build.get("build"), 1, 2100000000):
        raise ValueError("Invalid Android version or build.")
    if not integer(build.get("minimum_sdk"), 21, 1000):
        raise ValueError("Invalid minimum Android SDK.")
    if not text(build.get("application_id"), r"[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+"):
        raise ValueError("Missing or invalid Android application ID.")
    notes = check_notes(args.notes.read_text(encoding="utf-8"))
    url = https_url(args.asset_url)
    parsed = urlparse(url)
    # No mutable /latest links, arbitrary websites or versionless download URLs.
    if parsed.hostname != "github.com" or parsed.query or not re.fullmatch(
            r"/[^/]+/[^/]+/releases/download/clients-v[^/]+/" + re.escape(apk.name), parsed.path):
        raise ValueError("Use this APK's immutable clients-v* GitHub release asset URL.")
    if os.path.lexists(args.output):
        raise ValueError(OUTPUT_EXISTS)
    # Ask for the passphrase only once every other input has been checked.
    if encrypted(args.key):
        passphrase = read_passphrase(args)
    else:
        passphrase = None
        print("Warning: the update key is not passphrase-protected; encrypt it with encrypt-key.", file=sys.stderr)
    try:
        public = public_key(args.openssl, args.key, passphrase)
    except subprocess.CalledProcessError:
        raise ValueError("Cannot read the update key; check the passphrase. Nothing was signed.") from None
    if public != config["ARVEIL_UPDATE_PUBLIC_KEY"]:
        raise ValueError("Signing key does not match the client's configured public key.")
    expires = (datetime.now(timezone.utc) + timedelta(days=args.valid_days)).isoformat().replace("+00:00", "Z")
    payload = json.dumps({
        "schema": 1, "channel": channel, "sequence": sequence,
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
        signature = openssl(args.openssl, "pkeyutl", "-sign", "-rawin", "-inkey", str(args.key),
                            "-in", str(source), passin=passphrase)
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
    # Record the sequence before writing the manifest: a failed write then
    # leaves an unused number, which clients accept, never a reused one.
    record_sequence(ledger, channel, {
        "sequence": sequence, "version": build["version"], "build": build["build"],
        "expires": expires, "manifest_sha256": hashlib.sha256(envelope).hexdigest()})
    private_output(args.output, envelope, OUTPUT_EXISTS)
    print(f"Signed {channel} sequence {sequence} and verified it locally. "
          "Publish it only after the immutable release assets are available.")


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--openssl", default="openssl", help="OpenSSL 3 executable")
    secret = argparse.ArgumentParser(add_help=False)
    secret.add_argument("--passphrase-fd", type=int, metavar="N",
                        help="for automation: read the key passphrase from the first line of inherited "
                             "file descriptor N instead of the terminal")
    commands = parser.add_subparsers(required=True)
    init = commands.add_parser("init-key", parents=[secret], help="create a passphrase-protected update key once")
    init.add_argument("--key", type=Path, required=True)
    init.set_defaults(action=init_key, failure="Update key creation failed; check OpenSSL 3. Nothing was changed.")
    encrypt = commands.add_parser("encrypt-key", parents=[secret],
                                  help="write a passphrase-protected copy of an older plaintext key")
    encrypt.add_argument("--key", type=Path, required=True)
    encrypt.add_argument("--output", type=Path, required=True)
    encrypt.set_defaults(action=encrypt_key, failure="Key encryption failed; check the key and OpenSSL 3.")
    signed = commands.add_parser("sign", parents=[secret], help="sign an announcement for a packaged APK")
    for field in ("key", "config", "package", "notes", "output"):
        signed.add_argument("--" + field, type=Path, required=True)
    signed.add_argument("--asset-url", required=True)
    signed.add_argument("--notes-url", required=True)
    signed.add_argument("--sequence", type=int,
                        help="required for a channel's first announcement; defaults to the next one in the ledger")
    signed.add_argument("--valid-days", type=int, default=30)
    signed.set_defaults(action=sign,
                        failure="Update signing failed; check local inputs and OpenSSL 3. Nothing was published.")
    args = parser.parse_args()
    try:
        args.action(args)
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        print(str(error) if isinstance(error, ValueError) else args.failure, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
