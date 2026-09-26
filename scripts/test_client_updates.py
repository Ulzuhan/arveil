from contextlib import redirect_stderr, redirect_stdout
import base64
import getpass
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import warnings

import client_updates as updates

VECTORS = json.loads((Path(__file__).resolve().parents[1] /
                      "clients/flutter/test/fixtures/update-manifest-vectors.json").read_text(encoding="utf-8"))
PASSPHRASE = "a test passphrase, not a secret"


def passphrase_fd(value=PASSPHRASE):
    """The read end of a pipe holding one passphrase line, as --passphrase-fd expects."""
    read, write = os.pipe()
    with open(write, "wb") as pipe:
        pipe.write(value.encode() + b"\n")
    return read


class SharedRuleTests(unittest.TestCase):
    """The app applies the same rules; a divergence fails both suites."""

    def test_domain_and_notes_limit_match_the_app(self):
        self.assertEqual(updates.DOMAIN.decode(), VECTORS["domain"])
        self.assertEqual(updates.MAX_NOTES, VECTORS["max_notes"])

    def test_notes_are_counted_like_the_app(self):
        for vector in VECTORS["notes"]:
            notes = "a" * vector["ascii"] + "\U0001F600" * vector["emoji"]
            with self.subTest(**vector):
                if vector["valid"]:
                    self.assertEqual(updates.check_notes(notes), notes)
                else:
                    self.assertRaises(ValueError, updates.check_notes, notes)

    def test_urls_are_judged_like_the_app(self):
        for vector in VECTORS["urls"]:
            for kind, query in (("feed", False), ("link", True)):
                with self.subTest(url=vector["url"], kind=kind):
                    if vector[kind]:
                        updates.https_url(vector["url"], query=query)
                    else:
                        self.assertRaises(ValueError, updates.https_url, vector["url"], query=query)


class SigningTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        # The terminal prompt, without a terminal; --passphrase-fd has its own tests.
        prompt = patch.object(updates.getpass, "getpass", return_value=PASSPHRASE)
        self.prompt = prompt.start()
        self.addCleanup(prompt.stop)
        self.key = self.directory / "update-signing" / "key.pem"
        self.ledger = self.key.parent / updates.LEDGER
        with redirect_stdout(io.StringIO()):
            updates.init_key(SimpleNamespace(openssl="openssl", key=self.key, passphrase_fd=None))
        self.config = {"ARVEIL_UPDATE_URL": "https://updates.example.org/clients.json",
                       "ARVEIL_UPDATE_PUBLIC_KEY": updates.public_key("openssl", self.key, PASSPHRASE.encode()),
                       "ARVEIL_UPDATE_CHANNEL": "beta"}
        self.config_path = self.directory / "config.json"
        self.config_path.write_text(json.dumps(self.config), encoding="utf-8")
        self.package = self.directory / "package"
        self.package.mkdir()
        self.apk = self.package / "arveil-0.1.0-18-android-arm64.apk"
        self.apk.write_bytes(b"a packaging fixture")
        self.metadata = self.valid_metadata()
        self.metadata_path = self.package / "BUILD.json"
        self.write_metadata()
        self.notes = self.directory / "notes.txt"
        self.notes.write_text("An update.\nActualización.", encoding="utf-8")
        self.args = SimpleNamespace(openssl="openssl", key=self.key, config=self.config_path,
            package=self.package, sequence=1, valid_days=30, notes=self.notes, passphrase_fd=None,
            asset_url=f"https://github.com/example/arveil/releases/download/clients-v0.1.0-beta.1/{self.apk.name}",
            notes_url="https://github.com/example/arveil/releases/tag/clients-v0.1.0-beta.1",
            output=self.directory / "clients-1.json")

    def valid_metadata(self):
        return {"dirty_source": False, "platform": "android", "architecture": "arm64",
                "update_config": self.config, "certificate_sha256": "a" * 64,
                "version": "0.1.0", "build": 18, "minimum_sdk": 24,
                "application_id": "io.github.ulzuhan.arveil"}

    def write_metadata(self, text=None):
        self.metadata_path.write_text(json.dumps(self.metadata) if text is None else text, encoding="utf-8")
        (self.package / "SHA256SUMS.txt").write_text("".join(
            f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n" for p in (self.apk, self.metadata_path)),
            encoding="utf-8")

    def sign(self, sequence=None, output=None):
        if output:
            self.args.output = self.directory / output
        self.args.sequence = sequence
        with redirect_stdout(io.StringIO()):
            updates.sign(self.args)
        return json.loads(base64.b64decode(json.loads(self.args.output.read_text(encoding="utf-8"))["payload"]))

    def recorded(self):
        return [entry["sequence"] for entry in
                json.loads(self.ledger.read_text(encoding="utf-8"))["channels"]["beta"]]

    def test_signs_exact_domain_separated_bytes_and_never_replaces_key_or_feed(self):
        data = self.sign(sequence=1)
        envelope = json.loads(self.args.output.read_text(encoding="utf-8"))
        payload = base64.b64decode(envelope["payload"])
        self.assertEqual(data["sequence"], 1)
        self.assertEqual(data["platforms"]["android-arm64"]["sha256"], hashlib.sha256(self.apk.read_bytes()).hexdigest())
        message = self.directory / "message"
        message.write_bytes(updates.DOMAIN + payload)
        signature = self.directory / "signature"
        signature.write_bytes(base64.b64decode(envelope["signature"]))
        public = self.directory / "public.der"
        public.write_bytes(updates.PUBLIC_DER_PREFIX + base64.b64decode(self.config["ARVEIL_UPDATE_PUBLIC_KEY"]))
        updates.openssl("openssl", "pkeyutl", "-verify", "-rawin", "-pubin", "-keyform", "DER",
                        "-inkey", str(public), "-in", str(message), "-sigfile", str(signature))
        feed = self.args.output.read_bytes()
        with self.assertRaisesRegex(ValueError, "output file already exists"):
            self.sign()
        self.assertEqual(self.args.output.read_bytes(), feed)
        self.assertEqual(self.recorded(), [1])
        self.assertEqual(self.key.stat().st_mode & 0o077, 0)

    def mac_package(self, **changes):
        """A packaged macOS build next to the Android one."""
        directory = self.directory / "mac-package"
        directory.mkdir(exist_ok=True)
        archive = directory / "arveil-0.1.0-18-macos-arm64.zip"
        archive.write_bytes(b"a macos packaging fixture")
        metadata = directory / "BUILD.json"
        metadata.write_text(json.dumps({
            "dirty_source": False, "platform": "macos", "architecture": "arm64",
            "update_config": self.config, "version": "0.1.0", "build": 18, "minimum_os": "12.0",
            **changes}), encoding="utf-8")
        (directory / "SHA256SUMS.txt").write_text("".join(
            f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n" for p in (archive, metadata)),
            encoding="utf-8")
        self.args.macos_package = directory
        self.args.macos_asset_url = (
            f"https://github.com/example/arveil/releases/download/clients-v0.1.0-beta.1/{archive.name}")
        return archive

    def test_announces_the_mac_build_beside_the_android_one(self):
        archive = self.mac_package()
        data = self.sign(sequence=1)
        mac = data["platforms"]["macos-arm64"]
        self.assertEqual(mac["build"], 18)
        self.assertEqual(mac["minimum_os"], "12.0")
        self.assertEqual(mac["sha256"], hashlib.sha256(archive.read_bytes()).hexdigest())
        self.assertEqual(mac["url"], self.args.macos_asset_url)
        self.assertEqual(mac["notes"], data["platforms"]["android-arm64"]["notes"])

    def test_refuses_a_mac_build_that_does_not_match(self):
        for changes, message in [({"build": 19}, "same version and build"),
                                 ({"update_config": {}}, "exact update distribution"),
                                 ({"dirty_source": True}, "clean, packaged macos"),
                                 ({"minimum_os": "twelve"}, "minimum macOS")]:
            with self.subTest(changes=changes):
                self.mac_package(**changes)
                with self.assertRaisesRegex(ValueError, message):
                    self.sign(sequence=1)
        self.mac_package()
        self.args.macos_asset_url = "https://example.org/arveil.zip"
        with self.assertRaisesRegex(ValueError, "release asset URL"):
            self.sign(sequence=1)
        self.args.macos_asset_url = None
        with self.assertRaisesRegex(ValueError, "together"):
            self.sign(sequence=1)
        self.assertFalse(self.ledger.exists(), "nothing was recorded")

    def test_init_key_encrypts_the_key_and_never_replaces_it(self):
        pem = self.key.read_bytes()
        self.assertTrue(pem.startswith(updates.ENCRYPTED_KEY + b"\n"))
        self.assertNotIn(b"BEGIN PRIVATE KEY", pem)
        self.assertEqual(self.key.stat().st_mode & 0o777, 0o600)
        with self.assertRaises(ValueError) as failure:
            updates.init_key(SimpleNamespace(openssl="openssl", key=self.key, passphrase_fd=None))
        self.assertEqual(str(failure.exception), updates.KEY_EXISTS)
        self.assertEqual(self.key.read_bytes(), pem)

    def test_init_key_requires_a_confirmed_long_passphrase_from_a_terminal(self):
        key = self.directory / "other" / "key.pem"
        args = SimpleNamespace(openssl="openssl", key=key, passphrase_fd=None)
        self.prompt.side_effect = [PASSPHRASE, PASSPHRASE + "!"]
        with self.assertRaisesRegex(ValueError, "passphrases differ"):
            updates.init_key(args)
        self.prompt.side_effect = None
        self.prompt.return_value = "too short"
        with self.assertRaisesRegex(ValueError, "at least 12"):
            updates.init_key(args)

        def echoing_fallback(prompt):  # What getpass does without a terminal.
            warnings.warn("Can not control echo on the terminal.", getpass.GetPassWarning)
            return PASSPHRASE
        self.prompt.side_effect = echoing_fallback
        with self.assertRaisesRegex(ValueError, "terminal"):
            updates.init_key(args)
        self.assertFalse(key.exists())

    def test_wrong_passphrase_signs_nothing(self):
        self.prompt.return_value = PASSPHRASE + "?"
        with self.assertRaisesRegex(ValueError, "passphrase"):
            self.sign(sequence=1)
        self.assertFalse(self.args.output.exists())
        self.assertFalse(self.ledger.exists())

    def test_passphrase_from_an_inherited_descriptor(self):
        prompts = self.prompt.call_count  # setUp's init_key asked twice.
        key = self.directory / "automation" / "key.pem"
        with redirect_stdout(io.StringIO()):
            updates.init_key(SimpleNamespace(openssl="openssl", key=key, passphrase_fd=passphrase_fd()))
        self.assertTrue(key.read_bytes().startswith(updates.ENCRYPTED_KEY))
        updates.public_key("openssl", key, PASSPHRASE.encode())
        self.args.passphrase_fd = passphrase_fd()
        self.assertEqual(self.sign(sequence=1)["sequence"], 1)
        self.assertEqual(self.prompt.call_count, prompts)
        read, write = os.pipe()
        with open(write, "wb") as pipe:
            pipe.write(b"\xff" * 20 + b"\n")
        with self.assertRaises(ValueError) as failure:
            updates.read_passphrase(SimpleNamespace(passphrase_fd=read))
        self.assertEqual(str(failure.exception), "The passphrase must be UTF-8 text.")

    def test_command_line_takes_the_passphrase_from_a_descriptor_and_explains_an_existing_key(self):
        key = self.directory / "cli" / "key.pem"
        script = Path(updates.__file__)
        for attempt in range(2):
            read = passphrase_fd()
            try:
                result = subprocess.run([sys.executable, str(script), "init-key", "--key", str(key),
                                         "--passphrase-fd", str(read)], pass_fds=(read,),
                                        capture_output=True, text=True, check=False)
            finally:
                os.close(read)
            self.assertNotIn(PASSPHRASE, result.stdout + result.stderr)
            if attempt == 0:
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("Public key (safe to distribute): " +
                              updates.public_key("openssl", key, PASSPHRASE.encode()), result.stdout)
            else:
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stderr.strip(), updates.KEY_EXISTS)

    def test_plaintext_key_still_signs_and_can_be_encrypted(self):
        plain = self.directory / "legacy" / "key.pem"
        updates.private_output(plain, updates.openssl("openssl", "genpkey", "-algorithm", "ED25519"))
        self.config["ARVEIL_UPDATE_PUBLIC_KEY"] = updates.public_key("openssl", plain)
        self.config_path.write_text(json.dumps(self.config), encoding="utf-8")
        self.metadata["update_config"] = self.config
        self.write_metadata()
        self.args.key = plain
        warning = io.StringIO()
        with redirect_stderr(warning):
            self.assertEqual(self.sign(sequence=1)["sequence"], 1)
        self.assertIn("not passphrase-protected", warning.getvalue())
        protected = plain.with_name("encrypted.pem")
        with redirect_stdout(io.StringIO()):
            updates.encrypt_key(SimpleNamespace(openssl="openssl", key=plain, output=protected, passphrase_fd=None))
        self.assertTrue(protected.read_bytes().startswith(updates.ENCRYPTED_KEY))
        self.assertEqual(protected.stat().st_mode & 0o777, 0o600)
        with self.assertRaisesRegex(ValueError, "already exists"):
            updates.encrypt_key(SimpleNamespace(openssl="openssl", key=plain, output=protected, passphrase_fd=None))
        with self.assertRaisesRegex(ValueError, "already passphrase-protected"):
            updates.encrypt_key(SimpleNamespace(openssl="openssl", key=protected, output=plain.with_name("x.pem"),
                                                passphrase_fd=None))
        # The encrypted copy is the same key and shares the ledger beside it.
        self.args.key = protected
        self.assertEqual(self.sign(output="clients-2.json")["sequence"], 2)

    def test_ledger_needs_one_explicit_sequence_then_proposes_the_next(self):
        with self.assertRaisesRegex(ValueError, "--sequence"):
            self.sign()
        self.assertFalse(self.ledger.exists())
        # Seeding: announcements signed before the ledger existed ended at 4.
        self.assertEqual(self.sign(sequence=5)["sequence"], 5)
        self.assertEqual(self.ledger.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.sign(output="clients-2.json")["sequence"], 6)
        self.assertEqual(self.recorded(), [5, 6])
        entry = json.loads(self.ledger.read_text(encoding="utf-8"))["channels"]["beta"][-1]
        self.assertEqual(entry["manifest_sha256"], hashlib.sha256(self.args.output.read_bytes()).hexdigest())
        self.assertEqual((entry["version"], entry["build"]), ("0.1.0", 18))
        self.assertEqual([p.name for p in self.ledger.parent.iterdir() if p.name.startswith(".")], [])

    def test_ledger_refuses_reuse_or_rollback_and_changes_nothing(self):
        self.sign(sequence=3)
        ledger = self.ledger.read_bytes()
        for sequence in (3, 2, 0, -1, updates.MAX_SEQUENCE + 1):
            with self.subTest(sequence=sequence), self.assertRaisesRegex(ValueError, "higher than 3"):
                self.sign(sequence=sequence, output="clients-2.json")
        self.assertFalse(self.args.output.exists())
        self.assertEqual(self.ledger.read_bytes(), ledger)
        self.assertEqual(self.sign(sequence=10)["sequence"], 10)

    def test_channels_keep_separate_sequences(self):
        self.ledger.write_text(json.dumps({"schema": 1, "channels": {"stable": [{"sequence": 9}]}}), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "No beta announcement"):
            self.sign()
        self.assertEqual(self.sign(sequence=1)["sequence"], 1)
        ledger = json.loads(self.ledger.read_text(encoding="utf-8"))
        self.assertEqual(ledger["channels"]["stable"], [{"sequence": 9}])
        self.assertEqual(self.recorded(), [1])

    def test_malformed_ledger_fails_closed_and_is_never_reset(self):
        entry = {"sequence": 1}
        for content in (b"", b"{", b"\xff", b"[]", json.dumps({"schema": 2, "channels": {}}).encode(),
                        json.dumps({"schema": True, "channels": {}}).encode(),
                        json.dumps({"schema": 1, "channels": {"nightly": [entry]}}).encode(),
                        json.dumps({"schema": 1, "channels": {"beta": []}}).encode(),
                        json.dumps({"schema": 1, "channels": {"beta": [entry, entry]}}).encode(),
                        json.dumps({"schema": 1, "channels": {"beta": [{"sequence": True}]}}).encode(),
                        json.dumps({"schema": 1, "channels": {"beta": [{"sequence": "2"}]}}).encode(),
                        json.dumps({"schema": 1, "channels": {"beta": [entry]}, "extra": 1}).encode()):
            self.ledger.write_bytes(content)
            for sequence in (None, 5):
                with self.subTest(content=content, sequence=sequence), self.assertRaises(ValueError) as failure:
                    self.sign(sequence=sequence)
                self.assertEqual(str(failure.exception), updates.LEDGER_MALFORMED)
            self.assertEqual(self.ledger.read_bytes(), content)
        self.assertFalse(self.args.output.exists())

    def test_rejects_modified_artifact_or_metadata(self):
        self.apk.write_bytes(b"modified")
        with self.assertRaises(ValueError): self.sign(sequence=1)
        self.write_metadata()
        self.metadata["dirty_source"] = True
        self.write_metadata()
        with self.assertRaises(ValueError): self.sign(sequence=1)
        self.assertFalse(self.ledger.exists())

    def test_rejects_build_metadata_that_is_not_an_object_or_mistyped(self):
        for text in ("[]", '"android"', "18", "null"):
            self.write_metadata(text)
            with self.subTest(text=text), self.assertRaisesRegex(ValueError, "JSON object"):
                self.sign(sequence=1)
        for field, value in (("build", "18"), ("build", True), ("minimum_sdk", 24.0), ("version", 1),
                             ("application_id", ["io.example.app"]), ("certificate_sha256", None)):
            self.metadata = dict(self.valid_metadata(), **{field: value})
            self.write_metadata()
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                self.sign(sequence=1)
        self.assertFalse(self.ledger.exists())

    def test_rejects_an_unrelated_key_or_build_distribution(self):
        self.config["ARVEIL_UPDATE_PUBLIC_KEY"] = base64.b64encode(bytes(32)).decode()
        self.config_path.write_text(json.dumps(self.config), encoding="utf-8")
        with self.assertRaises(ValueError): self.sign(sequence=1)
        self.assertFalse(self.ledger.exists())
        for config in ([], "beta", {"ARVEIL_UPDATE_URL": 1, "ARVEIL_UPDATE_PUBLIC_KEY": "",
                                   "ARVEIL_UPDATE_CHANNEL": "beta"}):
            self.config_path.write_text(json.dumps(config), encoding="utf-8")
            with self.subTest(config=config), self.assertRaisesRegex(ValueError, "three documented"):
                updates.read_config(self.config_path)

    def test_rejects_mutable_downloads_private_operator_fields_and_unsafe_urls(self):
        for url in ("http://example.org/feed", "https://user:password@example.org/feed", "https://example.org/feed#token"):
            with self.assertRaises(ValueError): updates.https_url(url)
        self.args.asset_url = "https://github.com/example/arveil/releases/latest/download/app.apk"
        with self.assertRaises(ValueError): self.sign(sequence=1)
        self.config["relay_url"] = "wss://relay.example.org/v1/channel"
        self.config_path.write_text(json.dumps(self.config), encoding="utf-8")
        with self.assertRaises(ValueError): updates.read_config(self.config_path)

    def test_refuses_insecure_key_permissions_and_unbounded_expiry(self):
        self.key.chmod(0o644)
        with self.assertRaises(ValueError): self.sign(sequence=1)
        self.key.chmod(0o600); self.args.valid_days = 365
        with self.assertRaises(ValueError): self.sign(sequence=1)
        self.assertFalse(self.args.output.exists())
        self.assertFalse(self.ledger.exists())


if __name__ == "__main__":
    unittest.main()
