import argparse
from pathlib import Path
import subprocess
import unittest
from unittest import mock

import podman
from prepare_tunnel import TAILNET_RANGE, render

ROOT = Path(__file__).resolve().parents[1]
REVISION = "0123456789abcdef0123456789abcdef01234567"
ADDRESS = str(TAILNET_RANGE[1])
HOME = "/srv/operator"


class FakeRemote:
    """Answers the few questions deploy asks and records everything else."""

    name = "arveil-staging"

    def __init__(self, unit, running=False):
        self.unit = unit
        self.running = running
        self.shells = []
        self.commands = []

    def shell(self, command, *, capture=True, **kwargs):
        self.shells.append(command)
        if command.startswith("printf"):
            output = HOME
        elif command.startswith("cat -- "):
            output = self.unit
        else:
            output = ""
        return subprocess.CompletedProcess(command, 0, stdout=output)

    def command(self, *args):
        self.commands.append(args)
        answers = {
            ("id", "-un"): "operator",
            ("tailscale", "ip", "-4"): ADDRESS,
            ("tailscale", "serve", "status", "--json"): "{}",
        }
        if args[:2] == ("loginctl", "show-user"):
            return "yes"
        if args[:2] == ("podman", "info"):
            return "true"
        if args[:2] == ("podman", "inspect"):
            return "true" if self.running else "false"
        if args[:3] == ("podman", "run", "--rm"):
            return f"arveil-relay {REVISION}"
        return answers.get(args, "")

    def healthy(self):
        self.commands.append(("healthy",))


def local(args, **kwargs):
    """Stands in for the operator's checkout: clean, at REVISION."""
    if args[:2] == ["git", "rev-parse"]:
        return subprocess.CompletedProcess(args, 0, stdout=REVISION + "\n")
    if args[:2] == ["git", "show"]:
        text = (ROOT / "relay/packaging/arveil-staging.container.in").read_text()
        return subprocess.CompletedProcess(args, 0, stdout=text)
    return subprocess.CompletedProcess(args, 0, stdout=b"")


def arguments(**overrides):
    values = {"host": "staging", "address": ADDRESS, "port": 8447, "name": "arveil-staging",
              "revision": "HEAD", "known_hosts": None, "image_only": False}
    values.update(overrides)
    return argparse.Namespace(**values)


class DeployTests(unittest.TestCase):
    def setUp(self):
        self.tunnel = render({"hostname": "relay.example.org",
                              "tunnel_id": "00000000-0000-4000-8000-000000000001",
                              "credentials_file": "/srv/arveil/private/tunnel.json",
                              "revision": "a" * 40})["arveil-staging.container"]

    def deploy(self, unit, running=False, **overrides):
        remote = FakeRemote(unit, running)
        with mock.patch.object(podman, "run", side_effect=local), \
                mock.patch.object(podman, "save_backup", return_value="backup") as backup:
            podman.deploy(arguments(**overrides), remote)
        remote.backups = backup.call_count
        return remote

    def test_a_unit_rendered_for_the_tunnel_is_recognised(self):
        self.assertTrue(podman.tunnel_unit(self.tunnel))
        stock = (ROOT / "relay/packaging/arveil-staging.container.in").read_text()
        self.assertFalse(podman.tunnel_unit(stock))
        self.assertFalse(podman.tunnel_unit(""))

    def test_deploy_refuses_to_replace_a_tunnel_unit_before_building_anything(self):
        remote = FakeRemote(self.tunnel)
        with mock.patch.object(podman, "run", side_effect=local), \
                self.assertRaisesRegex(RuntimeError, "prepare_tunnel.py"):
            podman.deploy(arguments(), remote)
        self.assertFalse(any("podman build" in shell or "cat >" in shell for shell in remote.shells))
        self.assertFalse(any(command[:2] == ("systemctl", "--user") for command in remote.commands))

    def test_image_only_builds_and_checks_without_touching_the_service(self):
        remote = self.deploy(self.tunnel, image_only=True)
        self.assertTrue(any("podman build" in shell for shell in remote.shells))
        self.assertFalse(any("cat >" in shell for shell in remote.shells))
        self.assertFalse(any(command[0] in ("systemctl", "healthy") for command in remote.commands))
        self.assertFalse(any(command[:3] == ("tailscale", "serve", "--bg") for command in remote.commands))

    def test_image_only_saves_a_backup_of_a_running_realm_for_the_switch_that_follows(self):
        self.assertEqual(self.deploy(self.tunnel, running=True, image_only=True).backups, 1)
        self.assertEqual(self.deploy(self.tunnel, running=False, image_only=True).backups, 0)

    def test_an_ordinary_realm_still_deploys_its_stock_unit(self):
        remote = self.deploy("")
        written = [shell for shell in remote.shells if "cat >" in shell]
        self.assertEqual(len(written), 1)
        self.assertIn(("systemctl", "--user", "restart", "arveil-staging.service"), remote.commands)


if __name__ == "__main__":
    unittest.main()
