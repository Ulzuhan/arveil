# Why Arveil's server has no rooms table

*Outline for a second design note. To be written after Phase 0 provides a screenshot of the actual relay schema.*

## Angle

Every chat server people self-host has a `rooms` table, a `room_members` table and a `messages` table. Even the end-to-end encrypted ones. That schema is where the metadata lives, and it is what an operator, a backup thief or a subpoena reads. Arveil's relay has none of them, and the post walks through what that costs and what it buys.

## Structure

1. **The schema, side by side.** A typical homeserver schema versus Arveil's eleven tables: memberships, invites, device credentials, manifests, key packages, mailboxes, capabilities, envelopes, blobs, push subscriptions, endpoint lists. No conversation, no group, no message.
2. **Where the group went.** Every conversation is an MLS group and its roster, title and policy live only inside MLS state on the devices. The relay sees mailboxes owned by devices and envelopes addressed to mailboxes. Show the envelope row: mailbox id, random delivery id, ciphertext, expiry. Nothing else.
3. **What the relay can still infer, honestly.** Fan-out from one authenticated device to N mailboxes at the same second is a group, whether or not there is a table for it. IPs, timing, sizes. Link to the threat model section that says so in a table.
4. **What you lose.** No server-side search, no link previews, no moderation of content, no admin "reset password", no web client served by the server. Each is a deliberate boundary with its own ADR.
5. **What you gain.** Backups of the relay are metadata plus ciphertext; losing the relay entirely loses no history and no identity; migrating to another machine is copying a directory; the relay code is small enough to read in an afternoon.
6. **The one operation that gets harder: ordering commits.** Without a rooms table there is no server-side sequencer, so concurrent MLS commits need another answer. Describe the current committer-policy approach and the deterministic-successor alternative under evaluation. This is the honest "still open" section.

## Evidence to include

- `sqlite3 realm.db .schema` output from the Phase 0 relay.
- The I-01 test: inventory of every column and a grep of the database and logs for plaintext after a demo run.
- A packet-level view of a three-member group message: three envelopes, three different delivery ids, three different ciphertexts thanks to the per-device HPKE seal.

## Links

[ADR-003](../adr/ADR-003-zero-trust-server.md), [Domain model §4](../DOMAIN_MODEL.md#4-logical-server-schema), [Threat model §3](../THREAT_MODEL.md#3-what-the-server-actually-knows).
