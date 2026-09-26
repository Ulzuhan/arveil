# A private realm through Cloudflare Tunnel

This is an optional deployment recipe. Arveil remains compatible with LAN,
Tailscale and direct public endpoints. No operator hostname, account, tunnel
ID, SSH destination, token or realm bootstrap belongs in the public repository.

Use separate hostnames for a project landing page and a personal realm, for
example `project.example.org` and `relay.example.org`. A single-level subdomain
also fits Cloudflare's ordinary Universal SSL wildcard coverage. Friends use
the public `wss://` endpoint with their normal Arveil invitation; they do not
need Tailscale or a Cloudflare account. Keep registration invite-only.

*Español: [Acceso mediante túnel](es/TUNNEL.md).*

## Traffic and trust boundaries

```text
Android ── WSS + Noise ── Cloudflare ── outbound tunnel ── cloudflared
                                                          │ loopback:8448
                                                          ▼
                                                      nginx ── loopback:8449 ── relay
                                                          ▲
Tailscale Serve TCP ──────────────────────────────── loopback:8447
```

Cloudflare terminates the outer TLS connection and sees the IP, hostname,
HTTP headers and traffic patterns. Arveil's authenticated Noise session still
terminates in the client and relay; message/attachment encryption remains in
place. This is not anonymous transport. See the [protocol explanation](articles/noise-inside-a-cloudflare-tunnel.md).

Only `/v1/channel` is forwarded. Relay administration/metrics remain on its
container loopback port 9090, unpublished; connector metrics also bind host
loopback. There is no router port forwarding. All three host listeners bind
127.0.0.1, and the host firewall should continue denying inbound application
ports. Only trusted local processes may access the proxy/backend.

**Do not enable `-trust-forwarded-for` directly behind cloudflared.** Cloudflare
can append the visitor IP to an incoming `X-Forwarded-For` chain, while the
relay reads its first entry. This recipe uses nginx's real-IP module on a
dedicated connector listener, takes `CF-Connecting-IP` only there, and replaces
the entire `X-Forwarded-For` value. Missing/invalid headers are refused. The
separate Tailscale listener strips incoming address claims and uses the actual
peer; Serve TCP clients retain the existing shared per-address limit.

Keep Cloudflare Pseudo IPv4 **Off** or **Add Header**, not **Overwrite Headers**,
and leave **Remove visitor IP headers** disabled. Do not attach Workers that
rewrite the client address to this hostname. The account, connector and local
proxy are trusted for IP attribution; they do not gain the Noise session keys.

## Prepare privately

Requirements: domain DNS on Cloudflare, a named **locally managed** tunnel,
cloudflared, nginx with `http_realip_module`, and the existing rootless
[Podman deployment](PODMAN.md). Install maintained versions from their official
sources. Restrict account administration with MFA and retain Tailscale for SSH.

Authenticate/create the named tunnel from the maintainer's machine following
[Cloudflare's local tunnel guide](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/create-local-tunnel/).
Put only that tunnel's credentials JSON on the server, mode 0600, in a 0700
directory. Do not copy the broader account `cert.pem` to the server. The
renderer below does not read or copy either credential. Back up the realm and
retain its existing named volume and keys before changing listeners.

Create `.local/tunnel/operator.json` with mode 0600 (all values below are examples):

```json
{
  "hostname": "relay.example.org",
  "tunnel_id": "00000000-0000-4000-8000-000000000001",
  "credentials_file": "/srv/arveil/private/tunnel.json",
  "revision": "0123456789012345678901234567890123456789",
  "name": "arveil-staging",
  "tailnet_address": "REPLACE_WITH_YOUR_TAILSCALE_IPV4",
  "tailnet_port": 8447,
  "connector_port": 8448,
  "backend_port": 8449,
  "metrics_port": 20241
}
```

Replace the address placeholder with your private Tailscale IPv4. Use the
**existing** container/volume name and an already-built committed image
revision. Omit `tailnet_address` only for a new public-only deployment. Ports
must be distinct and unused, except the tailnet port being migrated. Render:

```sh
python3 scripts/prepare_tunnel.py \
  --config .local/tunnel/operator.json --output .local/tunnel/rendered
```

The renderer refuses non-ignored Git locations and existing output directories.
It creates private `cloudflared.yml`, `nginx.conf`, relay Quadlet and two user
systemd units. It performs no SSH, DNS changes, startup or credential creation.
Keep its files, logs and inventories private. Review the service executable
paths (`/usr/sbin/nginx`, `/usr/local/bin/cloudflared`) for the target distribution.
The reference units need a user manager supporting their sandbox directives;
check them on the actual server before switching.

## Validate and switch

1. Save the existing Quadlet and a realm backup privately. Verify the pinned
   relay image exists and its `-version` matches. Keep the old image and data.
2. Copy configs to `~/.local/share/arveil/tunnel/` (directory 0700, files 0600)
   and the service units to `~/.config/systemd/user/`. Check configuration:

   ```sh
   nginx -V
   nginx -t -e stderr -p "$HOME/.local/share/arveil/tunnel/" -c nginx.conf
   cloudflared --config "$HOME/.local/share/arveil/tunnel/cloudflared.yml" tunnel ingress validate
   systemd-analyze --user verify "$HOME/.config/systemd/user/arveil-proxy.service" \
     "$HOME/.config/systemd/user/arveil-tunnel.service"
   ```

3. Replace only the selected realm's Quadlet, retaining its named data volume.
   Reload user systemd and restart that realm; its backend moves to loopback
   8449, freeing the old 8447 port. Start the proxy and connector. Expect a
   brief reconnect interval. Do not reset Tailscale Serve or change other routes.
4. Validate locally before creating the public DNS route. Check the relay's
   internal health command and `ss -lnt`: every host port above must be loopback.
   Confirm nginx refuses `/metrics`, `/healthz` and every path except the
   channel; a channel request without WebSocket upgrade or a missing/invalid
   Cloudflare address must fail. Verify Tailscale still works and cannot spoof
   a different address with either forwarding header.
5. Create a DNS route for **only the chosen relay hostname** to this named
   tunnel. Keep the landing hostname unchanged. Enable WebSockets, bypass
   cache on this hostname, and avoid browser-only Access logins, JavaScript
   challenges or CAPTCHA on the channel. Arveil's Noise/invite authentication
   remains required. Do not weaken protections on unrelated services.
6. From outside the tailnet, complete a real Arveil enrollment with a disposable
   one-use invitation and exchange messages. Test reconnect after restarting
   the connector, attachments within the relay's limits, and limits with
   deliberately forged incoming `X-Forwarded-For`. Check the signed endpoint
   list and new bootstrap use the public WSS endpoint. Existing members should
   learn it while their previous endpoint is still reachable.
7. Enable just the proxy/connector user units for startup, confirm lingering,
   and check a reboot/restart. Keep journals limited in retention and never
   enable request logging containing identifiers or dump invites into tickets.

Do not call the deployment ready merely because the tunnel reports connected:
the external Noise handshake, address attribution and profile-preserving
client update are separate checks. Cloudflare/proxy restarts can interrupt
WebSockets; the clients must reconnect.

For a cutover rollback, stop the new connector and proxy **before** restoring
the old Quadlet, so port 8447 is free again. Restore its original flags and
restart; leave the same volume intact when only networking changed. Remove
only the new DNS route if it is no longer wanted. If also changing relay code
or database format, use the [backup/rollback procedure](PODMAN.md#updates-backups-and-rollback)
instead of assuming an older binary can read the current database.

References: [Cloudflare headers](https://developers.cloudflare.com/fundamentals/reference/http-headers/),
[nginx real-IP module](https://nginx.org/en/docs/http/ngx_http_realip_module.html),
[nginx WebSocket proxying](https://nginx.org/en/docs/http/websocket.html).
