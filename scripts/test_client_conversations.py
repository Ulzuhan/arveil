#!/usr/bin/env python3
"""Native conversation acceptance using an isolated relay, identities and keys.

Put the pinned Flutter SDK (and adb for an emulator) on PATH, then run:
python3 scripts/test_client_conversations.py --device macos
Only macOS or a disposable Android emulator is accepted. Failed diagnostics stay
in ignored .local/client-acceptance/. Integration builds are cleaned afterwards.
"""
import argparse
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import secrets
import shutil
import socket
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
    adb = shutil.which("adb") if args.device != "macos" else None
    if not flutter:
        parser.error("Put the pinned Flutter SDK on PATH.")
    if args.device != "macos" and (not args.device.startswith("emulator-") or not args.device[9:].isdigit() or not adb):
        parser.error("Use macos or a disposable Android emulator with adb on PATH.")
    with tempfile.TemporaryDirectory(prefix="arveil-chat-acceptance-") as temporary:
        directory = Path(temporary)
        binary, realm = directory / "relay", directory / "realm"
        with (directory / "build.log").open("w") as log:
            subprocess.run(["go", "build", "-o", str(binary), "./cmd/arveil-relay"], cwd=ROOT / "relay", stdout=log, stderr=log, check=True)
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        relay = None
        control = None
        worker = None
        reversed_ports = []
        lock = threading.Lock()
        with (directory / "relay.log").open("w+") as output:
            def stop():
                nonlocal relay
                if relay is not None:
                    relay.terminate()
                    relay.wait(timeout=10)
                    relay = None

            def start():
                nonlocal relay
                if relay is not None:
                    return
                relay = subprocess.Popen([str(binary), "-data-dir", str(realm), "-listen", f"127.0.0.1:{port}"], stdout=output, stderr=output)
                for _ in range(100):
                    if relay.poll() is not None:
                        raise RuntimeError("Disposable relay failed to start.")
                    try:
                        with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                            return
                    except OSError:
                        time.sleep(0.1)
                raise RuntimeError("Disposable relay startup timed out.")

            try:
                start()
                output.seek(0)
                bootstrap = next(line.removeprefix("bootstrap: ").strip() for line in output if line.startswith("bootstrap: "))
                invites = []
                for _ in range(2):
                    result = subprocess.check_output([str(binary), "invite", "-data-dir", str(realm)], text=True)
                    invites.append(next(line.removeprefix("invite: ") for line in result.splitlines() if line.startswith("invite: ")))
                token = secrets.token_hex(32)

                class Control(BaseHTTPRequestHandler):
                    def log_message(self, *_):
                        pass

                    def do_POST(self):
                        if not hmac.compare_digest(self.headers.get("Authorization", ""), f"Bearer {token}"):
                            self.send_error(403)
                            return
                        if self.path not in ("/online", "/offline"):
                            self.send_error(404)
                            return
                        with lock:
                            try:
                                (start if self.path == "/online" else stop)()
                            except (OSError, subprocess.SubprocessError, RuntimeError):
                                self.send_error(500)
                                return
                        self.send_response(200)
                        self.send_header("Content-Length", "0")
                        self.end_headers()

                control = ThreadingHTTPServer(("127.0.0.1", 0), Control)
                control_port = control.server_address[1]
                worker = threading.Thread(target=control.serve_forever)
                worker.start()
                config = directory / "defines.json"
                config.write_text(json.dumps({"ARVEIL_TEST_BOOTSTRAP": bootstrap, "ARVEIL_TEST_INVITE_A": invites[0], "ARVEIL_TEST_INVITE_B": invites[1], "ARVEIL_TEST_CONTROL": f"http://127.0.0.1:{control_port}", "ARVEIL_TEST_CONTROL_TOKEN": token}))
                config.chmod(0o600)
                if adb:
                    for number in (port, control_port):
                        subprocess.run([adb, "-s", args.device, "reverse", f"tcp:{number}", f"tcp:{number}"], check=True, stdout=subprocess.DEVNULL)
                        reversed_ports.append(number)
                print("Running native conversation acceptance with a disposable relay.", flush=True)
                with (directory / "flutter.log").open("w") as log:
                    try:
                        result = subprocess.run([flutter, "test", "integration_test/conversations_test.dart", "-d", args.device, "--dart-define-from-file", str(config)], cwd=ROOT / "clients/flutter", stdout=log, stderr=log, timeout=1200)
                        failed = result.returncode != 0
                    except subprocess.TimeoutExpired:
                        failed = True
                if failed:
                    logs = ROOT / ".local/client-acceptance"
                    logs.mkdir(parents=True, exist_ok=True, mode=0o700)
                    logs.chmod(0o700)
                    destination = logs / f"conversations-{time.time_ns()}.log"
                    shutil.copyfile(directory / "flutter.log", destination)
                    destination.chmod(0o600)
                    raise RuntimeError("Native conversation acceptance failed. Private diagnostics retained in .local/client-acceptance/.")
                print("PASS: saved contacts, explicit verification, rename, verified group, duplex text, offline queue, encrypted reopen, pagination, reconnect without duplicates.")
            finally:
                if control:
                    control.shutdown()
                    control.server_close()
                if worker:
                    worker.join(timeout=10)
                stop()
                for number in reversed_ports:
                    subprocess.run([adb, "-s", args.device, "reverse", "--remove", f"tcp:{number}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                subprocess.run([flutter, "clean"], cwd=ROOT / "clients/flutter", stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120, check=True)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.SubprocessError, OSError, StopIteration) as error:
        raise SystemExit(str(error) if isinstance(error, RuntimeError) else "Acceptance command failed.") from None
