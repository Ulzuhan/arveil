"""Exercise the CLI/relay publisher against an isolated fake release store."""

import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


PUBLISHER = Path(__file__).with_name("publish_binaries.sh").resolve()
BINARIES = (
    "arveil-linux-x86_64", "arveil-relay-linux-x86_64",
    "arveil-macos-aarch64", "arveil-relay-macos-aarch64",
)


class ReleasePublicationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.dist = root / "dist"
        self.remote = root / "release"
        self.bin = root / "bin"
        for directory in (self.dist, self.remote, self.bin):
            directory.mkdir()
        for name in BINARIES:
            (self.dist / name).write_bytes(name.encode())
        for target in ("linux-x86_64", "macos-aarch64"):
            (self.dist / f"SHA256SUMS-{target}.txt").write_text("".join(
                self.checksum(name) for name in BINARIES if name.endswith(target)))
        # A client manifest and package may already exist in the release.
        self.clients = {"SHA256SUMS-clients.txt": b"client checksums\n",
                        "arveil-client.apk": b"signed client fixture"}
        for name, contents in self.clients.items():
            (self.remote / name).write_bytes(contents)
        gh = self.bin / "gh"
        gh.write_text("""#!/usr/bin/env python3
import os
from pathlib import Path
import shutil
import sys

args = sys.argv[1:]
assert args[:3] == ['release', 'upload', 'v1.0.0-test']
assert args[-2:] == ['--repo', 'example/project']
files = args[3:-2]
clobber = '--clobber' in files
files = [Path(name) for name in files if name != '--clobber']
remote = Path(os.environ['TEST_RELEASE_STORE'])
if not clobber and any((remote / path.name).exists() for path in files):
    sys.exit(1)
for path in files:
    shutil.copyfile(path, remote / path.name)
""")
        gh.chmod(0o700)
        self.env = dict(os.environ, PATH=f"{self.bin}{os.pathsep}{os.environ['PATH']}",
                        GITHUB_REF="refs/tags/v1.0.0-test",
                        GITHUB_REPOSITORY="example/project",
                        TEST_RELEASE_STORE=str(self.remote))

    def checksum(self, name):
        digest = hashlib.sha256((self.dist / name).read_bytes()).hexdigest()
        return f"{digest}  {name}\n"

    def publish(self):
        return subprocess.run(["bash", str(PUBLISHER), str(self.dist)],
                              env=self.env, capture_output=True, text=True)

    def snapshot(self):
        return {p.name: p.read_bytes() for p in self.remote.iterdir()}

    def test_upload_preserves_clients_and_excludes_unrelated_files(self):
        # Broad globs previously mixed manifests and uploaded every local file.
        (self.dist / "SHA256SUMS-clients.txt").write_text("unrelated manifest\n")
        (self.dist / "private-build.log").write_text("not a release asset\n")
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = dict(self.clients)
        expected.update({name: (self.dist / name).read_bytes() for name in BINARIES})
        expected["SHA256SUMS-cli-relay.txt"] = "".join(
            self.checksum(name) for name in BINARIES).encode()
        self.assertEqual(self.snapshot(), expected)

    def test_rerun_cannot_replace_already_uploaded_binaries(self):
        self.assertEqual(self.publish().returncode, 0)
        before = self.snapshot()
        name = BINARIES[0]
        (self.dist / name).write_bytes(b"different rebuild")
        (self.dist / "SHA256SUMS-linux-x86_64.txt").write_text("".join(
            self.checksum(name) for name in BINARIES if name.endswith("linux-x86_64")))
        self.assertNotEqual(self.publish().returncode, 0)
        self.assertEqual(self.snapshot(), before)

    def test_corrupt_or_missing_build_artifact_uploads_nothing(self):
        for damage in ("corrupt", "missing"):
            with self.subTest(damage=damage):
                artifact = self.dist / BINARIES[0]
                if damage == "corrupt":
                    artifact.write_bytes(b"corrupt transfer")
                else:
                    artifact.unlink()
                self.assertNotEqual(self.publish().returncode, 0)
                self.assertEqual(self.snapshot(), self.clients)

    def test_client_tag_and_branch_cannot_publish_cli_assets(self):
        for ref in ("refs/tags/clients-v1.0.0-test", "refs/heads/main", ""):
            with self.subTest(ref=ref):
                self.env["GITHUB_REF"] = ref
                self.assertNotEqual(self.publish().returncode, 0)
                self.assertEqual(self.snapshot(), self.clients)


if __name__ == "__main__":
    unittest.main()
