#!/usr/bin/env python3
"""Disposable relay -> ntfy UnifiedPush endpoint acceptance, without FCM.

Requires a server-capable ntfy binary and the built Arveil CLI. Starts loopback
servers with fresh configuration, synthetic identities and private temporary
storage. It does not register a phone or establish Android/Doze reliability.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import tempfile
import time
from urllib.request import ProxyHandler, build_opener
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]


def port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def wait_ready(process, number):
    for _ in range(100):
        if process.poll() is not None:
            raise RuntimeError("Disposable service exited during startup.")
        try:
            with socket.create_connection(("127.0.0.1", number), timeout=0.1):
                return
        except OSError:
            time.sleep(0.1)
    raise RuntimeError("Disposable service did not become ready.")


def stop(process):
    if process is not None and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    server = parser.add_mutually_exclusive_group(required=True)
    server.add_argument("--ntfy", type=Path, help="Server-capable ntfy executable; also tests restart/outage")
    server.add_argument("--ntfy-url", help="Disposable server forwarded to http://127.0.0.1:PORT (no restart test)")
    parser.add_argument("--cli", type=Path, default=ROOT / "core/target/debug/arveil")
    args = parser.parse_args()
    ntfy_binary, cli = args.ntfy.resolve() if args.ntfy else None, args.cli.resolve()
    if (ntfy_binary is not None and not ntfy_binary.is_file()) or not cli.is_file() or not shutil.which("go"):
        parser.error("Build the CLI and supply ntfy; Go is needed for the disposable relay.")
    if args.ntfy_url:
        parsed = urlsplit(args.ntfy_url)
        if (parsed.scheme != "http" or parsed.hostname != "127.0.0.1" or parsed.port is None
                or parsed.username or parsed.password or parsed.path not in ("", "/")
                or parsed.query or parsed.fragment):
            parser.error("Forward a disposable server to http://127.0.0.1:PORT first.")
    os.umask(0o077)
    with tempfile.TemporaryDirectory(prefix="arveil-ntfy-acceptance-") as temporary:
        directory = Path(temporary)
        relay_binary, realm = directory / "relay", directory / "realm"
        ntfy_port, relay_port = parsed.port if args.ntfy_url else port(), port()
        while relay_port == ntfy_port:
            relay_port = port()
        base = f"http://127.0.0.1:{ntfy_port}"
        # Capabilities are random and never printed or retained after the run.
        # ntfy topic names are limited to 64 characters.
        topic = "up" + secrets.token_hex(24)
        endpoint = f"{base}/{topic}?up=1"
        config = directory / "ntfy.yml"
        config.write_text(
            f'base-url: "{base}"\nlisten-http: "127.0.0.1:{ntfy_port}"\n'
            f'cache-file: {json.dumps(str(directory / "cache.db"))}\n'
            'cache-duration: "15m"\nauth-default-access: "read-write"\n'
            'firebase-key-file: ""\nupstream-base-url: ""\n'
            'web-root: "disable"\nlog-level: "error"\n'
        )
        environment = {k: v for k, v in os.environ.items() if not k.startswith("NTFY_")}
        # Avoid routing synthetic capability URLs through a machine's proxy.
        http = build_opener(ProxyHandler({}))
        relay = ntfy = None
        with (directory / "diagnostics.log").open("w+") as log:
            def run(command):
                result = subprocess.run(command, stdout=subprocess.PIPE, stderr=log,
                                        text=True, timeout=60)
                if result.returncode:
                    log.write(result.stdout)
                    raise RuntimeError("Disposable CLI command failed; see private .local/ntfy-acceptance diagnostics.")
                return result.stdout

            def command(who, *arguments):
                return run([str(cli), *arguments[:2], "--data-dir", str(directory / who), *arguments[2:]])

            def messages():
                with http.open(f"{base}/{topic}/json?poll=1&since=all", timeout=5) as response:
                    data = response.read(65537)
                if len(data) > 65536:
                    raise RuntimeError("Unexpectedly large hint response.")
                rows = [json.loads(line) for line in data.splitlines()]
                rows = [row for row in rows if row.get("event") == "message"]
                for row in rows:
                    body = row.get("message", "")
                    if row.get("encoding") == "base64":
                        body = base64.b64decode(body, validate=True).decode("ascii")
                    if body != "arveil-hint/v1" or any(row.get(k) for k in ("title", "tags", "click", "attach", "attachment")):
                        raise RuntimeError("The delivery carried more than the generic marker.")
                return rows

            def expect_count(expected, quiet=False):
                if quiet:
                    # Wait out the relay's attempt window without exhausting
                    # ntfy's normal request-rate limit by polling for absence.
                    time.sleep(6)
                    if len(messages()) != expected:
                        raise RuntimeError("Unexpected hint count after the quiet interval.")
                    return
                deadline = time.monotonic() + 10
                while True:
                    count = len(messages())
                    if count > expected:
                        raise RuntimeError("Unexpected extra notification hint.")
                    if count == expected and not quiet:
                        return
                    if time.monotonic() >= deadline:
                        if count != expected:
                            raise RuntimeError("Expected hint was not delivered.")
                        return
                    time.sleep(0.5)

            def start_ntfy():
                process = subprocess.Popen([str(ntfy_binary), "serve", "--config", str(config)],
                                           env=environment, stdout=log, stderr=log)
                try:
                    wait_ready(process, ntfy_port)
                except RuntimeError:
                    stop(process)
                    raise
                return process

            try:
                subprocess.run(["go", "build", "-o", str(relay_binary), "./cmd/arveil-relay"],
                               cwd=ROOT / "relay", stdout=log, stderr=log, check=True, timeout=180)
                if ntfy_binary:
                    ntfy = start_ntfy()
                with (directory / "relay.log").open("w+") as relay_log:
                    relay = subprocess.Popen([str(relay_binary), "-data-dir", str(realm),
                                              "-listen", f"127.0.0.1:{relay_port}"],
                                             stdout=relay_log, stderr=relay_log)
                    wait_ready(relay, relay_port)
                    relay_log.seek(0)
                    bootstrap = next(line.removeprefix("bootstrap: ").strip()
                                     for line in relay_log if line.startswith("bootstrap: "))
                    enrolled = {}
                    for who in ("alice", "bob"):
                        invite_output = run([str(relay_binary), "invite", "-data-dir", str(realm)])
                        invite = next(line.removeprefix("invite: ") for line in invite_output.splitlines()
                                      if line.startswith("invite: "))
                        enrolled[who] = run([str(cli), "enroll", "--data-dir", str(directory / who), bootstrap, invite])
                    route = next(line.removeprefix("route: ") for line in enrolled["alice"].splitlines()
                                 if line.startswith("route: "))
                    command("bob", "chat", "start", bootstrap, route)
                    command("alice", "chat", "sync", bootstrap)
                    command("alice", "notify", "set", bootstrap, endpoint)
                    command("bob", "chat", "send", bootstrap, "synthetic first message")
                    expect_count(1)
                    command("bob", "chat", "send", bootstrap, "synthetic second message")
                    expect_count(1, quiet=True)
                    command("alice", "chat", "sync", bootstrap)
                    command("bob", "chat", "send", bootstrap, "synthetic after acknowledgement")
                    expect_count(2)

                    expected = 2
                    if ntfy_binary:
                        # A failed best-effort hint is not retried while mail remains.
                        command("alice", "chat", "sync", bootstrap)
                        stop(ntfy)
                        ntfy = None
                        command("bob", "chat", "send", bootstrap, "synthetic during outage")
                        time.sleep(6)  # exceeds the relay's five-second attempt timeout
                        ntfy = start_ntfy()
                        expect_count(2)
                        command("bob", "chat", "send", bootstrap, "synthetic mailbox still pending")
                        expect_count(2, quiet=True)
                        recovered = command("alice", "chat", "sync", bootstrap)
                        if "synthetic during outage" not in recovered or "synthetic mailbox still pending" not in recovered:
                            raise RuntimeError("Sync did not recover mail after the missed hint.")
                        command("bob", "chat", "send", bootstrap, "synthetic after recovery")
                        expected = 3
                        expect_count(expected)
                    command("alice", "notify", "clear", bootstrap)
                    command("alice", "chat", "sync", bootstrap)
                    command("bob", "chat", "send", bootstrap, "synthetic after disable")
                    expect_count(expected, quiet=True)
                print("PASS: generic UnifiedPush-format hints, coalescing and unregister.")
                print("PASS: restart and missed-hint catch-up." if ntfy_binary else "Restart/outage: not tested against an externally managed server.")
                print("Scope: loopback/forwarded ntfy; no Android receiver or Doze assertion.")
            except (OSError, subprocess.SubprocessError, StopIteration, ValueError, RuntimeError):
                logs = ROOT / ".local/ntfy-acceptance"
                logs.mkdir(parents=True, exist_ok=True, mode=0o700)
                log.flush()
                shutil.copyfile(directory / "diagnostics.log", logs / "last-failure.log")
                raise
            finally:
                stop(relay)
                stop(ntfy)


if __name__ == "__main__":
    try:
        main()
    except (OSError, subprocess.SubprocessError, StopIteration, ValueError, RuntimeError) as error:
        raise SystemExit(str(error) if isinstance(error, RuntimeError) else "Isolated ntfy acceptance failed.") from None
