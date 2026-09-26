# ADR-013 — Realm administration from the app

- **Status:** proposed. Nothing in this record is implemented.
- **Date:** 2026-09-27.
- **Scope:** who administers a realm, how they invite and remove people from the app, and how administration is recovered when devices are lost. Invitation links and QR codes are [ADR-012](ADR-012-qr-codes-and-links.md).

*Versión en español: [../es/adr/ADR-013-realm-administration-from-the-app.md](../es/adr/ADR-013-realm-administration-from-the-app.md)*

## Context

Today a realm is administered only from its host.
- **Invitations.** `arveil-relay invite` opens the relay database directly, so creating one requires a shell on the host: SSH, `podman exec` or `docker compose exec`.
- **Nothing else exists.** There is no command to list or revoke invitations, list members or remove anyone.
- **Roles are stored but unused.** The invitation's `-role` is copied into `realm_memberships.role`, and nothing reads it.
- **No administrative frames.** The relay has none. Its admin listener serves only `/healthz` and `/metrics`.
- **A designed credential was never built.** The design called for an "independent administrative credential" ([Protocol §3](../PROTOCOL.md#3-realm-bootstrap-and-identity), [architecture](../ARCHITECTURE.md)), and said administrative frames would be accepted only on endpoints of kind `admin`. Neither exists.
- **A name clash.** The app calls the device holding the personal root the "administration device", which has nothing to do with administering the realm.

For a family realm this means one person with a terminal onboards everyone else, one SSH session per invitation.

What self-hosted services do: the owner is established once at installation and administers from the app. The host keeps a command for emergencies. Examples are Matrix/Synapse (admin API plus `register_new_matrix_user`), Home Assistant, Jellyfin and Gitea (`gitea admin`).

## Decision (proposed)

### 1. Roles belong to identities

`realm_memberships.role` becomes `owner`, `admin` or `member`.
- **Authority belongs to the identity, not to one device.** Any active device credential of that identity authenticates through its Noise session. Revoking a device ends that device's power, and a lost device does not take the role with it.
- **What each role may do:**
  - `owner` does everything and is the only role that changes roles;
  - `admin` invites and removes members;
  - `member` does neither, unless the realm allows members to invite (see the open questions).

### 2. The first owner is claimed with an invitation, not by connecting first

"Whoever connects first becomes the owner" is a race whenever the relay is reachable before its operator joins. Instead:
- `arveil-relay invite -role owner` creates the owner invitation on the host and prints the `join` link and QR of [ADR-012](ADR-012-qr-codes-and-links.md).
- On start, a relay without an owner logs a hint to run that command. It does not log the secret itself.
- Redeeming the invitation makes that identity the owner.

This is the one step that needs the host, as the first invitation needs it today.

### 3. Administrative frames

These frames are accepted only on member sessions whose identity holds the required role:

| Frame | Role | Effect |
|---|---|---|
| `invite_create {role, ttl, uses}` | admin, owner | Returns a token. The client builds the `join` link from the realm it already knows. Limits: `ttl` ≤ 7 days, `uses` ≤ 10, `role` ≤ the caller's |
| `invite_list` | admin, owner | Returns, for each invitation: a short prefix of its hash, role, expiry, uses left, and the identities that redeemed it |
| `invite_revoke {prefix}` | admin, owner | Deletes an unredeemed invitation |
| `member_list` | admin, owner | Returns identity ids, roles, status and join date. The relay already holds all of these |
| `member_remove {identity}` | admin (members only), owner | Marks the membership removed, closes its sessions and refuses its devices |
| `role_set {identity, role}` | owner | Changes a role; the last owner cannot be demoted |

**Actions that need the root.** `member_remove` and `role_set` must also carry a statement signed by the caller's root: `SignedObject` with the context `arveil/realm-admin/v1` and the body `{realm_id, action, target, expires, nonce}`.
- The relay checks it against the root stored for that membership.
- A stolen linked device can therefore invite, which is bounded and revocable, but cannot remove people or grant roles.
- The client builds the statement itself, with its own context. It is not a signature over bytes chosen by the server, which [Protocol §3](../PROTOCOL.md#3-realm-bootstrap-and-identity) forbids.

**Restricting the endpoints.** An option `-admin-frames any|admin-endpoints` limits these frames to endpoints of kind `admin`, for example a tailnet. The default is `any`, so a family administrator can invite from anywhere. This replaces the unconditional rule in [Protocol §3](../PROTOCOL.md#3-realm-bootstrap-and-identity).

**Limits and audit.**
- An administrator may create at most 20 invitations a day. At most 50 invitations can be open at once.
- The relay records each administrative action with the actor's truncated identity id, the action and the time. It never records names. `admin_log` returns the record, and the app shows it.

### 4. What administration cannot do

This record changes who decides admission, not what admission means ([ADR-003](ADR-003-zero-trust-server.md), [ADR-005](ADR-005-cryptographic-identity.md)). An owner or admin cannot:
- read messages;
- sign devices for other identities;
- fabricate or replace keys;
- see names or contacts.

Removing a member stops this relay from serving them. It does not remove them from MLS groups: the other members of each group do that.

### 5. Recovery, in order

1. **Another device of the same identity** keeps the role.
2. **The identity kit** restores the identity, and with it the role.
3. **A second owner.** The app suggests that an owner name another owner, such as a family member, so the realm never depends on one person.
4. **The host, over SSH**, for emergencies:
   - `arveil-relay invite -role owner` creates a new owner invitation;
   - `arveil-relay member list`, `member role` and `member remove` act on the database directly, for example to demote an identity whose devices were stolen.

### 6. Naming in the app

The device that holds the personal root becomes the **main device** in the interface. "Administrator" and "administration" are kept for the realm.

## What each party learns

| Party | Learns | Does not learn |
|---|---|---|
| The realm | Roles, the administrative actions and who performed them. It already knew every membership | Names, contacts or message contents |
| Owners and admins | The member list: identity ids, roles and dates, which the relay already has | Names, unless the members are also their contacts; messages |
| Members | Nothing new | Who administers, unless told |

## Alternatives

| Alternative | Reason not to adopt it |
|---|---|
| SSH only, as today | Works, but one person with a terminal onboards everyone |
| The first identity to connect becomes the owner | A race whenever the relay is reachable before its operator joins |
| A separate administrative password or credential | Another secret to lose and to protect; a stolen password acts without any device |
| A web administration panel on the relay | A new attack surface on the component that must hold the least |
| Every administrative action signed by the root | Invitations, the common action, would need the main device every time |

## Consequences

- **Relay:** new frames, a role check, an audit table and `member` subcommands. Invitations gain a creator.
- **Client:** an Administration section, visible only to owners and admins, with invitations, members and the log; root-signed statements; the renaming of the main device.
- **Protocol text:** [Protocol §3](../PROTOCOL.md#3-realm-bootstrap-and-identity) and the [architecture](../ARCHITECTURE.md) are updated to describe roles on identities instead of a separate administrative credential.
- **Realm redundancy:** a replica must replicate roles and the audit record, as it already must replicate invitation consumption ([ADR-007](ADR-007-optional-realm-redundancy.md)).

## Acceptance criteria

1. **Invitations.** An owner creates an invitation in the app and a new person joins with its link. A member without the role is refused `invite_create`.
2. **Revocation.** A revoked invitation cannot be redeemed, and the list shows every invitation's state.
3. **Actions that need the root.** `member_remove` and `role_set` without a valid root statement are refused, including when they come from a linked device of an owner.
4. **Recovery.** With every device and the kit lost, a new owner invitation from the host works, and the old owner can be demoted from the host.
5. **Privacy.** No name appears in the relay's database, logs or audit record; identifiers are truncated.
6. **Restricted endpoints.** With `-admin-frames admin-endpoints`, administrative frames are refused on other endpoints.

## Open questions

- Whether members may invite, and whether their invitations need an administrator's approval.
- Whether removal should also ask the removed person's groups to remove them, or leave that to their members.
- How long the audit record is kept.
