"""Regression checks for publication boundaries; no platform toolchain required."""

import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

SPEC = importlib.util.spec_from_file_location("package_clients", Path(__file__).with_name("package_clients.py"))
package = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(package)


class PublicationTests(unittest.TestCase):
    def test_checks_decompressed_binary_contents_without_disclosing_matches(self):
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / "client.apk"
            private = "/" + "/".join(("Users", "private-test-user", "checkout", "file.dart"))
            with zipfile.ZipFile(apk, "w", zipfile.ZIP_DEFLATED) as archive:
                archive.writestr("lib/arm64-v8a/libapp.so", b"\0" + private.encode() + b"\0")
            with self.assertRaises(ValueError) as failure:
                package.audit_archive(apk)
            self.assertIn("libapp.so", str(failure.exception))
            self.assertNotIn("private-test-user", str(failure.exception))

    def test_blocks_accidental_enrollment_test_build(self):
        with self.assertRaises(ValueError):
            package.audit_bytes(b"binary\0ARVEIL_TEST_INVITE\0", "libapp.so")
        package.audit_bytes(b"binary\0package:arveil/main.dart\0", "libapp.so")

    def test_signing_configuration_must_be_private(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "signing.json"
            store = Path(directory) / "release.keystore"
            store.write_bytes(b"test fixture")
            store.chmod(0o600)
            config.write_text(json.dumps({"keystore": str(store), "store_password": "fixture",
                                          "key_alias": "fixture", "key_password": "fixture"}))
            config.chmod(0o644)
            with self.assertRaises(ValueError):
                package.signing_environment(config)
            config.chmod(0o600)
            env = package.signing_environment(config)
            self.assertEqual(env["ARVEIL_ANDROID_KEYSTORE"], str(store.resolve()))

    def test_build_does_not_inherit_private_test_configuration(self):
        with patch.dict(os.environ, {"DART_DEFINES": "private-input", "ARVEIL_TEST_INVITE": "private-input",
                                     "FLUTTER_XCODE_DART_DEFINES": "private-input"}):
            env = package.build_environment(Path(tempfile.gettempdir()) / "neutral-source")
            self.assertNotIn("DART_DEFINES", env)
            self.assertNotIn("ARVEIL_TEST_INVITE", env)
            self.assertNotIn("FLUTTER_XCODE_DART_DEFINES", env)


if __name__ == "__main__":
    unittest.main()
