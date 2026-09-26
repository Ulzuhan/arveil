"""Exercise the generated proxy with real nginx; no Cloudflare account needed.

Set ARVEIL_NGINX to a binary compiled with http_realip_module. All listeners
and the recording backend are temporary and bind only loopback.
"""
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
import unittest

from prepare_tunnel import TAILNET_RANGE, render


class Recorder(BaseHTTPRequestHandler):
    def do_GET(self):
        self.server.seen.append(dict(self.headers))
        body = json.dumps(dict(self.headers)).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


def port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


@unittest.skipUnless(os.environ.get("ARVEIL_NGINX"), "Set ARVEIL_NGINX to run real proxy tests")
class ProxyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="arveil-proxy-test-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.directory = Path(cls.temporary.name)
        cls.backend = ThreadingHTTPServer(("127.0.0.1", 0), Recorder)
        cls.backend.seen = []
        threading.Thread(target=cls.backend.serve_forever, daemon=True).start()
        cls.addClassCleanup(cls.backend.server_close)
        cls.addClassCleanup(cls.backend.shutdown)
        chosen = {cls.backend.server_port}
        while len(chosen) < 4:
            chosen.add(port())
        chosen.remove(cls.backend.server_port)
        cls.tailnet, cls.connector, metrics = sorted(chosen)
        config = {"hostname": "relay.example.org", "tunnel_id": "00000000-0000-4000-8000-000000000001",
                  "credentials_file": "/srv/arveil/private/tunnel.json", "revision": "a" * 40,
                  "tailnet_address": str(TAILNET_RANGE[1]), "tailnet_port": cls.tailnet,
                  "connector_port": cls.connector, "backend_port": cls.backend.server_port, "metrics_port": metrics}
        (cls.directory / "nginx.conf").write_text(render(config)["nginx.conf"])
        command = [os.environ["ARVEIL_NGINX"], "-e", "stderr", "-p", str(cls.directory) + "/", "-c", "nginx.conf"]
        subprocess.run(command + ["-t"], check=True, capture_output=True)
        cls.process = subprocess.Popen(command + ["-g", "daemon off;"], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        def stop():
            cls.process.terminate()
            cls.process.communicate(timeout=10)
        cls.addClassCleanup(stop)
        for _ in range(100):
            if cls.process.poll() is not None:
                raise RuntimeError("nginx failed to start")
            try:
                with socket.create_connection(("127.0.0.1", cls.connector), timeout=.1):
                    break
            except OSError:
                time.sleep(.02)
        else:
            raise RuntimeError("nginx did not become ready")

    def request(self, *, local=False, path="/v1/channel", method="GET", headers=()):
        connection = http.client.HTTPConnection("127.0.0.1", self.tailnet if local else self.connector, timeout=5)
        try:
            connection.putrequest(method, path)
            connection.putheader("Upgrade", "websocket")
            connection.putheader("Connection", "Upgrade")
            for name, value in headers:
                connection.putheader(name, value)
            connection.endheaders()
            response = connection.getresponse()
            return response.status, response.read()
        finally:
            connection.close()

    def test_cloudflare_address_replaces_the_entire_forged_chain(self):
        status, body = self.request(headers=(("CF-Connecting-IP", "198.51.100.12"),
            ("X-Forwarded-For", "203.0.113.1, 203.0.113.2"), ("Forwarded", "for=203.0.113.3")))
        self.assertEqual(status, 200)
        headers = json.loads(body)
        self.assertEqual(headers["X-Forwarded-For"], "198.51.100.12")
        self.assertNotIn("CF-Connecting-IP", headers)
        self.assertNotIn("Forwarded", headers)

    def test_ipv6_attribution(self):
        status, body = self.request(headers=(("CF-Connecting-IP", "2001:db8::12"),))
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["X-Forwarded-For"], "2001:db8::12")

    def test_missing_invalid_chained_and_duplicate_addresses_never_reach_relay(self):
        cases = [(), (("CF-Connecting-IP", "invalid"),),
                 (("CF-Connecting-IP", "198.51.100.1, 203.0.113.1"),),
                 (("CF-Connecting-IP", "198.51.100.1"), ("CF-Connecting-IP", "203.0.113.1"))]
        for headers in cases:
            with self.subTest(headers=headers):
                before = len(self.backend.seen)
                self.assertEqual(self.request(headers=headers)[0], 400)
                self.assertEqual(len(self.backend.seen), before)

    def test_tailnet_listener_ignores_both_spoofable_headers(self):
        status, body = self.request(local=True, headers=(("CF-Connecting-IP", "198.51.100.12"),
                                                       ("X-Forwarded-For", "203.0.113.1")))
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["X-Forwarded-For"], "127.0.0.1")

    def test_admin_paths_and_non_get_requests_are_not_forwarded(self):
        for local in (False, True):
            for path in ("/metrics", "/healthz", "/admin", "/v1/channel/"):
                before = len(self.backend.seen)
                status, _ = self.request(local=local, path=path, headers=(("CF-Connecting-IP", "198.51.100.12"),))
                self.assertEqual(status, 404)
                self.assertEqual(len(self.backend.seen), before)
        self.assertEqual(self.request(method="POST", headers=(("CF-Connecting-IP", "198.51.100.12"),))[0], 405)


if __name__ == "__main__":
    unittest.main()
