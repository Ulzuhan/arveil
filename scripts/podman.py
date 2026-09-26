#!/usr/bin/env python3
"""Deploy a committed relay to rootless Podman, or exercise its staging service.

The staging test interrupts that service. Use only disposable client identities.
SSH handles authentication; no passwords or private keys are stored here.
"""
import argparse
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
# prepare_tunnel.py stamps the units it renders with this line. Such a unit
# publishes the relay on the backend port behind nginx, trusts the forwarded
# address and advertises the public endpoint; the stock unit deployed here
# would undo all three and take the relay down, so deploy never replaces one.
TUNNEL_MARKER = "# PRIVATE: rendered by scripts/prepare_tunnel.py"
TUNNEL_UPDATE = ("this relay runs behind the public tunnel: its unit was rendered by "
                 "scripts/prepare_tunnel.py. Build the image with --image-only, set that "
                 "revision in the operator configuration, render again with prepare_tunnel.py "
                 "and install the unit as docs/TUNNEL.md describes")


def tunnel_unit(text):
    """Whether a deployed Quadlet came from prepare_tunnel.py."""
    return any(line.startswith(TUNNEL_MARKER) for line in text.splitlines())


class CommandFailed(RuntimeError):
    """Do not include argv: enrollment arguments contain one-use credentials."""


def run(args, **kwargs):
    try:
        return subprocess.run(args, check=True, **kwargs)
    except subprocess.CalledProcessError as error:
        raise CommandFailed(f"{Path(args[0]).name} exited with status {error.returncode}") from None


class Remote:
    def __init__(self, args):
        self.ssh = ["ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
        if args.known_hosts:
            self.ssh += ["-o", "StrictHostKeyChecking=yes", "-o", f"UserKnownHostsFile={args.known_hosts}"]
        self.ssh.append(args.host)
        self.name = args.name

    def shell(self, command, *, capture=True, **kwargs):
        return run(self.ssh + [command], capture_output=capture, **kwargs)

    def command(self, *args):
        return self.shell(shlex.join(args), text=True).stdout.strip()

    def relay(self, *args):
        return self.command("podman", "exec", self.name, "/arveil-relay", *args)

    def healthy(self):
        for _ in range(60):
            try:
                self.relay("healthcheck", "-admin", "http://127.0.0.1:9090")
                return
            except CommandFailed:
                time.sleep(0.5)
        raise RuntimeError("relay did not become healthy; inspect its systemd journal")

    def bootstrap(self):
        # Only the public bootstrap line; never print invite tokens or routes.
        output = self.command("podman", "logs", self.name)
        return [line.removeprefix("bootstrap: ") for line in output.splitlines()
                if line.startswith("bootstrap: ")][-1]


def save_backup(remote, token):
    archive = f"/tmp/arveil-{token}.tar.gz"
    remote.relay("backup", "-data-dir", "/data", "-out", archive)
    home = remote.shell('printf "%s" "$HOME"', text=True).stdout
    directory = f"{home}/.local/share/arveil/backups"
    remote.command("mkdir", "-p", directory)
    remote.command("chmod", "700", directory)
    target = f"{directory}/{token}.tar.gz"
    remote.command("podman", "cp", f"{remote.name}:{archive}", target)
    remote.command("chmod", "600", target)
    return target


def deploy(args, remote):
    run(["git", "diff", "--exit-code", "HEAD", "--"], cwd=ROOT, stdout=subprocess.DEVNULL)
    revision = run(["git", "rev-parse", "--verify", "--end-of-options", f"{args.revision}^{{commit}}"],
                   cwd=ROOT, capture_output=True, text=True).stdout.strip()
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("expected a full Git commit")
    user = remote.command("id", "-un")
    if remote.command("loginctl", "show-user", user, "-p", "Linger", "--value") != "yes":
        raise RuntimeError("enable user lingering on the server before deploying")
    if remote.command("podman", "info", "--format", "{{.Host.Security.Rootless}}") != "true":
        raise RuntimeError("this deployment requires rootless Podman")
    if remote.command("tailscale", "ip", "-4") != args.address:
        raise RuntimeError("address does not match this server's Tailscale IPv4")
    serve = json.loads(remote.command("tailscale", "serve", "status", "--json"))
    port = str(args.port)
    forward = {"TCPForward": f"127.0.0.1:{args.port}"}
    if serve.get("TCP", {}).get(port) not in (None, forward):
        raise RuntimeError("Tailscale Serve already uses this port for another service")
    if any(enabled and target.endswith(":" + port)
           for target, enabled in serve.get("AllowFunnel", {}).items()):
        raise RuntimeError("the staging port must not be exposed through Funnel")
    image = f"localhost/arveil-relay:{revision}"
    home = remote.shell('printf "%s" "$HOME"', text=True).stdout
    directory = f"{home}/.config/containers/systemd"
    target = f"{directory}/{args.name}.container"
    # Decide before building anything, so a tunnelled realm is never touched.
    existing = remote.shell(f"cat -- {shlex.quote(target)} 2>/dev/null || true", text=True).stdout
    if tunnel_unit(existing) and not args.image_only:
        raise RuntimeError(TUNNEL_UPDATE)
    release = f"{home}/.local/share/arveil/releases/{revision}"
    remote.command("mkdir", "-p", release)
    archive = run(["git", "archive", revision, "relay"], cwd=ROOT, capture_output=True).stdout
    remote.shell(shlex.join(["tar", "-xf", "-", "-C", release]), input=archive)
    print(f"Building relay {revision} on the server (2 CPUs, 2 GiB build limit).", flush=True)
    remote.shell(shlex.join([
        "podman", "build", "--jobs=1", "--memory=2g", "--cpu-period=100000",
        "--cpu-quota=200000", "--label", f"org.opencontainers.image.revision={revision}",
        "--build-arg", f"REVISION={revision}", "-t", image,
        "-f", f"{release}/relay/Dockerfile", release,
    ]), capture=False)
    version = remote.command("podman", "run", "--rm", "--network=none", image, "-version")
    if revision not in version:
        raise RuntimeError("image reports the wrong revision")
    try:
        running = remote.command("podman", "inspect", "--format", "{{.State.Running}}", args.name)
    except CommandFailed:
        running = "false"
    if running == "true":
        backup = save_backup(remote, "before-deploy-" + uuid.uuid4().hex[:12])
        print(f"Pre-update backup: {backup}", flush=True)
    if args.image_only:
        print(version)
        print(f"Image ready, service unchanged: {image}")
        return
    template = run(["git", "show", f"{revision}:relay/packaging/arveil-staging.container.in"],
                   cwd=ROOT, capture_output=True, text=True).stdout
    for key, value in {"REVISION": revision, "IMAGE": image, "NAME": args.name,
                       "ADDRESS": args.address, "PORT": str(args.port)}.items():
        template = template.replace(f"@{key}@", value)
    remote.command("mkdir", "-p", directory)
    # Preserve the previous unit for review; data stays in its named volume.
    q = shlex.quote
    remote.shell(f"if [ -f {q(target)} ]; then cp {q(target)} {q(target + '.previous')}; fi\n"
                 f"umask 077\ncat > {q(target + '.new')}\nmv {q(target + '.new')} {q(target)}",
                 input=template.encode())
    remote.command("systemctl", "--user", "daemon-reload")
    remote.command("systemctl", "--user", "restart", f"{args.name}.service")
    remote.healthy()
    # Add only this port. Do not reset Serve or replace other services' routes.
    remote.command("tailscale", "serve", "--bg", "--yes", f"--tcp={args.port}",
                   f"tcp://127.0.0.1:{args.port}")
    updated = json.loads(remote.command("tailscale", "serve", "status", "--json"))
    for section in ("TCP", "Web", "AllowFunnel"):
        for key, value in serve.get(section, {}).items():
            if section != "TCP" or key != port:
                if updated.get(section, {}).get(key) != value:
                    raise RuntimeError("an unrelated Tailscale route changed")
    print(version)
    print(f"Active: {args.name}; ws://{args.address}:{args.port}/v1/channel")
    print(f"Data volume: {args.name}-data; unit: {target}")


def test_staging(args, remote):
    cli = ROOT / "core/target/debug/arveil"
    run(["cargo", "build", "--locked", "-p", "arveil-cli"], cwd=ROOT / "core")
    remote.healthy()
    bootstrap = remote.bootstrap()
    token = uuid.uuid4().hex[:12]
    service = f"{args.name}.service"
    restore_name = f"arveil-restore-{token}"
    restore_volume = restore_name + "-data"
    image = remote.command("podman", "inspect", "--format", "{{.ImageName}}", args.name)
    # Keep the backup off the live data volume after copying it out. The
    # temporary /tmp directory in this read-only container is writable.
    with tempfile.TemporaryDirectory(prefix="arveil-staging-") as directory:
        data = Path(directory)
        env = {key: value for key, value in os.environ.items() if not key.startswith("ARVEIL_")}
        env["ARVEIL_DB_KEY"] = "41" * 32  # disposable test profiles, never production keys

        def client(profile, *command):
            argv = [str(cli), *command[:2], "--data-dir", str(data / profile), *command[2:]]
            result = run(argv, env=env, capture_output=True, text=True)
            return result.stdout
        try:
            invites = {}
            routes = {}
            for person in ("alice", "bob"):
                invite = remote.relay("invite", "-data-dir", "/data").split("invite: ", 1)[1].splitlines()[0]
                invites[person] = invite
                # enroll has one command word; call it directly.
                output = run([str(cli), "enroll", "--data-dir", str(data / person), bootstrap, invite],
                             env=env, capture_output=True, text=True).stdout
                routes[person] = next(line[7:] for line in output.splitlines() if line.startswith("route: "))
            for _ in range(12):
                output = run([str(cli), "enroll", "--data-dir", str(data / "alice"), bootstrap, invites["alice"]],
                             env=env, capture_output=True, text=True).stdout
                assert routes["alice"] in output, "repeated enrollment changed the route"
            client("alice", "chat", "start", bootstrap, routes["bob"])
            client("bob", "chat", "sync", bootstrap)
            text = f"arveil-online-{token}"
            client("bob", "chat", "send", bootstrap, text)
            assert f"message: {text}" in client("alice", "chat", "sync", bootstrap)
            print("PASS: enrollment, twelve retries and encrypted conversation.", flush=True)

            remote.command("systemctl", "--user", "stop", service)
            offline = f"arveil-offline-{token}"
            queued = client("bob", "chat", "send", bootstrap, offline)
            assert "queued: relay unreachable" in queued
            assert offline in client("bob", "chat", "history")
            remote.command("systemctl", "--user", "start", service)
            remote.healthy()
            assert remote.bootstrap() == bootstrap, "restart changed realm identity"
            client("bob", "chat", "sync", bootstrap)
            assert f"message: {offline}" in client("alice", "chat", "sync", bootstrap)
            client("alice", "chat", "sync", bootstrap)
            assert client("alice", "chat", "history").count(offline) == 1
            print("PASS: offline send, restart, reconnect and no duplicate delivery.", flush=True)

            # Back up a queued message, then restore into an isolated volume.
            restored_message = f"arveil-restored-{token}"
            client("bob", "chat", "send", bootstrap, restored_message)
            saved_backup = save_backup(remote, token)
            # podman cp into a created container allows using the same image
            # without adding a shell or weakening the host's SELinux labels.
            remote.command("podman", "volume", "create", restore_volume)
            remote.command("podman", "create", "--name", restore_name, "--network=none",
                           "--volume", f"{restore_volume}:/data", image, "restore",
                           "-in", "/tmp/restore.tar.gz", "-data-dir", "/data")
            remote.command("podman", "cp", saved_backup, f"{restore_name}:/tmp/restore.tar.gz")
            remote.command("podman", "start", "-a", restore_name)
            assert remote.command("podman", "inspect", "--format", "{{.State.ExitCode}}", restore_name) == "0"
            remote.command("podman", "rm", restore_name)
            # Stop staging briefly so the restored realm can use its original
            # endpoint. No endpoints or trust pins are rewritten in clients.
            remote.command("systemctl", "--user", "stop", service)
            remote.command("podman", "run", "-d", "--name", restore_name,
                           "--memory=512m", "--cpus=1", "--read-only", "--cap-drop=ALL",
                           "--security-opt=no-new-privileges", "--volume", f"{restore_volume}:/data",
                           "--publish", f"127.0.0.1:{args.port}:8447", image,
                           "-data-dir=/data", "-listen=0.0.0.0:8447", "-admin-listen=127.0.0.1:9090",
                           f"-advertise=tailnet=ws://{args.address}:{args.port}/v1/channel")
            original_name = remote.name
            remote.name = restore_name
            try:
                remote.healthy()
                assert remote.bootstrap() == bootstrap
                assert f"message: {restored_message}" in client("alice", "chat", "sync", bootstrap)
            finally:
                remote.name = original_name
            print("PASS: backup restored into a separate volume; queued message decrypted.", flush=True)
            print(f"Backup retained with mode 0600: {saved_backup}")
        finally:
            # Never remove staging data. Only the uniquely named restore drill
            # container/volume are disposable. Always bring staging back up.
            for command in (("podman", "rm", "-f", restore_name),
                            ("podman", "volume", "rm", restore_volume)):
                try:
                    remote.command(*command)
                except CommandFailed:
                    pass
            remote.command("systemctl", "--user", "start", service)
            remote.healthy()
    print("Staging is running; temporary local client profiles removed.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("deploy", "test-staging"))
    parser.add_argument("--host", required=True, help="SSH alias or user@host")
    parser.add_argument("--address", required=True, help="server Tailscale IPv4")
    parser.add_argument("--port", type=int, default=8447)
    parser.add_argument("--name", default="arveil-staging")
    parser.add_argument("--revision", default="HEAD")
    parser.add_argument("--known-hosts", help="optional existing SSH known_hosts file")
    parser.add_argument("--image-only", action="store_true",
                        help="build and check the image without changing the running service")
    args = parser.parse_args()
    if args.host.startswith("-") or not re.fullmatch(r"[A-Za-z0-9_.@-]+", args.host):
        parser.error("use an SSH alias or user@host")
    if not re.fullmatch(r"arveil-staging(?:-[a-z0-9-]+)?", args.name):
        parser.error("service name must be arveil-staging or arveil-staging-<suffix>")
    if ipaddress.ip_address(args.address) not in ipaddress.ip_network("100.64.0.0/10"):
        parser.error("bind address must be a Tailscale IPv4 address")
    if not 1024 <= args.port <= 65535:
        parser.error("port must be between 1024 and 65535")
    remote = Remote(args)
    try:
        (deploy if args.action == "deploy" else test_staging)(args, remote)
    except (RuntimeError, AssertionError) as error:
        parser.exit(1, f"Failed: {error or 'acceptance assertion failed'}\n")


if __name__ == "__main__":
    main()
