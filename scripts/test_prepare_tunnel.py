import copy
from pathlib import Path
import tempfile
import unittest

from prepare_tunnel import TAILNET_RANGE, private_path, render


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
            with self.subTest(field=key), self.assertRaises(ValueError):
                render(config)

    def test_refuses_nonignored_repository_output(self):
        with self.assertRaises(ValueError):
            private_path(Path(__file__).resolve().parents[1] / "private-live-config")
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(private_path(Path(directory)), Path(directory).resolve())


if __name__ == "__main__":
    unittest.main()
