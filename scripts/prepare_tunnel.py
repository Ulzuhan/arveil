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
# nginx before 1.23 reads only the first of repeated header lines, so it could
# not refuse two CF-Connecting-IP headers. Refused as a $nginx_version regex in
# nginx.conf and as sh case patterns over `nginx -v` in the proxy unit.
OLD_NGINX = r"^(0|1\.([0-9]|1[0-9]|2[0-2]))\."
OLD_NGINX_VERSIONS = "*nginx/0.*|*nginx/1.[0-9].*|*nginx/1.1[0-9].*|*nginx/1.2[0-2].*"


def private_path(path, what="Operator configuration and output"):
    path = path.resolve()
    # Also works for linked worktrees, whose .git is a file.
    ancestor = next((p for p in (path, *path.parents) if (p / ".git").exists()), None)
    if ancestor is not None:
        ignored = subprocess.run(["git", "check-ignore", "--quiet", "--", str(path)],
                                 cwd=ancestor, check=False).returncode == 0
        if not ignored:
            raise ValueError(f"{what} must be outside Git or Git-ignored.")
    return path


def render(config):
    """Return the private files by name.

    Errors name the field and its constraint, never the value.
    """
    if not isinstance(config, dict):
        raise ValueError("The operator JSON must be an object of named fields.")
    allowed = {"hostname", "tunnel_id", "credentials_file", "revision", "name", "tailnet_address",
               "tailnet_port", "connector_port", "backend_port", "metrics_port"}
    # A pasted secret could arrive as a key: name only plain field-like keys.
    unknown = sorted({k if re.fullmatch(r"[a-z][a-z0-9_]{0,31}", k) else "(name not shown)"
                      for k in set(config) - allowed})
    if unknown:
        raise ValueError(f"Unknown operator field(s): {', '.join(unknown)}. "
                         "Do not put tokens or keys in this configuration.")
    missing = [k for k in ("hostname", "tunnel_id", "credentials_file", "revision") if k not in config]
    if missing:
        raise ValueError(f"Missing operator field(s): {', '.join(missing)}.")
    hostname = config["hostname"]
    if not isinstance(hostname, str) or len(hostname) > 253 or not re.fullmatch(
            r"(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}", hostname):
        raise ValueError("hostname: use a lowercase DNS hostname, without a scheme, port or path.")
    try:
        tunnel = str(uuid.UUID(config["tunnel_id"]))
    except (AttributeError, TypeError, ValueError):
        raise ValueError("tunnel_id: use the tunnel UUID string.") from None
    credentials = config["credentials_file"]
    if not isinstance(credentials, str) or not re.fullmatch(r"/[A-Za-z0-9_./-]+\.json", credentials) or ".." in Path(credentials).parts:
        raise ValueError("credentials_file: use a simple absolute path on the server to the tunnel "
                         "credentials JSON (letters, digits and _ . / -, ending in .json, no '..').")
    revision = config["revision"]
    if not isinstance(revision, str) or not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("revision: use the full 40-character lowercase commit hash of the relay, "
                         "never a branch or a moving image tag.")
    name = config.get("name", "arveil-staging")
    if not isinstance(name, str) or not re.fullmatch(r"arveil-[a-z0-9][a-z0-9-]{0,40}", name):
        raise ValueError("name: use the arveil-* service/container name: lowercase letters, digits "
                         "and hyphens, at most 48 characters.")
    ports = {}
    for key, default in (("tailnet_port", 8447), ("connector_port", 8448),
                         ("backend_port", 8449), ("metrics_port", 20241)):
        port = config.get(key, default)
        if type(port) is not int or not 1024 <= port <= 65535:
            raise ValueError(f"{key}: use an unprivileged local port number (1024-65535).")
        clash = next((other for other, used in ports.items() if used == port), None)
        if clash:
            raise ValueError(f"{key}: must differ from {clash}; the four local ports must be distinct.")
        ports[key] = port
    tailnet, connector, backend, metrics = ports.values()
    address = config.get("tailnet_address")
    if address is not None:
        try:
            tailscale = isinstance(address, str) and ipaddress.IPv4Address(address) in TAILNET_RANGE
        except ValueError:  # its message would quote the address
            tailscale = False
        if not tailscale:
            raise ValueError(f"tailnet_address: omit it, or use this host's Tailscale IPv4 address "
                             f"(inside {TAILNET_RANGE}).")
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
    server_tokens off;
    client_max_body_size 1k;
    client_body_temp_path body;
    proxy_temp_path proxy;
    fastcgi_temp_path fastcgi;
    uwsgi_temp_path uwsgi;
    scgi_temp_path scgi;
    # nginx joins repeated header lines into $http_* only since 1.23; older
    # versions show just the first, so a duplicated address would pass.
    map $nginx_version $arveil_nginx_too_old {{
        "~{OLD_NGINX}" 1;
        default 0;
    }}
    server {{
        listen 127.0.0.1:{connector};
        server_name {hostname};
        if ($arveil_nginx_too_old) {{ return 500; }}
        set_real_ip_from 127.0.0.1;
        real_ip_header CF-Connecting-IP;
        real_ip_recursive off;
        # $http_cf_connecting_ip joins repeated lines with ", ", so this
        # refuses duplicated as well as chained values.
        if ($http_cf_connecting_ip ~ "[,[:space:]]") {{ return 400; }}
        # Invalid or missing address headers leave the peer as loopback.
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
    # User managers have no network-online.target; waiting for it does nothing.
    proxy_unit = f"""[Unit]
Description=Arveil local WebSocket proxy

[Service]
# Refuse to start on an nginx that cannot see duplicated address headers.
ExecStartPre=/bin/sh -c 'case "$$(/usr/sbin/nginx -v 2>&1)" in {OLD_NGINX_VERSIONS}) echo "Arveil proxy: nginx 1.23 or later is required to refuse duplicate CF-Connecting-IP headers." >&2; exit 1;; esac'
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
After=arveil-proxy.service
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
        source = private_path(args.config, "The operator configuration")
        output = private_path(args.output, "The output directory")
        if source.stat().st_mode & 0o077:
            raise ValueError("The operator JSON must be private (chmod 600).")
        try:
            config = json.loads(source.read_text(encoding="utf-8"))
        except UnicodeDecodeError:  # its message would quote input bytes
            raise ValueError("The operator JSON must be UTF-8 text.") from None
        except json.JSONDecodeError as error:
            raise ValueError(f"The operator JSON is malformed: {error.msg} at line {error.lineno}, "
                             f"column {error.colno}.") from None
        rendered = render(config)
        output.mkdir(parents=True, exist_ok=False, mode=0o700)
        for name, data in rendered.items():
            with open(output / name, "x", opener=lambda p, f: os.open(p, f, 0o600)) as file:
                file.write(data)
        print("Private configuration prepared. Review paths and run the validation/cutover in docs/TUNNEL.md.")
    except (ValueError, OSError) as error:
        # Reasons name a field, a constraint or a path; never an input value.
        if isinstance(error, OSError) and error.filename:
            error = f"{error.strerror}: {error.filename}"
        print(f"Tunnel preparation failed: {error}", file=sys.stderr)
        print("No deployment was attempted.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
