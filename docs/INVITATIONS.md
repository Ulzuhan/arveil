# Personal invitations: implementation and rollout

October 1, 2026 · implemented on `codex/invitation-onboarding`; **not published**.
[Español](es/INVITATIONS.md) · [Detailed plan and acceptance matrix](es/INVITATION_ONBOARDING_PLAN.md).

## The user journey

In Contacts, choose **Invite someone**. An authorized owner can create a private,
single-use invitation valid for seven days, share it through the system, copy it
or display its QR. Opening or scanning only previews the invitation. The person
accepts explicitly; the app enrolls their independent identity, adds the inviter
and prepares one conversation. It copies no previous history and does not mark
either person verified. Existing members of the same realm keep their identity
and role. Another realm or the user's own invitation is refused.

A fresh installation offers scanning/pasting before requiring server details.
Older admission-only invitations retain a separate entry. After installing from
a website or store, return to the original link or scan again: there is no
cross-install attribution service. Play testing eligibility is separate from
relay admission. The web companion changes are prepared in `kaicorplabs-web`
(`/join`, `/install`, `/es/instalar`); deployment is still pending.

The inviter may be offline during acceptance. Reopen **the device that issued
the invitation** and synchronize to receive the contact. Other active devices
of the owner can list metadata and revoke, but cannot recover that device's
secret, reshare its link or receive its first chat through this feature.
Notifications are optional and are not an enrollment requirement.

## Owner setup for an existing realm

Owning the personal identity root does not confer relay administration. Only
active members with the literal role `owner` issue/revoke; legacy `admin` and
ordinary `member` cannot. No migration chooses an owner automatically.

After reviewing and deploying the relay update, compare the full public
identity ID shown in **Invite someone → permission details** with the intended
existing member. On the relay host, using the service account and its data path:

```sh
arveil-relay make-owner -data-dir /path/to/realm-data -identity FULL_64_HEX_ID
```

This changes only that existing active membership and records an audit event.
It neither replaces the person's identity nor grants a remote role-editing API.
Reopen the invitations screen to refresh permission. The ordinary `invite` CLI
remains available for legacy enrollment. **No live owner was promoted during
implementation.**

## Wire contract

These exact CBOR variant names are implemented inside the authenticated Noise
channel, not as public HTTP endpoints. Bytes are CBOR byte strings; empty byte
fields are `h''`, not null. Empty lists are arrays.

| Request | Input | Reply and authorization |
|---|---|---|
| `InvitePolicyGet` | Unit variant | `InvitePolicy {can_invite, server_time, ttl}`; active member |
| `InviteCreate` | `request_key: bytes24, token_hash: bytes32, ttl: u64` | `Invitation`; owner, admits one `member`, TTL 1–604800 seconds; app requests 604800 |
| `InviteList` | `cursor: u64, limit: u16` | `Invitations {invitations, next_cursor}`; own issuer identity only, limit 1–50 |
| `InviteGet` | `invitation_id: bytes32` | `Invitation`; issuer or recorded claimant |
| `InviteRevoke` | `invitation_id: bytes32` | `Invitation`; owner and original issuer; idempotent before use |
| `InviteAccept` | `token: bytes32` | `Invitation`; same-realm active member, spends the use without changing membership |
| `KeyPackagesClaimOnce` | `request_key: bytes24, identity_id: bytes32, device_id: bytes16` | Existing `KeyPackageClaimed`; active member, durable single package per request |

`Invitation` wraps `invitation`. Each record has `sequence: u64`, `id: bytes32`
(SHA-256 of the admission token), `created_at/expires_at/claimed_at: u64`,
`state: pending|used|revoked|expired`, and `claimed_identity: bytes32` (empty
before use; `claimed_at=0`). Dates are Unix seconds. The cursor is the last
sequence returned; sequences increase globally, but results are issuer-scoped.
New identities still use `InviteRedeem`, which updates the personal receipt in
the same transaction. Replaying acceptance is bound to the same credential,
not just identity, so two linked devices cannot independently claim its chat.

A request key consists of eight big-endian timestamp bytes obtained from server
policy plus sixteen cryptographically random bytes. A new request is accepted
within seven days, with at most five minutes of future skew. An existing receipt
is checked first: the same actor/key/parameters returns the original result;
a different target or parameters conflicts. After cleanup, a stale key cannot
create a new invitation or consume another KeyPackage. Do not rotate a key in
response to an uncertain network result.

Every action rechecks current credential/membership/role, including on existing
sessions. Limits: 20 new invitations/issuer/24 hours, 50 pending/realm,
60 attempts/session/minute and 120/address/minute (including refusals);
100 successful durable KeyPackage claims/credential/24 hours.
Errors: 400 invalid request (an old relay also rejects unsupported variants),
401 provisional session, 403 permission, 409 conflicting request/already used,
410 unavailable invitation/no KeyPackage, 429 quota. UI maps these to fixed
localized reasons and does not display arbitrary relay text or secrets.

## Link version and trust

V1 join/contact/link cards remain readable. Personal invitations use `version: 2,
kind: "join"` with the usual realm keys/URL, `invitation: bytes32`, `expires_at`
and compact `contact` tuple in this order:

```text
[device_id:16, credential_hash:32, identity_root:32, mailbox_id:16,
 write_capability:32, hpke_public_key:32, contact_secret:16, name:text|null]
```

The canonical CBOR limit remains 600 bytes, the URL limit 128 characters and
name limit 64 UTF-8 bytes. Old clients reject version 2 instead of silently
redeeming only half the operation. Worst-case name/URL payload and synthetic QR
render/decode are tested; physical scanning remains an acceptance gate.

The URL fragment stays in the browser; the companion page does not send it in
HTTP requests or analytics. A share recipient/provider can still see the full
link. It is a bearer invitation: the first eligible claimant wins, including
someone it was forwarded to. Names are self-descriptions, not authentication.
The recipient validates root-signed credentials, active manifest and matching
MLS keys. The inviter only auto-accepts when the encrypted hello's secret and
invitation hash match its local operation, the relay receipt names that sender,
and the MLS leaf matches the validated credential. Missing proof remains an
ordinary request. An already declined request is never automatically accepted.

## Durability, privacy and retention

Relay schema **4 → 5** adds issued invitation metadata/audit and durable package
claim receipts. Profile schema **7 → 8** adds invitation operations and candidate
hellos. Migration does not change existing identities or contact verification.
The relay learns the issuer/claimant relationship, issuance/use/revocation times,
and claimed package target. It does not receive the contact secret, names or
conversation contents through these APIs.

The encrypted profile stores the exact link/token/contact secret before a
network effect. Flutter holds transient display state, not another token store.
Identity kits and conversation archives do not export this operation table.
An encrypted whole-profile backup may contain unfinished invitation secrets and
needs the same protection as the profile; deletion in the current profile does
not erase old backups or the recipient's shared copy.

Recipient: `accepting → enrolled → prepared → complete`. Issuer: `issuing →
pending → used → connected`, plus `revoke-pending`, `revoked` and `expired`.
The executor serializes enrollment and sync mutations. Claimed package bytes
are saved before MLS; MLS, conversation, outbox and operation→group mapping
commit together. A retry uses the same package/group/outbox. Completion means
publication to the relay succeeded, not that the peer read or fetched it.

An uncertain failure retains progress. Definitive rejection before admission
releases only that enrollment marker and allows another invitation while
preserving the identity. An admitted user retains membership if contact setup
fails. Revocation is pending until confirmed; if a valid acceptance won the
race it remains used, and is not represented as revoked.

Managed relay invitation records remain until both expiry and claim time are
more than 37 days old. Package claim receipts/audit retain 37 days from creation.
Existing admission replay receipts retain their existing policy. This exceeds
the current 30-day envelope retention. Local outgoing proofs/metadata are
cleaned on listing after expiry +37 days. Incoming completion removes link,
secret and package while retaining the minimal ID→group mapping. Unfinished
incoming operations are retained for explicit resumption. This is logical
cleanup, not a promise to erase filesystem snapshots or all SQLite free pages.

## Validation recorded on October 1, 2026

- Go race suite and migration/permission/quota/claim/revoke tests pass, including
  migration from schema 4, consistent backup and reopening a receipt.
- Rust workspace tests and Clippy pass; profile migration, encrypted reopen,
  rollback of operation mapping, v1 compatibility and largest v2 QR pass.
- Real Go↔Rust disposable-relay tests cover a new recipient while the inviter is
  closed, relay restart, repeated links, same-realm members, rejected token
  replacement, offline/reopened concurrent resume, offline revocation surviving refresh,
  and a pruned receipt leaving
  an ordinary request without blocking sync. CI runs these explicitly.
- Flutter analysis and 303 tests pass, including explicit consent, disabled
  double-submit, saved progress, permissions, localization/accessibility and
  updated contact-screen goldens. Android arm64 debug APK and macOS debug app
  build. These are development builds, not released/signed acceptance artifacts.

Web validation: local pages pass at 11 viewport widths (320–1920 px), in
Spanish and English, with the synthetic fragment preserved on the app link and
absent from HTTP requests. Lighthouse: install guides 99/100/100/100; join
99/100/100/66 because its existing intentional `noindex` fails crawlability.
No privacy setting was removed to improve SEO. Live deployment/certificates
remain unverified by this local run.

Reproduce the cross-language test from the repository root:

```sh
go -C relay build -o /tmp/arveil-invitations-relay ./cmd/arveil-relay
cd core
ARVEIL_TEST_RELAY=/tmp/arveil-invitations-relay cargo test -p arveil-app --test invitations --locked -- --ignored
```

Still open: kill/lost-response injection at every network/commit boundary,
physical maximum-size QR and denied-camera journey, fresh installation from
WhatsApp/Play/direct APK, Play-signing App Links, full backup **restoration**
drill, another linked issuer device, and signed candidate acceptance. Issuer
loss/revoked route or a resume beyond receipt retention needs explicit recovery;
there is no automatic route transfer or safe abandonment button for an uncertain
operation. Optional per-invitation local labels are not implemented. These gaps
keep P7/P8 open; local tests do not satisfy A01–A18 wholesale.

## Rollout and rollback

1. Review the feature against its base `codex/files-notifications` (PR #141),
   which depends on `codex/android-qr-pairing` (PR #139). Publishing beta 5 did
   not merge those branches.
2. Complete the remaining integration/physical gates and restoration drill.
   Back up the live realm consistently using the existing backup command, and
   preserve profile backups before first open by the new client.
3. Deploy the compatible relay first; verify health, legacy admission and
   schema 5. Promote the intended owner by exact ID, then test issuance.
4. Deploy compatible web guidance and verify links with the actual signing
   certificates. Package a new version/build; never reuse build 26.
5. Accept on a fresh physical Android and packaged Mac, then publish the chosen
   Play/cask/feed candidate. Record source, hashes, device and results.

Do not run an old binary on schema 5/8 databases. Prefer a forward fix; restoration
requires matching binary/data and agreement about changes made after the backup.
A lower feed version cannot downgrade an installed client. Live deployment,
owner promotion and publication have not been performed by this feature change.
