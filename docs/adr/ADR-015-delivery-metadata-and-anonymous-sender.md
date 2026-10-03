# ADR-015 — Delivery metadata and an anonymous sender

- **Status:** part 1 (delivery metadata at rest) implemented on 2026-10-02 as relay schema 6, not yet deployed. Part 2 (anonymous sender) is proposed and waits for the conditions it lists. Part 3 records non-goals.
- **Date:** 2026-10-02.
- **Scope:** what the relay can relate between senders, mailboxes and people, in its database and while it runs, and which reductions are worth their cost in a family realm.

*Versión en español: [../es/adr/ADR-015-delivery-metadata-and-anonymous-sender.md](../es/adr/ADR-015-delivery-metadata-and-anonymous-sender.md)*

## Context

SimpleX Chat is designed so that its servers cannot relate the queues of one user. We asked whether Arveil could do the same. This is what links things today, read from the relay schema on 2026-10-02:

| Source | In the database (stolen database or backup) | While running (an operator instrumenting the relay) |
|---|---|---|
| Owner of each mailbox | Stored: `mailboxes.owner_identity`, `owner_device` | Yes |
| Sender of each envelope | Not stored: `envelopes` has no sender column | Yes: every `EnvelopePut` arrives on a member session ([protocol §4](../PROTOCOL.md#4-contact-verification-and-routes), V1) |
| Recipients of one message | **Reconstructible.** `seq` is one autoincrement for the whole realm and `expires_at` is the arrival time plus the TTL, to the second. A message to N devices leaves N consecutive rows with the same expiry | Yes: a burst of puts on one session |
| Attachments | Uploader and exact time: `blobs.owner_identity`, `created_at` | Uploader and downloaders |
| KeyPackage claims | Only that a package was consumed | Who claims whose package |
| IP and connections | Not stored by the relay; a proxy may log them | Yes |

There is also a small leak to members: the fetch cursor is the realm-wide `seq`, so a device can tell how much the whole realm received between two fetches.

In a realm of five to ten people, an operator who watches timing and IP addresses can usually reconstruct who writes to whom whatever the protocol does: there are very few people to hide among. SimpleX's design works partly because each server has thousands of users. It also relies on queues created without accounts, a second server on the sending path (private message routing) and optional per-queue transport isolation or Tor. An Arveil realm is membership-based by design ([ADR-003](ADR-003-zero-trust-server.md), [ADR-013](ADR-013-realm-administration-from-the-app.md)): it knows who its members are. The question is therefore narrower: how much the realm learns about **who talks to whom**.

## Decision (proposed)

### Part 1 — Delivery metadata at rest (next relay release)

The cheap, real gain is in what a stolen database or backup reveals.
- **Per-mailbox sequence.** Envelopes move to `queued_envelopes`, numbered by each mailbox's own counter (`mailboxes.next_seq`) under a random row id, so neither the cursor nor the order of rows follows arrival across the realm. A table without a rowid was considered and set aside: SQLite advises against it for rows as large as an envelope.
- **Cursor migration.** Migrated envelopes keep their numbers, and each mailbox's counter starts above the highest number the old table ever handed out, including envelopes already acknowledged. Every cursor a client holds stays valid, and nothing is skipped or repeated. The old realm-wide numbers leave with their envelopes, within one retention period.
- **Coarse expiry.** `expires_at` is rounded down to a UTC day for lifetimes of two days or more, to the hour for two hours or more, and to the minute for two minutes or more; rounding never takes more than half the lifetime away. The protocol already allows a shorter effective expiry, declared in the `EnvelopeAccepted` answer.
- **Blobs.** `created_at` is kept to the hour, so an upload left in staging is removed after 23 to 24 hours. The committed expiry gets the same rounding as envelopes, and the file's modification time is set to that hour; its change time cannot be set and remains. `owner_identity` stays, because the per-member quota needs it; this is documented as a residual.
- **Shuffled fan-out.** The client sends the copies of one message in random order, so the sender's own devices are not always first or last.

This does not hide sizes (padding buckets reduce their precision), nor timing from anyone watching the relay live. SQLite pages, the WAL and free pages may keep traces of insertion order. The goal is ordinary queries and backups, not forensic resistance.

### Part 2 — Anonymous sender profile (waits for its conditions)

**Design.**
- **Anonymous session.** A device may deliver from a session whose Noise static key is fresh, used once and unknown to the realm. Such a provisional session already exists for redeeming invitations and pairing. Its only new permission is `EnvelopePut` with a valid write capability and one anonymous token.
- **Tokens.** Member sessions obtain batches of single-use tokens through a Privacy Pass issuance ([RFC 9576](https://www.rfc-editor.org/rfc/rfc9576), [RFC 9578](https://www.rfc-editor.org/rfc/rfc9578)). Issuer and verifier are the same relay, so the privately verifiable VOPRF type fits. Issuance is limited per identity and per day. Redeeming a token does not reveal which member received it. Spent tokens are kept by hash until they expire.
- **One anonymous session per message.** The copies of one message share an anonymous session. While running, the relay still sees that those mailboxes received the same message, but not from whom.
- **Libraries.** This needs reviewed implementations in Rust for the client and in Go for the relay, with no ad hoc construction. Until they exist with enough quality, this part stays blocked.

**What it changes, honestly.** The relay process no longer receives the sender's identity with each delivery: logs, metrics, crash dumps or a relay modified to record sessions do not get it directly. Against an operator who looks at IP addresses and timing it adds little. The same phone usually keeps its member session open from the same address at the same moment, so the operator can match both sessions. Signal's sealed sender has the same limit.

**When to adopt it.** Any of these:
- contacts in other realms are designed: a sender who is not a member of the destination realm cannot deliver today, and an anonymous profile with tokens is the natural way to allow it;
- realms grow well beyond a family;
- an independent review asks for it.

### Part 3 — Non-goals

- **Unlinkability of a person's mailboxes**, meaning per-contact queues read without authentication. It requires reworking revocation (M2.3 revokes a device's mailboxes by owner), quotas and activity notices. The single watch session per device of [ADR-014](ADR-014-relay-activity-notices.md) would relate them again, and without hiding IP addresses the gain disappears.
- **Hiding IP addresses from the realm**, with Tor or a second relay from another operator as a proxy. High cost in battery, latency and operation, and still weak in small realms.

Reopen if realms with many unrelated users appear, if operators federate, or if a trial shows a need. The [threat model](../THREAT_MODEL.md#non-goal-unlinkability-of-a-persons-mailboxes) records that unlinkability is not a goal in small realms, so nobody assumes it.

## What each party learns

| Party | Today | After part 1 | After part 2 |
|---|---|---|---|
| Thief of the database or a backup | Mailbox owners; recipients of one message by consecutive rows and identical expiry; uploader and exact time of each attachment | Mailbox owners; arrival day or hour per mailbox; uploader of each attachment | Same as part 1 |
| Operator instrumenting the relay | Sender session of each delivery, recipients, IP addresses, timing | Same | Recipients of one message, IP addresses, timing; the sender only by matching IP and timing |
| Other members | Volume of the whole realm between two fetches | Only their own mailbox | Same as part 1 |

## Alternatives

| Alternative | Reason not to adopt it |
|---|---|
| Copy SimpleX's model: anonymous per-contact queues, private routing, transport isolation | Breaks revocation, quotas and notices, and does not protect against an operator in a small realm without hiding IP addresses |
| Sealed sender now, without tokens | Without anonymous quotas an unauthenticated session could fill mailboxes with only a leaked write capability |
| Random delays in fan-out | Costs latency for every message and only blurs timing for a live observer; can be revisited as an option |
| Do nothing | Leaves a stolen database able to reconstruct who is in each group |

## Consequences

- Part 1 needs a relay migration and a client change (shuffled fan-out); cursors remain compatible.
- Effective expiries become coarser; retention may end up to one day shorter than requested.
- Part 2, if adopted, adds token issuance, double-spend storage, a new kind of provisional session and two cryptographic dependencies to review.
- The threat model states that unlinkability of a person's mailboxes is not a goal for small realms.

## Acceptance criteria

Part 1:
1. After a group message to N devices, no ordinary query on the database or a backup groups its N copies: no realm-wide order, no identical expiry to the second.
2. The cursor a client receives reveals nothing about other mailboxes.
3. Migration from a database with realm-wide `seq`: every cursor held by existing clients continues without loss or duplicates.
4. Blob times are rounded; the uploader column remains, documented.

Part 2, if adopted:
5. An anonymous session can do nothing but `EnvelopePut` with a valid capability and an unspent token.
6. A spent token is refused, and a member cannot obtain more than the daily limit.
7. Linking issuance and redemption is impossible given the scheme's assumptions, checked against the library's test vectors and review.

References: [threat model](../THREAT_MODEL.md), [protocol](../PROTOCOL.md), [ADR-008](ADR-008-carrier-independent-transport.md), [ADR-014](ADR-014-relay-activity-notices.md), [Privacy Pass architecture (RFC 9576)](https://www.rfc-editor.org/rfc/rfc9576), [Privacy Pass issuance (RFC 9578)](https://www.rfc-editor.org/rfc/rfc9578).
