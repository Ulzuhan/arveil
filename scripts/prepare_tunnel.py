#!/usr/bin/env python3
"""Render private, reviewable Cloudflare/nginx/Podman configuration; never deploy.

Pass an operator JSON outside version control. Output must be outside Git or
inside a Git-ignored directory. No credentials are read or copied.
"""
import argparse
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
TAILNET_RANGE = ipaddress.IPv4Network("100.64.0.0/10")


def private_path(path):
    path = path.resolve()
    # Also works for linked worktrees, whose .git is a file.
    ancestor = next((p for p in (path, *path.parents) if (p / ".git").exists()), None)
    if ancestor is not None:
        ignored = subprocess.run(["git", "check-ignore", "--quiet", "--", str(path)],
                                 cwd=ancestor, check=False).returncode == 0
        if not ignored:
            raise ValueError("Operator configuration and output must be outside Git or Git-ignored.")
    return path


def render(config):
    allowed = {"hostname", "tunnel_id", "credentials_file", "revision", "name", "tailnet_address",
               "tailnet_port", "connector_port", "backend_port", "metrics_port"}
    if set(config) - allowed:
        raise ValueError("Unknown operator fields; do not put tokens or keys in this configuration.")
    hostname = config["hostname"]
    if not isinstance(hostname, str) or len(hostname) > 253 or not re.fullmatch(
            r"(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}", hostname):
        raise ValueError("Use a DNS hostname, without a scheme, port or path.")
    if not isinstance(config["tunnel_id"], str):
        raise ValueError("Use the tunnel UUID string.")
    tunnel = str(uuid.UUID(config["tunnel_id"]))
    credentials = config["credentials_file"]
    if not isinstance(credentials, str) or not re.fullmatch(r"/[A-Za-z0-9_./-]+\.json", credentials) or ".." in Path(credentials).parts:
        raise ValueError("Use a simple absolute remote path for the tunnel credentials JSON.")
    revision = config["revision"]
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("Use the full committed relay revision, never a moving image tag.")
    name = config.get("name", "arveil-staging")
    if not re.fullmatch(r"arveil-[a-z0-9][a-z0-9-]{0,40}", name):
        raise ValueError("Use an arveil-* service/container name.")
    ports = [config.get(k, v) for k, v in (("tailnet_port", 8447), ("connector_port", 8448),
                                          ("backend_port", 8449), ("metrics_port", 20241))]
    if any(type(p) is not int or not 1024 <= p <= 65535 for p in ports) or len(set(ports)) != 4:
        raise ValueError("Use four distinct unprivileged local ports.")
    tailnet, connector, backend, metrics = ports
    address = config.get("tailnet_address")
    if address is not None and ipaddress.IPv4Address(address) not in TAILNET_RANGE:
        raise ValueError("The optional tailnet address must be a Tailscale IPv4 address.")
    advertise = f"public=wss://{hostname}/v1/channel"
    if address:
        advertise += f",tailnet=ws://{address}:{tailnet}/v1/channel"
    template = (ROOT / "relay/packaging/arveil-staging.container.in").read_text()
    for key, value in {"REVISION": revision, "IMAGE": f"localhost/arveil-relay:{revision}",
                       "NAME": name, "ADDRESS": address or "127.0.0.1", "PORT": str(backend)}.items():
        template = template.replace(f"@{key}@", value)
    template = re.sub(r" -advertise=[^\n]+", f" -trust-forwarded-for=true -advertise={advertise}", template)
    template = template.replace("# Rendered by scripts/podman.py from a specific Git commit.",
                                "# PRIVATE: rendered by scripts/prepare_tunnel.py; do not commit.")
    location = f"""
        location = /v1/channel {{
            if ($request_method != GET) {{ return 405; }}
            if ($http_upgrade !~* ^websocket$) {{ return 400; }}
            proxy_pass http://127.0.0.1:{backend};
            proxy_http_version 1.1;
            proxy_set_header Upgrade websocket;
            proxy_set_header Connection upgrade;
            proxy_set_header Host $host;
            # Replace, never append to an untrusted incoming chain.
            proxy_set_header X-Forwarded-For $remote_addr;
            proxy_set_header CF-Connecting-IP "";
            proxy_set_header Forwarded "";
            proxy_buffering off;
            proxy_cache off;
            proxy_read_timeout 100s;
            proxy_send_timeout 100s;
        }}
        location / {{ return 404; }}
"""
    nginx = f"""# PRIVATE: only local trusted processes may reach these listeners.
worker_processes 1;
pid nginx.pid;
error_log stderr crit;
events {{ worker_connections 1024; }}
http {{
    access_log off;
    client_max_body_size 1k;
    client_body_temp_path body;
    proxy_temp_path proxy;
    fastcgi_temp_path fastcgi;
    uwsgi_temp_path uwsgi;
    scgi_temp_path scgi;
    server {{
        listen 127.0.0.1:{connector};
        server_name {hostname};
        set_real_ip_from 127.0.0.1;
        real_ip_header CF-Connecting-IP;
        real_ip_recursive off;
        if ($http_cf_connecting_ip ~ "[,[:space:]]") {{ return 400; }}
        # Invalid/missing/multiple address headers leave the peer as loopback.
        # They must not become arbitrary buckets in the relay's rate limiter.
        if ($remote_addr = 127.0.0.1) {{ return 400; }}
        if ($remote_addr = ::1) {{ return 400; }}
{location}    }}
"""
    if address:
        nginx += f"""    server {{
        listen 127.0.0.1:{tailnet};
        server_name _;
        # Tailscale Serve TCP loses the original IP. Keep its clients in the
        # local forwarder's bucket; NEVER trust CF or XFF headers on this port.
{location}    }}
"""
    nginx += "}\n"
    cloudflared = f"""# PRIVATE: credentials stay on the host, separate from this file.
tunnel: {tunnel}
credentials-file: {credentials}
metrics: 127.0.0.1:{metrics}
ingress:
  - hostname: {hostname}
    path: ^/v1/channel$
    service: http://127.0.0.1:{connector}
  - service: http_status:404
"""
    proxy_unit = """[Unit]
Description=Arveil local WebSocket proxy
After=network-online.target

[Service]
ExecStart=/usr/sbin/nginx -e stderr -p %h/.local/share/arveil/tunnel/ -c nginx.conf -g "daemon off;"
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=%h/.local/share/arveil/tunnel
UMask=0077

[Install]
WantedBy=default.target
"""
    tunnel_unit = """[Unit]
Description=Arveil Cloudflare connector
After=network-online.target arveil-proxy.service
Wants=arveil-proxy.service

[Service]
ExecStart=/usr/local/bin/cloudflared --no-autoupdate --config %h/.local/share/arveil/tunnel/cloudflared.yml tunnel run
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
UMask=0077

[Install]
WantedBy=default.target
"""
    return {"cloudflared.yml": cloudflared, "nginx.conf": nginx,
            f"{name}.container": template, "arveil-proxy.service": proxy_unit,
            "arveil-tunnel.service": tunnel_unit}


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        source = private_path(args.config)
        output = private_path(args.output)
        if source.stat().st_mode & 0o077:
            raise ValueError("Operator JSON must be private (chmod 600).")
        rendered = render(json.loads(source.read_text()))
        output.mkdir(parents=True, exist_ok=False, mode=0o700)
        for name, data in rendered.items():
            with open(output / name, "x", opener=lambda p, f: os.open(p, f, 0o600)) as file:
                file.write(data)
        print("Private configuration prepared. Review paths and run the validation/cutover in docs/TUNNEL.md.")
    except (ValueError, OSError, KeyError, TypeError):
        print("Tunnel preparation failed. Check the private input, permissions and output location; no deployment was attempted.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
