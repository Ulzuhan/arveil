from contextlib import redirect_stdout
import base64
import hashlib
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

import client_updates as updates


class SigningTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.key = self.directory / "key.pem"
        with redirect_stdout(io.StringIO()):
            updates.init_key(SimpleNamespace(openssl="openssl", key=self.key))
        self.config = {"ARVEIL_UPDATE_URL": "https://updates.example.org/clients.json",
                       "ARVEIL_UPDATE_PUBLIC_KEY": updates.public_key("openssl", self.key),
                       "ARVEIL_UPDATE_CHANNEL": "beta"}
        self.config_path = self.directory / "config.json"
        self.config_path.write_text(json.dumps(self.config))
        self.apk = self.directory / "arveil-0.1.0-18-android-arm64.apk"
        self.apk.write_bytes(b"a packaging fixture")
        self.metadata = {"dirty_source": False, "platform": "android", "architecture": "arm64",
                         "update_config": self.config, "certificate_sha256": "a" * 64,
                         "version": "0.1.0", "build": 18, "minimum_sdk": 24,
                         "application_id": "io.github.ulzuhan.arveil"}
        self.metadata_path = self.directory / "BUILD.json"
        self.metadata_path.write_text(json.dumps(self.metadata))
        self.sums()
        self.notes = self.directory / "notes.txt"
        self.notes.write_text("An update.\nActualización.")
        self.args = SimpleNamespace(openssl="openssl", key=self.key, config=self.config_path,
            package=self.directory, sequence=1, valid_days=30, notes=self.notes,
            asset_url=f"https://github.com/example/arveil/releases/download/clients-v0.1.0-beta.1/{self.apk.name}",
            notes_url="https://github.com/example/arveil/releases/tag/clients-v0.1.0-beta.1",
            output=self.directory / "clients.json")

    def sums(self):
        (self.directory / "SHA256SUMS.txt").write_text("".join(
            f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n" for p in (self.apk, self.metadata_path)))

    def sign(self):
        with redirect_stdout(io.StringIO()):
            updates.sign(self.args)

    def test_signs_exact_domain_separated_bytes_and_never_replaces_key_or_feed(self):
        self.sign()
        envelope = json.loads(self.args.output.read_text())
        payload = base64.b64decode(envelope["payload"])
        data = json.loads(payload)
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
        with self.assertRaises(FileExistsError): self.sign()
        with self.assertRaises(FileExistsError):
            updates.init_key(SimpleNamespace(openssl="openssl", key=self.key))
        self.assertEqual(self.key.stat().st_mode & 0o077, 0)

    def test_rejects_modified_artifact_or_metadata(self):
        self.apk.write_bytes(b"modified")
        with self.assertRaises(ValueError): self.sign()
        self.sums()
        self.metadata["dirty_source"] = True
        self.metadata_path.write_text(json.dumps(self.metadata)); self.sums()
        with self.assertRaises(ValueError): self.sign()

    def test_rejects_an_unrelated_key_or_build_distribution(self):
        self.config["ARVEIL_UPDATE_PUBLIC_KEY"] = base64.b64encode(bytes(32)).decode()
        self.config_path.write_text(json.dumps(self.config))
        with self.assertRaises(ValueError): self.sign()

    def test_rejects_mutable_downloads_private_operator_fields_and_unsafe_urls(self):
        for url in ("http://example.org/feed", "https://user:password@example.org/feed", "https://example.org/feed#token"):
            with self.assertRaises(ValueError): updates.https_url(url)
        self.args.asset_url = "https://github.com/example/arveil/releases/latest/download/app.apk"
        with self.assertRaises(ValueError): self.sign()
        self.config["relay_url"] = "wss://relay.example.org/v1/channel"
        self.config_path.write_text(json.dumps(self.config))
        with self.assertRaises(ValueError): updates.read_config(self.config_path)

    def test_refuses_insecure_key_permissions_and_unbounded_expiry(self):
        self.key.chmod(0o644)
        with self.assertRaises(ValueError): self.sign()
        self.key.chmod(0o600); self.args.valid_days = 365
        with self.assertRaises(ValueError): self.sign()
        self.assertFalse(self.args.output.exists())


if __name__ == "__main__":
    unittest.main()
