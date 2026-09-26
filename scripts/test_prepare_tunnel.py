from contextlib import redirect_stderr, redirect_stdout
import copy
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

from prepare_tunnel import TAILNET_RANGE, main, private_path, render


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
