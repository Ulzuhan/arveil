# Plan: one invitation, from installation to the first conversation

Date: October 1, 2026. **Current product priority within M3b.2/M3b.5. Implementation available for review; integration acceptance and publication remain open.**

The [Spanish plan](es/INVITATION_ONBOARDING_PLAN.md) is the normative, detailed specification, with decisions D1–D8, blockers B1–B15 and acceptance cases A01–A18. This English summary must stay aligned in the same review. The [implementation record](INVITATIONS.md) closes D1–D8 with exact wire contracts, evidence and remaining gates. Requirements below describe the complete milestone, not a claim that every acceptance case has passed.

Inspected base: `f5dfd190b97f13de694c91a7cf4b5257ca59cc26`, the source of beta 5/build 26. Preparation branch: `codex/invitation-onboarding`. Publishing that beta did not merge its source PRs; recheck dependencies before implementation and preserve unrelated local work.

## Intended experience

A member who is allowed to invite chooses **Invite someone**, shares one HTTPS link through the system share sheet or displays its QR. A recipient without Arveil installs it, returns to that link, reviews the invitation, creates their independent identity and reaches a conversation with the inviter. No manual server fields or second contact-card exchange.

The inviter can close the app after issuing the invitation. The relay must remain reachable, and completion is received when the inviter syncs again, within retention limits. This does not promise push delivery, permanent availability or simultaneous online presence.

Linking another device remains a separate flow for the same identity. Admission grants no history, groups, other contacts or administrative privileges. Identity-kit export is offered with an explicit deferral; notification setup is not an onboarding gate.

## Foundation inspected before implementation

- The relay CLI already emits one-use join links/QRs, defaulting to 24 hours. App-based issuance is missing. Membership roles are stored but do not authorize an administrative API; ADR-013 is still proposed.
- `Card::Join` has only realm and invitation; `Card::Contact` has the route, secret and optional self-description. A combined version and coordinator are needed.
- Enrollment already persists phases and hashes and retries the same redemption idempotently. It does not retain the invitation token. Incoming Flutter links are memory-only.
- `start_with` commits MLS, conversation and outbox together, then publishes. It does not map an invitation operation to that committed conversation, so retrying the whole operation needs a new durable guard.
- Contact cards require the same realm. Their current ten-minute in-person and thirty-day shared-link policies do not define invitation lifetime.
- The relay sweep removes exhausted/expired invitations. A useful invitation list requires retention changes without breaking redemption receipts.
- The website has join/open/copy pages, but installation instructions still describe two separate strings. Play currently uses internal testing: installation eligibility and relay admission are separate.

Update ADR-012, the invitation subset of ADR-013, protocol, domain and threat model. Do not label the entire administrative panel implemented when this milestone ships.

## Scope and product decisions

Included: issue/list/revoke personal invitations on Mac/Android, sharing/QR/paste, new enrollment, acceptance by an existing identity in the same realm, associated contact/chat, restart recovery, migration, website guidance and physical-device acceptance.

Excluded: federation, silent realm switching, public reusable invitations, automatic groups, member removal/role editing from the app, history recovery, Mac camera, iOS, notification redesign and general multi-device contact synchronization. Outstanding beta 5 acceptance remains open.

| Decision | Contract selected for this implementation |
|---|---|
| D1 Permission | Owner-only issuance in this release; active devices of that identity may issue, always admitting a member. No implicit authority for legacy admin roles. |
| D2 Existing owner | Explicit host-side promotion of the existing identity, checked against its app identity. No new identity required, first-connection race or shared admin password. |
| D3 Lifetime | One use, seven days default and initial maximum; absolute server expiry never extends on retry or QR display. |
| D4 Contact consent | Issuance and recipient confirmation authorize this personal conversation. Auto-accept requires the invitation proof bound to the claiming identity and validated MLS sender. Otherwise retain a request. |
| D5 Verification | Invitation scanning alone does not verify a human; camera input can be a forwarded image. Keep separate verification and existing contact-card behavior. |
| D6 Encoding | Explicit new join version, preserving v1 readers for existing links. No silently ignored contact fields in old clients. |
| D7 Retention | 37-day receipt/proof retention; exact cleanup anchors and minimal completed mappings are specified in INVITATIONS.md. |
| D8 Installation | Return to the original link after installing. Play for eligible testers, direct APK alternative. No secret in Install Referrer, URL shorteners or attribution services. |

D1–D8 are closed for this candidate in the implementation record. D1 is intentionally narrower than ADR-013. Holding a personal root does not make its holder a relay owner.

## Screens and state handling

Inviter: Invite someone → query permission → Create → relay confirms → Share/Copy/Show QR/Revoke. Labels remain local and are not authenticated recipient names. Without permission, explain the limitation and retain ordinary sharing with existing members.

Recipient: open link → install if necessary → return → review/consent → protect profile and choose optional name → enroll/claim → prepare conversation → send. Server details are available without being mandatory input. Merely opening/scanning or a messaging preview must never redeem.

| Recipient state | Expected result |
|---|---|
| New profile | One identity, membership and conversation. |
| Same-realm member | Claim this invitation using the existing identity; consume its personal use without adding membership or changing role. |
| Same operation interrupted | Continue durable progress. |
| Different enrollment underway | Explain conflict; preserve it. |
| Different realm | Explain incompatibility; do not replace profile or silently create another. |
| Own invitation | Reject before creating a chat. |
| Operation already completed | Open its existing conversation. |

Android scans, opens or pastes. Mac displays and opens/pastes. Installing via a QR must not inherit the ten-minute expiry of a contact verification screen. Denying camera access leaves paste/open usable.

## Technical requirements and selected contracts

### Relay and persistence

Implemented frame family (exact shapes in INVITATIONS.md): `InvitePolicyGet`, owner-only `InviteCreate {request_key, token_hash, ttl}`, issuer-scoped paginated `InviteList`, idempotent `InviteRevoke {invitation_id}`, and authenticated `InviteAccept {token}` for existing members. Keep new-user `InviteRedeem` and its existing token/identity/credential replay contract.

Generate tokens with Rust cryptographic randomness and persist them in the encrypted profile before issuance. The relay stores hashes. Equivalent issuance retries return the same expiry; altered parameters conflict. Bound request-receipt retention and prevent an old cleared request from becoming a fresh emission. Save the confirmed result before sharing; cancelling the share sheet neither revokes nor reissues it. Authenticate role, membership and credential at each action, even on an open session. Use full identifiers for mutations. Transactional quotas: twenty emissions per identity per 24 hours and fifty pending per realm, plus bounded attempt rates. Redeem, existing-member claim and revoke must race atomically.

Add versioned migrations from inspected relay schema 4/profile schema 7; now relay schema 5/profile schema 8. Separate terminal invitation history from redemption replay receipts. The relay learns issuer/claimant correlation: document that metadata change without claiming it learns no relationship. Names, labels, contact secrets and message content remain client-side.

Storing the accepted token encrypted changes today's hash-only enrollment policy and needs an explicit rationale, deletion rules and backup exclusions. Before the recipient protects/opens a profile, reopening the external link is the fallback; never persist it in plaintext preferences. Dart remains a projection of Rust state.

### Payload and coordinator

The combined payload carries realm/current endpoint, admission token, expiry hint, inviter route, independent one-use contact secret and optional declared name. Validate the route through the existing root-signed credential, active manifest and matching KeyPackage before use. If validation fails after admission, preserve the created identity and report the blocked contact step.

Resolve the size gate first: current Rust limit is 600 bytes, website fragment limit 1100 characters, with separate native/text limits. Produce worst-case UTF-8 name/URL vectors and physical QR trials. Version and bounds must agree across Go/Rust/Dart/web; prefer reducing encoding over introducing secret storage on a website.

One coordinator in `arveil-app` owns durable state under the profile executor. Persist consent before any token-consuming call. Recipient phases: consent saved → redeem/claim → enrolled → contact validated → conversation prepared → publish pending → published. Network errors retain phases; terminal reasons are typed. Issuer phases distinguish prepared/issuing/active/claimed/contact-established, expired and revocation-pending/revoked.

Commit operation-to-group mapping with MLS, conversation and welcome/roster/hello outbox in one unit of work. Persist claimed KeyPackages before constructing the group. P0 must resolve lost claim replies with a bounded idempotent claim design or a tested recovery contract; blind retries must not exhaust packages. After local commit, retry the same outbox rather than starting a second chat.

Auto-accept only the invitation proof bound to the verified sender and claiming identity; duplicates/out-of-order events must not duplicate contacts or notices. Human verification remains separate. A relay assertion does not authenticate a human or replace cryptographic credential checks.

### Expiry, revocation and multiple devices

A confirmed redemption before expiry can complete after expiry; use the receipt, not arrival time or a client-asserted timestamp. Revocation before claim blocks use; after claim reports already used and does not expel the person. Offline revocation remains visibly pending until server confirmation. If a prior valid claim won the race, retain the completion proof and resolve as already used, not as a permanently blocked contact. Revoking a card secret does not revoke the existing mailbox write capability.

Align local proof retention with the relay's current initial maximum envelope retention of thirty days and effective delivery expiry. Unavailable KeyPackages, revoked inviter routes and outages keep the recipient's enrolled identity intact.

Roles are identity-wide, while current card routes/secrets are device-local. Minimum delivery supports completion on the emitting device after reopening. Another linked owner device may list metadata/revoke but cannot reconstruct an absent secret. Test issuing on Mac and reopening only the linked phone; do not claim cross-device completion unless explicitly implemented with encrypted synchronization.

## Blockers and phased implementation

| Blocker group | Resolution gate |
|---|---|
| B1–B2: existing owner and permission policy | Explicit promotion and server-side authorization tests, including legacy and revoked credentials. |
| B3: payload/version/QR limits | Canonical vectors, old/new matrix and worst-case physical scanning. |
| B4–B7: secret persistence, lost replies, duplicate chats and existing-member claim | Fault injection around each durable/network boundary, single operation/membership/chat, atomic races. |
| B8: expiry and delayed delivery | Retention contract and receipt-based late acceptance. |
| B9–B10: Play eligibility and verified links | Eligible/ineligible account flows, Play signing versus upload/direct certificate checks, open/paste fallback. |
| B11–B12: offline inviter/key exhaustion and forwarded invitation | Bounded retry, validated routes and identity binding; no false verification. |
| B13–B15: migration rollback, privacy and hardware | Consistent backup/restore drill, secret-free diagnostics, clean physical installation. |

The Spanish table specifies every blocker, evidence and dependent phase. A blocked contract may delay its dependants; it cannot be silently omitted from acceptance.

| Phase | Deliverable and exit |
|---|---|
| P0 Contract (M) | Close D1–D8, schema/retention, QR vectors, lost MLS claim, multi-device behavior and errors before implementation. |
| P1 Relay/owner (L) | Promotion, policy/create/list/revoke/accept, quotas/audit/migrations; authorization, race/restart and legacy tests. |
| P2 Format (M) | Combined codec/QR/version with cross-language vectors and bounds; new reads v1, old refuses v2 clearly. |
| P3 Durable coordinator (L) | Encrypted operations, snapshots and lifecycle; kill/reopen per phase, one identity/mailbox/invitation. |
| P4 Contact/MLS (L) | Operation→chat, bound hello, durable claims/outbox; offline inviter, no duplicates, late acceptance and adversarial tests. |
| P5 Flutter/bridge (M/L) | Invite management, contextual onboarding, accessible retries, EN/ES and generated bindings; native/widget checks. |
| P6 Website/install (M) | Join page, return-after-install, Play/APK and certificates, EN/ES guidance; privacy and mandatory Lighthouse checks. |
| P7 Candidate integration (M) | Disposable migrated relay and signed clients, interop/CI/package checks, rehearsed rollback. |
| P8 Physical acceptance/deploy | New person from WhatsApp and QR, clean phone + packaged Mac, operator owner setup and controlled rollout. |

Dependencies: P0 → P1/P2 → P3 → P4 → P5 → P7 → P8; P6 starts after P2 and joins before P8. M/L mean relative change size, not calendar commitments. Suggested reviews follow those layers; no partial PR enables a flow whose dependencies are unavailable. This dependency graph does not authorize delegation or premature deployment.

## Acceptance and rollout

The normative matrix has A01–A18: clean WhatsApp/QR installation, denied camera, offline inviter, network loss/kill at every commit, duplicate clicks and races, revocation, timely redemption with late hello, existing/different/self identity, authorization, altered payload/MLS sender, exhausted/lost KeyPackages, migration/clocks/cleanup, compatibility, real signing, secret-free diagnostics, accessibility/localization and linked-device limitations.

Run affected Go race/store/server/codec, Rust parser/migration/executor/MLS and interop fault tests; Flutter/native flow and link tests; strict docs/hygiene; full CI before packaging. Evidence names exact source/build/system/device and contains no live invitations. Isolated transport tests do not replace the full new-person journey.

Rollout: settle branch dependencies → disposable migration/restore drill → consistent operator backup → backward-compatible relay first → explicit promotion of existing owner → compatible website and certificates → signed physical candidate → new Play/cask/feed versions. Never reuse build 26. A SQLite WAL deployment needs a consistent backup, not a blind copy of its main database file.

Rollback pairs compatible binary/data or uses a forward fix; old binaries must refuse newer schemas. Explain post-backup data loss before restoration. Rolling back a feed cannot downgrade installed clients: distribute a higher corrective build. Pause new issuance if needed while preserving valid pending progress when safe.

## Current status

P0 contracts are closed. P1–P5 are implemented with automated evidence; P6 companion pages are prepared locally. P7 is partially validated and P8 remains open. See [implementation and remaining gates](INVITATIONS.md): nine Go↔Rust scenarios now cover 22 persistence failures with abrupt process exit, compatible backup restoration and a linked issuer device; native Mac/emulated Android acceptance and relay rollback with the prior binary/backup also pass. The operator procedure preserves the endpoint counter. Signed/physical acceptance remains open; no schema/client-profile downgrade is claimed. These tests do not claim to cover every possible dropped network packet. Production owner promotion, deployment and publication have not occurred. Optional local labels and cancellation of uncertain enrollment are not implemented; resumption preserves progress.

External references checked October 1, 2026: [Android App Links](https://developer.android.com/training/app-links/about), [Google Play testing access](https://support.google.com/googleplay/android-developer/answer/9845334), and [SimpleX invitation experience](https://simplex.chat/invitation/). These inform platform behavior and UX, not Arveil protocol guarantees.
