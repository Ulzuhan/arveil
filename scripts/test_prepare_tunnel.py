from contextlib import redirect_stderr, redirect_stdout
import copy
import io
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from prepare_tunnel import ROOT, TAILNET_RANGE, main, private_path, render


class TunnelTests(unittest.TestCase):
    def setUp(self):
        self.config = {"hostname": "relay.example.org", "tunnel_id": "00000000-0000-4000-8000-000000000001",
                       "credentials_file": "/srv/arveil/private/tunnel.json", "revision": "a" * 40,
                       "tailnet_address": str(TAILNET_RANGE[1])}

    def test_only_channel_is_forwarded_and_every_published_port_is_loopback(self):
        files = render(self.config)
        self.assertIn("path: ^/v1/channel$", files["cloudflared.yml"])
        self.assertIn("http_status:404", files["cloudflared.yml"])
        self.assertIn("metrics: 127.0.0.1:", files["cloudflared.yml"])
        self.assertIn("PublishPort=127.0.0.1:8449:8447", files["arveil-staging.container"])
        self.assertIn("-admin-listen=127.0.0.1:9090", files["arveil-staging.container"])
        self.assertIn("-advertise=public=wss://relay.example.org/v1/channel,tailnet=", files["arveil-staging.container"])
        self.assertNotIn("@", files["arveil-staging.container"])

    def test_header_trust_is_scoped_to_the_connector_listener(self):
        nginx = render(self.config)["nginx.conf"]
        public, private = nginx.split("listen 127.0.0.1:8447;")
        self.assertIn("real_ip_header CF-Connecting-IP;", public)
        self.assertNotIn("real_ip_header", private)
        self.assertEqual(nginx.count("proxy_set_header X-Forwarded-For $remote_addr;"), 2)
        self.assertNotIn("$proxy_add_x_forwarded_for", nginx)
        self.assertIn("location / { return 404; }", private)
        self.assertIn("access_log off;", nginx)
        # Error pages and the Server header must not name the nginx version.
        self.assertIn("server_tokens off;", nginx)

    def test_user_units_do_not_wait_for_a_system_only_target(self):
        files = render(self.config)
        for unit in ("arveil-proxy.service", "arveil-tunnel.service"):
            self.assertNotIn("network-online", files[unit])
        self.assertIn("After=arveil-proxy.service\nWants=arveil-proxy.service\n", files["arveil-tunnel.service"])

    def test_nginx_before_1_23_is_refused_at_start_and_on_every_connector_request(self):
        files = render(self.config)
        # Older nginx shows only the first of two CF-Connecting-IP lines.
        old, supported = ("0.8.55", "1.2.9", "1.18.0", "1.22.1"), ("1.23.0", "1.24.0", "1.26.3", "1.30.0", "2.0.0")
        public, private = files["nginx.conf"].split("listen 127.0.0.1:8447;")
        self.assertIn("if ($arveil_nginx_too_old) { return 500; }", public)
        self.assertNotIn("arveil_nginx_too_old", private)
        pattern = re.search(r'map \$nginx_version \$arveil_nginx_too_old \{\s*"~([^"]+)" 1;\s*default 0;\s*\}',
                            files["nginx.conf"]).group(1)
        for version in old + supported:
            self.assertEqual(bool(re.search(pattern, version)), version in old, version)
        line = next(line for line in files["arveil-proxy.service"].splitlines() if line.startswith("ExecStartPre="))
        self.assertNotIn("$", line.replace("$$", ""))  # nothing for systemd to expand
        self.assertNotIn("%", line)  # nor any systemd specifier
        command = shlex.split(line.removeprefix("ExecStartPre=").replace("$$", "$"))
        with tempfile.TemporaryDirectory() as directory:
            nginx = Path(directory) / "nginx"
            nginx.write_text('#!/bin/sh\necho "nginx version: nginx/$VERSION (Debian)" >&2\n')
            nginx.chmod(0o700)
            command = [part.replace("/usr/sbin/nginx", str(nginx)) for part in command]
            for version in old + supported:
                result = subprocess.run(command, env={"PATH": os.defpath, "VERSION": version},
                                        capture_output=True, text=True, check=False)
                with self.subTest(version=version):
                    self.assertEqual(result.returncode, 1 if version in old else 0)
                    self.assertEqual("nginx 1.23 or later is required" in result.stderr, version in old)

    def test_channel_timeouts_outlast_the_relay_read_timeout(self):
        # A real idle wait of 90 s or more does not belong in CI; the proxy
        # tests shorten the timeout instead and watch nginx apply it.
        relay = re.search(r"ReadTimeout:\s+(\d+) \* time\.Second",
                          (ROOT / "relay/cmd/arveil-relay/main.go").read_text())
        self.assertIsNotNone(relay, "the relay's read timeout moved; update this test")
        nginx = render(self.config)["nginx.conf"]
        for directive in ("proxy_read_timeout", "proxy_send_timeout"):
            values = re.findall(rf"^ +{directive} (\d+)s;$", nginx, re.MULTILINE)
            self.assertEqual(len(values), 2)  # connector and tailnet listeners
            for value in values:
                self.assertGreater(int(value), int(relay.group(1)))
        shortened = render(self.config, idle_timeout=1)["nginx.conf"]
        self.assertEqual(len(re.findall(r"proxy_(?:read|send)_timeout 1s;", shortened)), 4)
        for value in (0, "1", 1.5, True):
            self.assertRaisesRegex(ValueError, "^idle_timeout", render, self.config, idle_timeout=value)
        self.assertRaisesRegex(ValueError, "Unknown operator field", render, dict(self.config, idle_timeout=1))

    def test_refuses_configuration_injection_tokens_and_overlapping_ports(self):
        for key, value in (("hostname", "relay.example.org; injected"), ("revision", "main"),
                           ("credentials_file", "/tmp/a\nother.json"), ("name", "../other"),
                           ("connector_port", 8447), ("backend_port", 80), ("backend_port", True),
                           ("tailnet_address", "192.0.2.1"), ("token", "not accepted")):
            config = copy.deepcopy(self.config); config[key] = value
            with self.subTest(field=key), self.assertRaises(ValueError) as refused:
                render(config)
            self.assertIn(key, str(refused.exception))
            self.assertNotIn(str(value), str(refused.exception))

    def test_errors_name_the_field_and_constraint_never_the_value(self):
        for key, value in (("tunnel_id", "not-a-uuid"), ("tunnel_id", 7), ("revision", 7),
                           ("name", ["arveil-x"]), ("tailnet_address", 1681915905),
                           ("tailnet_address", "100.64.1"), ("hostname", "Relay.Example.org"),
                           ("metrics_port", "20241")):
            config = copy.deepcopy(self.config); config[key] = value
            with self.subTest(field=key, value=value), self.assertRaises(ValueError) as refused:
                render(config)
            message = str(refused.exception)
            self.assertTrue(message.startswith(f"{key}: "), message)
            self.assertNotIn(str(value), message)
        config = copy.deepcopy(self.config); del config["revision"], config["hostname"]
        self.assertRaisesRegex(ValueError, "^Missing operator field\\(s\\): hostname, revision\\.$", render, config)
        config = copy.deepcopy(self.config); config["Example-Pasted-Token-0000"] = True
        with self.assertRaises(ValueError) as refused:
            render(config)
        self.assertIn("(name not shown)", str(refused.exception))
        self.assertNotIn("Pasted", str(refused.exception))
        self.assertRaisesRegex(ValueError, "object", render, [self.config])

    def test_command_line_reports_the_reason_and_writes_nothing(self):
        previous = os.umask(0o077)  # main() sets it for the whole process
        self.addCleanup(os.umask, previous)
        with tempfile.TemporaryDirectory() as directory:
            source, output = Path(directory) / "operator.json", Path(directory) / "rendered"
            def run(config):
                source.write_text(config if isinstance(config, str) else json.dumps(config))
                source.chmod(0o600)
                stderr = io.StringIO()
                with mock.patch.object(sys, "argv", ["prepare_tunnel.py", "--config", str(source),
                                                     "--output", str(output)]), \
                        redirect_stderr(stderr), redirect_stdout(io.StringIO()):
                    return main(), stderr.getvalue()
            status, stderr = run(dict(self.config, credentials_file="/srv/private/kept-secret"))
            self.assertEqual(status, 1)
            self.assertIn("credentials_file: use a simple absolute path", stderr)
            self.assertIn("No deployment was attempted.", stderr)
            self.assertNotIn("kept-secret", stderr)
            self.assertFalse(output.exists())
            status, stderr = run('{"hostname": "kept-secret"')
            self.assertEqual(status, 1)
            self.assertIn("The operator JSON is malformed", stderr)
            self.assertNotIn("kept-secret", stderr)
            self.assertEqual(run(self.config)[0], 0)
            self.assertEqual(sorted(p.name for p in output.iterdir()), sorted(render(self.config)))
            self.assertEqual(output.stat().st_mode & 0o777, 0o700)
            status, stderr = run(self.config)
            self.assertEqual(status, 1)
            self.assertIn(f"File exists: {output.resolve()}", stderr)

    def test_refuses_nonignored_repository_output(self):
        with self.assertRaises(ValueError):
            private_path(Path(__file__).resolve().parents[1] / "private-live-config")
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(private_path(Path(directory)), Path(directory).resolve())


if __name__ == "__main__":
    unittest.main()
