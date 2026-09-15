# Podman staging server

The relay runs in rootless Podman, supervised by a user systemd service
generated from `relay/packaging/arveil-staging.container.in` (Quadlet).
Each image is built from a committed Git revision and reports it with
`/arveil-relay -version`. This server is for disposable CLI and client testing.

## Deploy

Local requirements: Python 3, Git and authenticated SSH. Acceptance also needs
the Rust toolchain pinned in `core/rust-toolchain.toml`. Remote requirements:
rootless Podman with Quadlet, user systemd, lingering enabled and Tailscale
with permission for the deployment user to configure Serve.
The host builds a native image; Linux ARM64 does not need an x86-64 release
or Go/Rust installed on the host.

```sh
python3 scripts/podman.py deploy \
  --host "$ARVEIL_SSH_HOST" --address "$ARVEIL_TAILNET_IPV4"
```

Set `ARVEIL_SSH_HOST` to your private SSH alias and `ARVEIL_TAILNET_IPV4` to
your server's Tailscale IPv4 in your local shell. These are operator inputs;
this repository contains no live server address, login or SSH configuration.

Commit all intended changes first. `--revision` defaults to `HEAD`;
uncommitted tracked changes are refused. SSH uses its normal authentication
and host trust. `--known-hosts /path/to/known_hosts` can select an already
trusted file. Never commit passwords or private keys.

| Setting | Default |
|---|---|
| Service / container | `arveil-staging.service` / `arveil-staging` |
| Endpoint | `ws://<tailscale-ipv4>:8447/v1/channel` |
| Host port | `127.0.0.1:8447`, forwarded by Tailscale Serve TCP port 8447 |
| Data | Podman volume `arveil-staging-data`, mounted at `/data` |
| Quadlet | `~/.config/containers/systemd/arveil-staging.container` |
| Source | `~/.local/share/arveil/releases/<commit>/relay` |
| Image | `localhost/arveil-relay:<commit>` |
| Runtime limits | 512 MiB, one CPU, 128 processes |
| Build limits | 2 GiB, two CPUs |
| Health / metrics | Container loopback `127.0.0.1:9090`, not published |

`--name arveil-staging-<suffix>` and `--port` allow another instance. Use the
same arguments for deployment and acceptance. The container binds loopback;
Tailscale Serve forwards just the selected TCP port within the tailnet. No
Funnel or Internet endpoint is configured. Existing Serve routes are preserved.
Tailscale ACLs still apply; the relay sees connections from the local forwarder,
so its default per-address connection limit is shared by these clients.
The container uses a read-only root filesystem, a non-root application user,
no capabilities and no new privileges.

The unit joins the user's `default.target`; lingering starts the user manager
at boot. Quadlet does not need `systemctl enable`. Failed processes and health
checks restart the service. Retries also cover Tailscale bringing up its
address after the service starts.

## Operate

On the server, as the deployment user:

```sh
systemctl --user status arveil-staging.service
podman exec arveil-staging /arveil-relay -version
podman healthcheck run arveil-staging
podman logs arveil-staging
podman exec arveil-staging /arveil-relay invite -data-dir /data
systemctl --user restart arveil-staging.service
```

The public bootstrap string is in the log. An invite is a one-use credential
for the intended test client. Restarting preserves the volume. Stop with
`systemctl --user stop`; disable startup by moving the `.container` file out
of the Quadlet directory and running `systemctl --user daemon-reload`.
Keep the volume unless deliberately discarding the realm.
To remove its tailnet endpoint, run `tailscale serve --tcp=8447 off`.
Never use `tailscale serve reset` for this: it removes other services' routes.

## Repeatable CLI acceptance

```sh
python3 scripts/podman.py test-staging \
  --host "$ARVEIL_SSH_HOST" --address "$ARVEIL_TAILNET_IPV4"
```

**This test stops and restarts staging.** It creates two disposable encrypted
local profiles, repeats an enrollment twelve times, starts a real MLS
conversation, checks offline sending and delivery after a restart, and
rejects duplicate delivery. It backs up a queued message, restores into a
separate temporary volume, and verifies decryption through the restored realm
using the original endpoint and trust pin.

Cleanup brings the original service back up and never replaces its volume.
Temporary local profiles and the restore container/volume are removed. Test
memberships remain in the staging realm. Physical Flutter device acceptance
and a host-reboot drill are separate checks.

## Updates, backups and rollback

Deploy a new commit with the same command. The image is built and its reported
revision checked before switching. If staging is running, the helper saves a
backup before updating it. The old Quadlet is retained as `.container.previous`;
old images are not pruned.

Backups live under `~/.local/share/arveil/backups/`, with directory mode 0700
and archive mode 0600. They contain the realm's private keys. These are local,
unencrypted snapshots for staging, not an off-host disaster-recovery policy.
Before real use, encrypt and copy them off-host, define retention and test
that recovery path.

Keep host inventories, SSH files, command output, invites, client profiles
and backup archives outside the repository. Logs can include bootstrap
addresses and local paths; sanitize excerpts before sharing them in an issue
or pull request. The paths above describe the generic application layout,
not a particular machine. See [contribution hygiene](https://github.com/Ulzuhan/arveil/blob/main/CONTRIBUTING.md).

Switching only the image is not a guaranteed rollback: the newer binary may
have migrated the database. Restore the pre-update archive into a **new empty
volume** using `arveil-relay restore`, then select the restored volume and
matching old image in the Quadlet. Keep the current volume until recovery is
verified. See [operations](OPERATIONS.md#backups) for the archive contract.
