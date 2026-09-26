"""Regression checks for publication boundaries; no platform toolchain required."""

import importlib.util
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import zipfile

SPEC = importlib.util.spec_from_file_location("package_clients", Path(__file__).with_name("package_clients.py"))
package = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(package)

# The lines of `aapt2 dump badging` that the release checks read.
BADGING = """package: name='io.github.ulzuhan.arveil' versionCode='18' versionName='0.1.0' platformBuildVersionName='15' platformBuildVersionCode='35' compileSdkVersion='35' compileSdkVersionCodename='15'
sdkVersion:'24'
targetSdkVersion:'35'
uses-permission: name='android.permission.INTERNET'
application-label:'Arveil'
native-code: 'arm64-v8a'
"""
INSTALLER = "uses-permission: name='android.permission.REQUEST_INSTALL_PACKAGES'\n"


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

    def test_apk_badging_must_match_the_build_and_its_update_feed(self):
        facts = {"minimum_sdk": 24, "application_id": "io.github.ulzuhan.arveil"}
        self.assertEqual(package.android_details(BADGING, 18, updates=False), facts)
        self.assertEqual(package.android_details(BADGING + INSTALLER, 18, updates=True), facts)
        # The installer permission comes only with an update feed, and always with one.
        with self.assertRaisesRegex(ValueError, "with an update feed must request"):
            package.android_details(BADGING, 18, updates=True)
        with self.assertRaisesRegex(ValueError, "without an update feed must not request"):
            package.android_details(BADGING + INSTALLER, 18, updates=False)
        # The updater announces BUILD.json's build; Android compares versionCode.
        with self.assertRaisesRegex(ValueError, "versionCode differs"):
            package.android_details(BADGING, 19, updates=False)
        with self.assertRaisesRegex(ValueError, "versionCode differs"):
            package.android_details(BADGING.replace(" versionCode='18'", ""), 18, updates=False)
        with self.assertRaisesRegex(ValueError, "package name"):
            package.android_details(BADGING.replace("package: name='io.github.ulzuhan.arveil' ", "package: "),
                                    18, updates=False)
        with self.assertRaisesRegex(ValueError, "minimum SDK"):
            package.android_details(BADGING.replace("sdkVersion:'24'\n", ""), 18, updates=False)
        with self.assertRaisesRegex(ValueError, "debuggable"):
            package.android_details(BADGING + "application-debuggable\n", 18, updates=False)

    def test_apk_native_code_must_be_arm64_only(self):
        # clients-v0.1.0-beta.1 carried a plugin library for two ABIs without
        # libflutter.so; Android installed it there and it crashed at launch.
        arm64 = "native-code: 'arm64-v8a'\n"
        for native in ("native-code: 'arm64-v8a' 'armeabi-v7a' 'x86_64'\n", "native-code: 'armeabi-v7a'\n",
                       "native-code: 'x86_64' 'arm64-v8a'\n", "native-code: 'arm64-v8a' \n",
                       arm64 + "alt-native-code: 'armeabi-v7a'\n", arm64 + arm64, ""):
            with self.subTest(native=native), self.assertRaisesRegex(ValueError, "arm64-v8a only"):
                package.android_details(BADGING.replace(arm64, native), 18, updates=False)

    def test_update_configuration_is_refused_for_macos_before_building(self):
        args = SimpleNamespace(platform="macos", update_config=Path("distribution.json"), allow_dirty=False,
                               build_number=None, flutter="flutter", signing_config=None)
        with patch.object(package, "run") as run, patch.object(package, "read_config") as read_config:
            with self.assertRaisesRegex(ValueError, "only to Android"):
                package.package(args)
        run.assert_not_called()
        read_config.assert_not_called()

    def test_signing_configuration_must_be_private(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "signing.json"
            store = Path(directory) / "release.keystore"
            store.write_bytes(b"test fixture")
            store.chmod(0o600)
            config.write_text(json.dumps({"keystore": str(store), "store_password": "fixture",
                                          "key_alias": "fixture", "key_password": "fixture"}), encoding="utf-8")
            config.chmod(0o644)
            with self.assertRaises(ValueError):
                package.signing_environment(config)
            config.chmod(0o600)
            env = package.signing_environment(config)
            self.assertEqual(env["ARVEIL_ANDROID_KEYSTORE"], str(store.resolve()))
            config.write_text("[]", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "JSON object"):
                package.signing_environment(config)

    def test_build_does_not_inherit_private_test_configuration(self):
        with patch.dict(os.environ, {"DART_DEFINES": "private-input", "ARVEIL_TEST_INVITE": "private-input",
                                     "FLUTTER_XCODE_DART_DEFINES": "private-input"}):
            env = package.build_environment(Path(tempfile.gettempdir()) / "neutral-source")
            self.assertNotIn("DART_DEFINES", env)
            self.assertNotIn("ARVEIL_TEST_INVITE", env)
            self.assertNotIn("FLUTTER_XCODE_DART_DEFINES", env)


if __name__ == "__main__":
    unittest.main()
