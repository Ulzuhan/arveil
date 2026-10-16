#!/usr/bin/env python3
"""Android activity-notice acceptance against a disposable relay (ADR-014).

Starts a loopback relay with fresh synthetic identities, registers a watch key
for one of them with the CLI, and runs WatchServiceTest on a connected emulator
or device, which reaches the host relay as 10.0.2.2 (an emulator) or through
`adb reverse` (--reverse, for a phone on USB). The test checks the subscription,
the generic notice when the other identity writes, and that the service stops
once the key is removed. It does not establish Doze, battery or network-change
behaviour on a physical phone.

Build first: the relay and CLI binaries, and the debug app and test APKs:
  (cd clients/flutter && flutter build apk --debug --target-platform android-arm64)
  (cd clients/flutter/android && ./gradlew app:assembleDebugAndroidTest -Ptarget-platform=android-arm64)
The credentials passed to the device contain a private key: they stay in memory
and in the disposable relay, never in logs or files.
"""
import argparse
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "clients/flutter/build/app/outputs/flutter-apk/app-debug.apk"
TEST = ROOT / "clients/flutter/build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk"
PACKAGE = "io.github.ulzuhan.arveil"


def free_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def stop(process):
    if process is not None and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cli", type=Path, default=ROOT / "core/target/debug/arveil")
    parser.add_argument("--relay", type=Path, default=ROOT / "relay/bin/arveil-relay")
    parser.add_argument("--adb", default=shutil.which("adb") or str(Path.home() / "Library/Android/sdk/platform-tools/adb"))
    parser.add_argument("--reverse", action="store_true", help="a phone on USB: adb reverse instead of 10.0.2.2")
    args = parser.parse_args()
    for path in (args.cli, args.relay, APP, TEST):
        if not path.is_file():
            parser.error(f"missing {path}; see the build steps above")
    adb = [args.adb]

    with tempfile.TemporaryDirectory(prefix="arveil-android-watch-") as temporary:
        directory = Path(temporary)
        port = free_port()
        relay = instrument = logcat = None
        credentials = ""

        def report():
            if instrument is not None:
                stop(instrument)
                output = instrument.stdout.read() if instrument.stdout else ""
                print(output.replace(credentials, "<credentials>") if credentials else output)
        try:
            relay = subprocess.Popen(
                [str(args.relay), "-data-dir", str(directory / "realm"), "-listen", f"127.0.0.1:{port}",
                 "-sweep-interval", "1s"],
                stdout=(directory / "relay.out").open("w"), stderr=subprocess.DEVNULL)
            for _ in range(100):
                text = (directory / "relay.out").read_text()
                if "bootstrap: " in text:
                    break
                time.sleep(0.1)
            else:
                raise RuntimeError("relay did not start")
            bootstrap = next(line.removeprefix("bootstrap: ") for line in text.splitlines()
                             if line.startswith("bootstrap: "))

            def cli(who, *arguments):
                result = subprocess.run([str(args.cli), *arguments[:1], "--data-dir", str(directory / who), *arguments[1:]],
                                        capture_output=True, text=True, timeout=60)
                if result.returncode:
                    raise RuntimeError(f"CLI {arguments[0]} failed")
                return result.stdout

            def invite():
                out = subprocess.run([str(args.relay), "invite", "-data-dir", str(directory / "realm")],
                                     capture_output=True, text=True, check=True).stdout
                return next(line.removeprefix("invite: ") for line in out.splitlines() if line.startswith("invite: "))

            alice = cli("alice", "enroll", bootstrap, invite())
            cli("bob", "enroll", bootstrap, invite())
            route = next(line.removeprefix("route: ") for line in alice.splitlines() if line.startswith("route: "))
            if args.reverse:
                subprocess.run(adb + ["reverse", f"tcp:{port}", f"tcp:{port}"], check=True)
                url = f"ws://127.0.0.1:{port}/v1/channel"
            else:
                url = f"ws://10.0.2.2:{port}/v1/channel"
            out = subprocess.run([str(args.cli), "watch", "credentials", "--data-dir", str(directory / "alice"),
                                  bootstrap, url], capture_output=True, text=True, timeout=60)
            if out.returncode:
                raise RuntimeError("watch credentials failed")
            credentials = next(line.removeprefix("credentials: ") for line in out.stdout.splitlines()
                               if line.startswith("credentials: "))

            for apk in (APP, TEST):
                subprocess.run(adb + ["install", "-r", "-t", str(apk)], check=True, capture_output=True)
            subprocess.run(adb + ["logcat", "-c"], check=True)
            logcat = subprocess.Popen(adb + ["logcat", "-s", "ArveilWatchTest:I", "-v", "raw"],
                                      stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
            seen = []
            threading.Thread(target=lambda: [seen.append(line.strip()) for line in logcat.stdout], daemon=True).start()
            instrument = subprocess.Popen(
                adb + ["shell", "am", "instrument", "-w", "-e", "credentials", credentials,
                       "-e", "class", f"{PACKAGE}.WatchServiceTest",
                       f"{PACKAGE}.test/androidx.test.runner.AndroidJUnitRunner"],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

            def wait_for(marker, seconds):
                deadline = time.monotonic() + seconds
                while marker not in seen:
                    if time.monotonic() > deadline or instrument.poll() is not None:
                        report()
                        raise RuntimeError(f"the device never reported '{marker}'")
                    time.sleep(0.2)
                print(f"device: {marker}", flush=True)

            wait_for("listening", 60)
            cli("bob", "send", bootstrap, route, "hola")
            wait_for("notified", 90)
            cli("alice", "watch", "clear", bootstrap)
            wait_for("refused", 90)
            output, _ = instrument.communicate(timeout=60)
            logcat.terminate()
            if "OK (1 test)" not in output:
                print(output.replace(credentials, "<credentials>"))
                raise RuntimeError("WatchServiceTest did not pass")
            print("PASS: subscribed, generic notice on new mail, stopped once the key was removed.")
        finally:
            stop(instrument)
            stop(logcat)
            stop(relay)
            if args.reverse:
                subprocess.run(adb + ["reverse", "--remove", f"tcp:{port}"], capture_output=True)


if __name__ == "__main__":
    main()
