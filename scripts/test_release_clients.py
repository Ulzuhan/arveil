"""Checks for the two-command client release helper, without GitHub or hosts."""
import base64
import contextlib
import hashlib
import http.server
import io
import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch

import release_clients as release

REVISION = "a" * 40
DISTRIBUTION = {"ARVEIL_UPDATE_URL": "https://updates.example/clients-beta.json",
                "ARVEIL_UPDATE_PUBLIC_KEY": "fixture", "ARVEIL_UPDATE_CHANNEL": "beta"}
REPO = "owner/arveil"
TAG = "clients-v0.1.0-beta.3"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def package(root, platform, suffix, *, build=21, revision=REVISION, data=None):
    """A packaged build directory as package_clients.py leaves it."""
    directory = root / "dist/clients" / f"0.1.0+{build}" / platform
    directory.mkdir(parents=True)
    artifact = directory / f"arveil-0.1.0-{build}-{platform}-arm64{suffix}"
    artifact.write_bytes(data or f"{platform} package".encode())
    info = {"platform": platform, "revision": revision, "build": build, "dirty_source": False,
            "update_config": DISTRIBUTION, "version": "0.1.0", "certificate_sha256": "c" * 64}
    (directory / "BUILD.json").write_text(json.dumps(info))
    sums = "".join(f"{digest(f.read_bytes())}  {f.name}\n" for f in (artifact, directory / "BUILD.json"))
    (directory / "SHA256SUMS.txt").write_text(sums)
    return directory


def feed(platforms):
    payload = json.dumps({"schema": 1, "channel": "beta", "sequence": 5, "platforms": platforms}).encode()
    return json.dumps({"schema": 1, "payload": base64.b64encode(payload).decode(), "signature": "x"})


class ReleaseClientsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for name, value in (("ROOT", self.root), ("RELEASES", self.root / ".local/releases")):
            patcher = patch.object(release, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        (self.root / ".local/releases").mkdir(parents=True)

    def packages(self):
        return {platform: release.check_package(package(self.root, platform, suffix), platform, suffix,
                                                REVISION, 21, DISTRIBUTION)
                for platform, suffix in release.PLATFORMS}

    def test_tags_name_the_version_and_its_label(self):
        self.assertEqual(release.parse_tag("clients-v0.1.0-beta.3"), ("0.1.0", "0.1.0 beta 3"))
        self.assertEqual(release.parse_tag("clients-v1.2.0"), ("1.2.0", "1.2.0"))
        for bad in ("v0.1.0", "clients-v0.1", "clients-v0.1.0-beta", "clients-v0.1.0-beta.3/x"):
            with self.subTest(bad=bad), self.assertRaises(release.ReleaseError):
                release.parse_tag(bad)

    def test_config_resolves_local_paths_and_checks_the_site(self):
        path = self.root / "release.json"
        path.write_text(json.dumps({
            "signing_config": ".local/signing/android-signing.json",
            "update_config": ".local/distribution.json", "update_key": "/keys/update.pem",
            "web": {"repo": ".local/repos/web", "site": "https://arveil.example"},
            "tap": {"repo": ".local/repos/tap", "cask": "Casks/arveil.rb"}}))
        config = release.load_config(path)
        self.assertEqual(config["update_config"], self.root / ".local/distribution.json")
        self.assertEqual(config["update_key"], Path("/keys/update.pem"))
        self.assertEqual(config["web"]["repo"], self.root / ".local/repos/web")
        for web in ({"repo": "w", "site": "http://arveil.example"}, {"repo": "w", "site": "https://a.example/x"},
                    {"repo": "w", "site": "https://a.example", "ssh": "host"}):
            path.write_text(json.dumps({"signing_config": "s", "update_config": "u", "update_key": "k", "web": web}))
            with self.subTest(web=web), self.assertRaises(release.ReleaseError):
                release.load_config(path)

    def test_only_packages_built_for_this_release_are_used(self):
        packages = self.packages()
        self.assertEqual(packages["android"][0].suffix, ".apk")
        cases = {"revision": dict(revision="b" * 40), "build": dict(build=22)}
        for field, change in cases.items():
            with self.subTest(field=field), tempfile.TemporaryDirectory() as other:
                directory = package(Path(other), "android", ".apk", **change)
                with self.assertRaisesRegex(release.ReleaseError, field):
                    release.check_package(directory, "android", ".apk", REVISION, 21, DISTRIBUTION)
        # A package changed after packaging no longer matches its checksums.
        packages["android"][0].write_bytes(b"tampered")
        with self.assertRaisesRegex(release.ReleaseError, "checksums"):
            release.check_package(packages["android"][0].parent, "android", ".apk", REVISION, 21, DISTRIBUTION)

    def test_staging_is_repeatable_and_refuses_other_files(self):
        packages = self.packages()
        first = release.stage(TAG, packages)
        names = sorted(f.name for f in first)
        self.assertEqual(names, sorted(["arveil-0.1.0-21-android-arm64.apk", "arveil-0.1.0-21-macos-arm64.zip",
                                        "BUILD-android.json", "BUILD-macos.json", "SHA256SUMS-clients.txt"]))
        manifest = (self.root / ".local/releases" / TAG / "SHA256SUMS-clients.txt").read_text()
        self.assertEqual(len(manifest.splitlines()), 4)
        self.assertEqual(release.stage(TAG, packages), first)
        (self.root / ".local/releases" / TAG / "BUILD-macos.json").write_text("{}")
        with self.assertRaisesRegex(release.ReleaseError, "move it aside"):
            release.stage(TAG, packages)

    def test_notes_start_as_templates_and_must_lose_every_todo(self):
        packages = self.packages()
        with self.assertRaisesRegex(release.ReleaseError, "TODO"):
            release.notes(TAG, "0.1.0 beta 3", "0.1.0", REVISION, 21, packages["android"][1])
        github = self.root / ".local/releases" / f"{TAG}-notes.md"
        app = self.root / ".local/releases" / f"{TAG}-app-notes.txt"
        self.assertIn(REVISION, github.read_text())
        self.assertIn("c" * 64, github.read_text())
        github.write_text("# Arveil 0.1.0 beta 3\n")
        with self.assertRaisesRegex(release.ReleaseError, "TODO"):
            release.notes(TAG, "0.1.0 beta 3", "0.1.0", REVISION, 21, packages["android"][1])
        app.write_text("Arveil 0.1.0 beta 3.\n")
        self.assertEqual(release.notes(TAG, "0.1.0 beta 3", "0.1.0", REVISION, 21, packages["android"][1]), (github, app))

    def test_an_existing_announcement_is_reused_only_for_these_packages(self):
        packages = self.packages()
        directory = self.root / ".local/releases" / f"{TAG}-feed"
        directory.mkdir()
        entry = {f"{p}-arm64": {"build": 21, "sha256": release.sha256(packages[p][0])} for p, _ in release.PLATFORMS}
        (directory / "clients-beta-5.json").write_text(feed(entry))
        self.assertEqual(release.announcement(directory, "beta", 21, packages), directory / "clients-beta-5.json")
        self.assertIsNone(release.announcement(directory, "beta", 22, packages))
        entry["macos-arm64"]["sha256"] = "0" * 64
        (directory / "clients-beta-5.json").write_text(feed(entry))
        with self.assertRaisesRegex(release.ReleaseError, "other packages"):
            release.announcement(directory, "beta", 21, packages)

    def test_signing_uses_the_next_sequence_and_never_a_lower_build(self):
        packages = self.packages()
        key = self.root / ".local/update-signing/update.pem"
        key.parent.mkdir(parents=True)
        config = {"update_key": key, "update_config": self.root / "distribution.json"}
        notes = self.root / "notes.txt"
        ledger = key.parent / "sequences.json"
        with self.assertRaisesRegex(release.ReleaseError, "ledger"):
            release.sign(config, "beta", TAG, REPO, packages, notes, 21)
        ledger.write_text(json.dumps({"schema": 1, "channels": {"beta": [
            {"sequence": 3, "build": 19}, {"sequence": 4, "build": 22}]}}))
        with self.assertRaisesRegex(release.ReleaseError, "lower"):
            release.sign(config, "beta", TAG, REPO, packages, notes, 21)
        ledger.write_text(json.dumps({"schema": 1, "channels": {"beta": [
            {"sequence": 3, "build": 19}, {"sequence": 4, "build": 20}]}}))

        def signer(command, capture):
            self.assertFalse(capture, "the passphrase prompt needs the terminal")
            output = Path(command[command.index("--output") + 1])
            output.write_text("{}")
        with patch.object(release, "run", side_effect=signer) as run:
            output = release.sign(config, "beta", TAG, REPO, packages, notes, 21)
        command = run.call_args.args[0]
        self.assertEqual(output.name, "clients-beta-5.json")
        self.assertEqual(command[command.index("--sequence") + 1], "5")
        self.assertEqual(command[command.index("--asset-url") + 1],
                         f"https://github.com/{REPO}/releases/download/{TAG}/arveil-0.1.0-21-android-arm64.apk")
        self.assertEqual(command[command.index("--notes-url") + 1], f"https://github.com/{REPO}/releases/tag/{TAG}")

    def test_the_revision_must_be_on_main(self):
        answers = {("git", "rev-parse", "HEAD"): "h" * 40 + "\n",
                   ("git", "rev-parse", "--verify"): REVISION + "\n"}

        def git(command, **_):
            if command[:3] == ["git", "merge-base", "--is-ancestor"]:
                if command[3] != REVISION:
                    raise release.ReleaseError("git merge-base --is-ancestor failed.")
                return ""
            return answers.get(tuple(command[:3]), "")
        with patch.object(release, "run", side_effect=git) as run:
            self.assertEqual(release.release_revision(REVISION), (REVISION, "h" * 40))
        self.assertIn(["git", "rev-parse", "--verify", f"{REVISION}^{{commit}}"], [c.args[0] for c in run.call_args_list])
        answers[("git", "rev-parse", "--verify")] = "b" * 40 + "\n"
        with patch.object(release, "run", side_effect=git), \
                self.assertRaisesRegex(release.ReleaseError, "origin/main"):
            release.release_revision("b" * 40)

    def test_release_assets_must_match_byte_for_byte(self):
        files = release.stage(TAG, self.packages())
        remote = {"assets": [{"name": f.name, "digest": "sha256:" + release.sha256(f)} for f in files]}
        self.assertTrue(release.assets_match(remote, files))
        self.assertFalse(release.assets_match({"assets": remote["assets"][:-1]}, files))
        remote["assets"][0]["digest"] = "sha256:" + "0" * 64
        self.assertFalse(release.assets_match(remote, files))

    def test_the_cask_gets_the_new_version_and_digest(self):
        cask = 'cask "arveil" do\n  version "0.1.0-beta.2,20"\n  sha256 "' + "7" * 64 + '"\n\n  url "x"\nend\n'
        updated = release.cask_text(cask, "0.1.0-beta.3", 21, "9" * 64)
        self.assertIn('  version "0.1.0-beta.3,21"\n', updated)
        self.assertIn('  sha256 "' + "9" * 64 + '"\n', updated)
        self.assertEqual(updated.count("\n"), cask.count("\n"))
        with self.assertRaises(release.ReleaseError):
            release.cask_text('cask "arveil" do\nend\n', "0.1.0-beta.3", 21, "9" * 64)

    def test_the_live_site_must_serve_this_announcement_and_links(self):
        packages = self.packages()
        announced = self.root / "clients-beta-5.json"
        announced.write_text(feed({}))
        base = f"https://github.com/{REPO}/releases"
        routes = {"/updates/clients-beta.json": (200, announced.read_bytes()),
                  "/download/android": (302, f"{base}/download/{TAG}/arveil-0.1.0-21-android-arm64.apk"),
                  "/download/macos": (302, f"{base}/download/{TAG}/arveil-0.1.0-21-macos-arm64.zip"),
                  "/download/notes": (302, f"{base}/tag/{TAG}")}

        class Site(http.server.BaseHTTPRequestHandler):
            def reply(self):
                status, value = routes.get(self.path, (404, b""))
                self.send_response(status)
                if status == 302:
                    self.send_header("Location", value)
                    value = b""
                self.send_header("Content-Length", str(len(value)))
                self.end_headers()
                if self.command == "GET":
                    self.wfile.write(value)
            do_GET = do_HEAD = reply

            def log_message(self, *args):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Site)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.shutdown)
        site = f"http://127.0.0.1:{server.server_address[1]}"
        with contextlib.redirect_stdout(io.StringIO()):
            release.check_live(site, "beta", announced, REPO, TAG, packages)
        routes["/download/macos"] = (302, f"{base}/download/clients-v0.1.0-beta.2/old.zip")
        with self.assertRaisesRegex(release.ReleaseError, "macos"):
            release.check_live(site, "beta", announced, REPO, TAG, packages)
        routes["/updates/clients-beta.json"] = (200, b"older")
        with self.assertRaisesRegex(release.ReleaseError, "announcement"):
            release.check_live(site, "beta", announced, REPO, TAG, packages)


if __name__ == "__main__":
    unittest.main()
