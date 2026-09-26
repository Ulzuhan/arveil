"""Exercise the generated proxy with real nginx; no Cloudflare account needed.

Set ARVEIL_NGINX to a binary (1.23 or later) compiled with http_realip_module.
Set ARVEIL_REQUIRE_NGINX=1, as CI does, to fail instead of skipping when it is
missing. All listeners and the recording backend are temporary and bind only
loopback.
"""
import base64
import hashlib
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

NGINX = os.environ.get("ARVEIL_NGINX")
REQUIRED = os.environ.get("ARVEIL_REQUIRE_NGINX") == "1"
ADDRESS = (("CF-Connecting-IP", "198.51.100.12"),)
WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def accept(key):
    """The Sec-WebSocket-Accept value a server derives from the client's key."""
    return base64.b64encode(hashlib.sha1((key + WEBSOCKET_GUID).encode()).digest()).decode()


def frame(payload, mask=None):
    """One short, final text frame; a client must mask it (RFC 6455)."""
    if mask is None:
        return bytes([0x81, len(payload)]) + payload
    return bytes([0x81, 0x80 | len(payload)]) + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload))


def read_frame(stream, *, masked):
    """Read one frame written by frame(); EOFError if the peer closed first."""
    head = stream.read(2)
    if len(head) < 2:
        raise EOFError
    if head[0] != 0x81 or bool(head[1] & 0x80) != masked or head[1] & 0x7F > 125:
        raise ValueError(f"unexpected frame header {head.hex()}")
    mask = stream.read(4) if masked else bytes(4)
    payload = stream.read(head[1] & 0x7F)
    if len(mask) < 4 or len(payload) < head[1] & 0x7F:
        raise EOFError
    return bytes(b ^ mask[i % 4] for i, b in enumerate(payload))


class Recorder(BaseHTTPRequestHandler):
    """Stands in for the relay: records headers, then echoes them or upgrades."""

    def do_GET(self):
        self.server.seen.append(dict(self.headers))
        key = self.headers.get("Sec-WebSocket-Key")
        if key is not None:
            return self.channel(key)
        body = json.dumps(dict(self.headers)).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def channel(self, key):
        self.wfile.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                          f"Connection: Upgrade\r\nSec-WebSocket-Accept: {accept(key)}\r\n\r\n").encode())
        self.wfile.write(frame(b"from relay"))
        try:
            # Answer each frame until nginx closes the upstream connection.
            while True:
                self.wfile.write(frame(b"relay saw " + read_frame(self.rfile, masked=True)))
        except (EOFError, OSError):
            pass

    def log_message(self, *_args):
        pass


def port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


@unittest.skipUnless(NGINX or REQUIRED, "Set ARVEIL_NGINX to run real proxy tests")
class Proxy(unittest.TestCase):
    """Starts a recording backend and nginx with the rendered configuration."""

    options = {}

    @classmethod
    def setUpClass(cls):
        if not NGINX:
            raise RuntimeError("ARVEIL_REQUIRE_NGINX=1: set ARVEIL_NGINX to an nginx binary.")
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
        (cls.directory / "nginx.conf").write_text(render(config, **cls.options)["nginx.conf"])
        command = [NGINX, "-e", "stderr", "-p", str(cls.directory) + "/", "-c", "nginx.conf"]
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

    def exchange(self, *, local=False, path="/v1/channel", method="GET", headers=()):
        """Send one request that asks for an upgrade; return status, headers and body."""
        connection = http.client.HTTPConnection("127.0.0.1", self.tailnet if local else self.connector, timeout=5)
        try:
            connection.putrequest(method, path)
            connection.putheader("Upgrade", "websocket")
            connection.putheader("Connection", "Upgrade")
            for name, value in headers:
                connection.putheader(name, value)
            connection.endheaders()
            response = connection.getresponse()
            return response.status, response.headers, response.read()
        finally:
            connection.close()

    def request(self, **kwargs):
        status, _, body = self.exchange(**kwargs)
        return status, body

    def open_channel(self):
        """Complete a WebSocket handshake with the backend through nginx."""
        key = base64.b64encode(os.urandom(16)).decode()
        sock = socket.create_connection(("127.0.0.1", self.connector), timeout=5)
        self.addCleanup(sock.close)
        request = ["GET /v1/channel HTTP/1.1", "Host: relay.example.org", "Upgrade: websocket",
                   "Connection: Upgrade", f"Sec-WebSocket-Key: {key}", "Sec-WebSocket-Version: 13",
                   "CF-Connecting-IP: 198.51.100.12"]
        sock.sendall("\r\n".join(request).encode() + b"\r\n\r\n")
        stream = sock.makefile("rb")
        self.addCleanup(stream.close)
        self.assertEqual(stream.readline(), b"HTTP/1.1 101 Switching Protocols\r\n")
        response = http.client.parse_headers(stream)
        self.assertEqual(response["Upgrade"], "websocket")
        # Only the backend could derive this from the key nginx passed on.
        self.assertEqual(response["Sec-WebSocket-Accept"], accept(key))
        self.assertEqual(read_frame(stream, masked=False), b"from relay")
        return sock, stream


class ProxyTests(Proxy):
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
                status, _ = self.request(local=local, path=path, headers=ADDRESS)
                self.assertEqual(status, 404)
                self.assertEqual(len(self.backend.seen), before)
        self.assertEqual(self.request(method="POST", headers=ADDRESS)[0], 405)

    def test_error_responses_do_not_reveal_the_nginx_version(self):
        for expected, kwargs in ((400, {}), (404, {"path": "/metrics", "headers": ADDRESS}),
                                 (405, {"method": "POST", "headers": ADDRESS})):
            with self.subTest(status=expected):
                status, headers, body = self.exchange(**kwargs)
                self.assertEqual(status, expected)
                self.assertEqual(headers["Server"], "nginx")
                self.assertNotRegex(body, rb"nginx/[0-9]")

    def test_websocket_upgrade_carries_frames_both_ways(self):
        sock, stream = self.open_channel()
        seen = self.backend.seen[-1]
        self.assertEqual(seen["X-Forwarded-For"], "198.51.100.12")
        self.assertEqual((seen["Upgrade"], seen["Connection"]), ("websocket", "upgrade"))
        self.assertNotIn("CF-Connecting-IP", seen)
        for payload in (b"first", b"second"):
            sock.sendall(frame(payload, mask=os.urandom(4)))
            self.assertEqual(read_frame(stream, masked=False), b"relay saw " + payload)


class IdleTimeoutTests(Proxy):
    # The rendered 100 s is too long for CI; a shortened copy shows nginx
    # applies the setting to an upgraded connection.
    options = {"idle_timeout": 1}

    def test_an_idle_channel_is_closed_after_the_proxy_timeout(self):
        sock, stream = self.open_channel()
        sock.sendall(frame(b"ping", mask=os.urandom(4)))
        self.assertEqual(read_frame(stream, masked=False), b"relay saw ping")
        started = time.monotonic()
        with self.assertRaises(EOFError):  # a TimeoutError would mean it was kept open
            read_frame(stream, masked=False)
        self.assertGreater(time.monotonic() - started, .5)


if __name__ == "__main__":
    unittest.main()
