# ADR-011 — Names people choose for themselves

- **Status:** proposed. Nothing in this record is implemented.
- **Date:** 2026-09-26.
- **Scope:** letting each person choose the name others see for them, shared end to end with the members of their conversations and never with the realm. Local names, which each profile gives its contacts, stay as they are.

*Versión en español: [../es/adr/ADR-011-shared-display-names.md](../es/adr/ADR-011-shared-display-names.md)*

## Context

Today a name is local and only local. A profile names its contacts; the name lives in its encrypted database, never travels and never authenticates anyone ([ADR-005](ADR-005-cryptographic-identity.md): "Names and aliases do not take part in cryptographic authentication"; [Phase 4](../PHASE4.md), M4.8). Nobody can choose how they appear to others. Until someone names you, you are eight hexadecimal characters of your identity.

The first beta installation made the cost visible. A person installing the app looked for a place to set their own name and found none. The app now shows "Unnamed · a1b2c3d4" and asks the person to name each contact ([implementation record](../CLIENT_FOUNDATION.md#naming-people-who-have-no-local-name-september-26-2026)). That makes the gap clear, but each person still has to name everyone else, in every profile and on every linked device, since local names do not sync between devices.

What the protocol offers today:

- **Application events** inside MLS are a CBOR `{kind, body}`. The kinds are `roster`, `manifest`, `text` and `file`.
- **A client drops an unknown kind.** It acknowledges the event, stores nothing, counts nothing as unread and moves on. So a new kind is additive: installed clients ignore it.
- **An existing kind cannot be extended.** A malformed body rolls back the whole delivery unit and blocks the mailbox until it is retried. Roster lines, for example, must be routes of exactly nine fields, so adding a name to a route would stall every older client.
- **Each identity has an Ed25519 root key.** It signs device credentials and a sequenced device manifest, and manifests already travel as a group event, accepted only under the stored root and an increasing sequence. The root is kept on the administration device, or a recovered one, and is not copied to linked devices.
- **MLS authenticates the sending device** of each event, and the roster maps devices to identities.

## Decision (proposed)

**1. A profile is a statement signed by the identity's root.** It is a `SignedObject` with the context `arveil/profile/v1` and the body `{sequence, name}`:
- `sequence` increases with every change;
- `name` is either a string or empty, which removes the name.

It reuses the signing pattern of the device manifest. The name belongs to the identity, not to one device, so every device of that identity shows the same name.

**2. It travels as a new MLS application event, `profile`, and nowhere else.** A device announces the latest profile of its identity:
- to a conversation when it creates it or is added;
- to all its conversations when the name changes.

The realm sees only ciphertext of ordinary size. It never receives or stores a name, and nothing is added to routes, invitations, key packages or relay tables.

**3. Receivers accept a profile under the root they already know for that identity**, and only when its `sequence` is higher than the last one they accepted. They keep it in a table of announced names, apart from local names and from history: it is never a message, never unread and never in an archive.

**4. A local name always wins.** An announced name is shown only when this profile has not named the person, and it is marked as theirs: for example "~Lucía", with the person's short identifier where two people share it. One action saves it as the local name. Neither kind of name authenticates anyone: the safety number stays the only check, and a name never changes it.

**5. Only a device holding the root can change the name.** That is the administration device or a recovered one. Linked devices forward the latest signed profile they received and send people to the administration device to change it. The cost is that a person who has only linked devices cannot rename themselves. In exchange, a lost or stolen linked device cannot rename the identity.

**6. The name is validated where it is chosen and where it is received:**
- at most 64 Unicode code points, normalised to NFC;
- no control characters;
- no bidirectional overrides and no zero-width characters.

Anything else is refused whole.

## What each party learns

| Party | Learns | Does not learn |
|---|---|---|
| The realm | That events of ordinary size were sent after a name change, as for any message | The name, whether one exists, or that an event is a profile |
| Members of a conversation | The name the person chose, and later changes | Local names others gave them |
| People in no conversation with the person | Nothing | The name |

A name reaches everyone in every conversation the person is in, including groups with people they have never met. That is the point of the feature and its main privacy cost. The settings screen says so where the name is set.

## Alternatives

| Alternative | Reason not to adopt it |
|---|---|
| Local names only, with the new prompts | Keeps every property of today, but each person names everyone, on every device |
| A name inside the contact route | Older clients require nine fields and would stall; routes are pasted into other channels, where a name would leak; a route does not change when the name does |
| An MLS leaf node extension | Authenticated by the leaf, but it belongs to one device, not the identity, and changing it needs an Update commit that only the lowest active leaf may make today |
| A `profile` event without the root signature | Any device could set the name; simpler, but devices could disagree, and a stolen linked device could rename the identity |
| A profile stored by the realm | Gives the server names it must never hold ([ADR-003](ADR-003-zero-trust-server.md), invariant I-01) |

## Consequences

- A new event kind and a table of announced names in the core, plus a signed statement with its own sequence.
- Older clients keep working and simply show no chosen names.
- Setting a name creates one event per conversation. That is a small, visible burst of traffic; its timing tells the realm that something happened, but not what.
- Phase 3b excludes protocol redesign ([Phase 3b](../PHASE3B.md)). This is an additive change, so it may fit, but the decision is taken separately from the beta.

## Acceptance criteria

1. An older client that receives a `profile` event keeps working, shows nothing new, and has nothing new counted as unread or stored in its history.
2. A profile signed by another root, with a lower or equal sequence, or with a name outside the rules is refused, and the name shown does not change.
3. A local name always takes precedence, and an announced name never changes a safety number or a verification.
4. No name appears in the realm's database, logs or metrics, or in routes, invitations or key packages.
5. A linked device shows the name set on the administration device and cannot change it.
6. Removing the name removes it for every member once they receive the new profile.

## Open questions

- Whether to let a person choose, per conversation or per group, not to share their name.
- Whether a person whose devices are all linked should get a way to rename themselves, and with what authority.
- Whether a profile should later carry a photo. It would be a larger, separate decision with its own size and storage limits.
