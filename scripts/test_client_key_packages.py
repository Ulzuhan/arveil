#!/usr/bin/env python3
"""Exercise the native KeyPackage GUI against a disposable local relay only.

Run from any directory: python3 scripts/test_client_key_packages.py --device macos
For an Android emulator, use its adb serial. No production host is accepted.
Test credentials stay in a private temporary directory; failed Flutter logs are
retained in ignored .local/client-acceptance/ with private permissions. The
Flutter build is cleaned afterwards; never distribute an integration-test build.
"""
import argparse
import json
from pathlib import Path
import shutil
import socket
import sqlite3
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", default="macos")
    args = parser.parse_args()
    flutter = shutil.which("flutter")
    if not flutter:
        parser.error("Put the pinned Flutter SDK on PATH.")
    adb = None
    if args.device != "macos":
        if not args.device.startswith("emulator-") or not args.device[9:].isdigit():
            parser.error("Use macos or a disposable Android emulator serial.")
        adb = shutil.which("adb")
        if not adb:
            parser.error("Put Android platform-tools on PATH.")
    with tempfile.TemporaryDirectory(prefix="arveil-key-package-acceptance-") as temporary:
        directory = Path(temporary)
        realm = directory / "realm"
        binary = directory / "arveil-relay"
        with (directory / "build.log").open("w") as output:
            subprocess.run(["go", "build", "-o", str(binary), "./cmd/arveil-relay"], cwd=ROOT / "relay", stdout=output, stderr=output, check=True)
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        stopped = threading.Event()
        exhausted = threading.Event()
        errors = []
        worker = None
        with (directory / "relay.log").open("w+") as output:
            relay = subprocess.Popen([str(binary), "-data-dir", str(realm), "-listen", f"127.0.0.1:{port}"], stdout=output, stderr=output)
            try:
                bootstrap = None
                for _ in range(100):
                    output.seek(0)
                    bootstrap = next((line.removeprefix("bootstrap: ").strip() for line in output if line.startswith("bootstrap: ")), None)
                    if bootstrap:
                        break
                    if relay.poll() is not None:
                        raise RuntimeError("Disposable relay stopped during startup.")
                    time.sleep(0.1)
                if not bootstrap:
                    raise RuntimeError("Disposable relay did not start.")
                invitation = subprocess.check_output([str(binary), "invite", "-data-dir", str(realm)], text=True)
                token = next(line.removeprefix("invite: ") for line in invitation.splitlines() if line.startswith("invite: "))
                config = directory / "defines.json"
                config.write_text(json.dumps({"ARVEIL_TEST_BOOTSTRAP": bootstrap, "ARVEIL_TEST_INVITE": token}))
                config.chmod(0o600)
                if adb:
                    subprocess.run([adb, "-s", args.device, "reverse", f"tcp:{port}", f"tcp:{port}"], check=True, stdout=subprocess.DEVNULL)

                def consume_initial():
                    try:
                        while not stopped.wait(0.1):
                            # This DB belongs only to the relay created above.
                            with sqlite3.connect(realm / "realm.db", timeout=10) as conn:
                                count = conn.execute("SELECT count(*) FROM key_packages").fetchone()[0]
                                if count == 5:
                                    conn.execute("UPDATE key_packages SET consumed = 1")
                                    exhausted.set()
                                    return
                    except Exception:
                        errors.append("Unable to exhaust the disposable initial batch.")

                worker = threading.Thread(target=consume_initial)
                worker.start()
                # Keep diagnostics local: native failures may include private
                # paths, bootstrap data or test keys in assertions.
                with (directory / "flutter.log").open("w") as log:
                    print("Running native KeyPackage acceptance against a disposable relay.", flush=True)
                    try:
                        result = subprocess.run([flutter, "test", "integration_test/key_packages_test.dart", "-d", args.device, "--dart-define-from-file", str(config)], cwd=ROOT / "clients/flutter", stdout=log, stderr=log, timeout=1200)
                        failed = result.returncode != 0
                    except subprocess.TimeoutExpired:
                        failed = True
                if failed or errors or not exhausted.is_set():
                    logs = ROOT / ".local" / "client-acceptance"
                    logs.mkdir(parents=True, exist_ok=True, mode=0o700)
                    logs.chmod(0o700)
                    destination = logs / f"key-packages-{time.time_ns()}.log"
                    shutil.copyfile(directory / "flutter.log", destination)
                    destination.chmod(0o600)
                    print("Private diagnostic log retained under .local/client-acceptance/.")
                    raise RuntimeError("Native KeyPackage acceptance failed; reproduce locally with a disposable fixture.")
                with sqlite3.connect(realm / "realm.db") as conn:
                    total, consumed = conn.execute("SELECT count(*), sum(consumed) FROM key_packages").fetchone()
                if (total, consumed) != (15, 5):
                    raise RuntimeError("Unexpected package count: replenishment duplicated or revived keys.")
                print("PASS: GUI exhaustion, replenishment, reopen; 15 total / 5 consumed / 10 available.")
            finally:
                stopped.set()
                if worker:
                    worker.join(timeout=15)
                relay.terminate()
                relay.wait(timeout=10)
                if adb:
                    subprocess.run([adb, "-s", args.device, "reverse", "--remove", f"tcp:{port}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                subprocess.run([flutter, "clean"], cwd=ROOT / "clients/flutter", stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120, check=True)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.SubprocessError, OSError, sqlite3.Error) as error:
        # Do not echo failed argv, which may include private fixture paths.
        raise SystemExit(str(error) if isinstance(error, RuntimeError) else "Acceptance command failed.") from None
