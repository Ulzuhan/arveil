"""Exercise a v0.2.0 relay upgrade and rollback with disposable CLI profiles."""
import argparse
from contextlib import contextmanager
from pathlib import Path
import shutil
import socket
import sqlite3
import subprocess
import tempfile
import time


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(binary, *arguments):
    # Commands may return invite tokens or routes. Keep output out of CI logs.
    result = subprocess.run([binary, *arguments], capture_output=True, text=True, timeout=60)
    require(result.returncode == 0, f"{binary.name} {arguments[0]} exited {result.returncode}")
    return result.stdout


def field(output, name):
    return next(line.removeprefix(name) for line in output.splitlines() if line.startswith(name))


@contextmanager
def running(binary, realm, port, scratch):
    with (scratch / "relay.out").open("w") as stdout:
        process = subprocess.Popen([binary, "-data-dir", realm, "-listen", f"127.0.0.1:{port}"],
                                   stdout=stdout, stderr=subprocess.DEVNULL)
    try:
        for _ in range(100):
            require(process.poll() is None, f"{binary.name} exited before publishing its bootstrap")
            output = (scratch / "relay.out").read_text()
            if "bootstrap: " in output:
                break
            time.sleep(0.1)
        yield field(output, "bootstrap: ")
    finally:
        if process.poll() is None:
            process.terminate()
        process.wait(timeout=10)


def schema(realm):
    with sqlite3.connect((realm / "realm.db").as_uri() + "?mode=ro", uri=True) as db:
        return db.execute("SELECT MAX(version) FROM schema_migrations").fetchone()[0]


def exercise(old, new, legacy, cli, scratch):
    realm, alice, bob = (scratch / name for name in ("realm", "alice", "bob"))
    backup = scratch / "before.tar.gz"
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]

    with running(old, realm, port, scratch) as bootstrap:
        require(schema(realm) == 5, "expected the published schema 5 relay")
        for profile in (alice, bob):
            token = field(run(old, "invite", "-data-dir", realm), "invite: ")
            enrolled = run(legacy, "enroll", "--data-dir", profile, bootstrap, token)
        bob_route = field(enrolled, "route: ")
        run(legacy, "chat", "start", "--data-dir", alice, bootstrap, bob_route)
        run(legacy, "chat", "sync", "--data-dir", bob, bootstrap)
        run(legacy, "chat", "send", "--data-dir", alice, bootstrap, "before upgrade")
        run(old, "backup", "-data-dir", realm, "-out", backup)
    # Preserve the pre-upgrade receiving cursor and MLS state for the restore drill.
    rollback_bob = scratch / "rollback-bob"
    shutil.copytree(bob, rollback_bob)

    with running(new, realm, port, scratch) as upgraded:
        require(schema(realm) == 7 and upgraded == bootstrap, "migration changed realm or wrong schema")
        out = run(legacy, "chat", "sync", "--data-dir", bob, bootstrap)
        require(out.count("message: before upgrade") == 1, "legacy cursor lost the queued message")
        require("message: before upgrade" not in run(legacy, "chat", "sync", "--data-dir", bob, bootstrap),
                "message redelivered after cursor advance")
        run(legacy, "chat", "send", "--data-dir", bob, bootstrap, "after upgrade")
        # Subscribe with a nonempty mailbox. ADR-014 promises an initial notice in that case.
        out = run(cli, "watch", "--data-dir", alice, bootstrap, "1")
        require("watch: activity 1" in out, "watch-only session missed queued mail")
        require("message: after upgrade" in run(cli, "chat", "sync", "--data-dir", alice, bootstrap),
                "current client missed the legacy reply")
        run(cli, "chat", "send", "--data-dir", alice, bootstrap, "current to legacy")
        require("message: current to legacy" in run(legacy, "chat", "sync", "--data-dir", bob, bootstrap),
                "legacy client missed the current reply")

    restored = scratch / "restored"
    run(old, "restore", "-data-dir", restored, "-in", backup)
    secrets = Path("server-secrets")
    for name in ("realm-signing.key", "realm-noise.key"):
        require((realm / secrets / name).read_bytes() == (restored / secrets / name).read_bytes(),
                "restored realm key differs")
    counter = secrets / "endpoint-sequence"
    high = max(int((path / counter).read_text()) for path in (realm, restored))
    (restored / counter).write_text(f"{high}\n")
    with running(old, restored, port, scratch) as rolled_back:
        require(schema(restored) == 5 and rolled_back == bootstrap, "restored realm mismatch")
        require(int((restored / counter).read_text()) > high, "endpoint list sequence rolled back")
        out = run(legacy, "chat", "sync", "--data-dir", rollback_bob, bootstrap)
        require("message: before upgrade" in out and "message: current to legacy" not in out,
                "restored queue differs from the backup")
    print("PASS: schema 5 to 7, queued message and cursor, duplex chat, watch notice, schema 5 restore")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ("old-relay", "new-relay", "old-cli", "new-cli"):
        parser.add_argument("--" + option, type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="arveil-relay-upgrade-") as directory:
        exercise(args.old_relay.resolve(), args.new_relay.resolve(), args.old_cli.resolve(),
                 args.new_cli.resolve(), Path(directory))
