# ADR-012 — QR codes and links for joining, linking and contacts

- **Status:** proposed. Nothing in this record is implemented.
- **Date:** 2026-09-27.
- **Scope:** how a person joins a realm, links another of their devices and adds a contact without copying long strings between apps; and how verifying a contact becomes a separate, optional step. Realm administration from the app is [ADR-013](ADR-013-realm-administration-from-the-app.md).

*Versión en español: [../es/adr/ADR-012-qr-codes-and-links.md](../es/adr/ADR-012-qr-codes-and-links.md)*

## Context

The first beta was tried end to end by its maintainer: a Mac holding the identity and an Android phone to link, with WhatsApp as the channel to move codes between them. The phone was never linked. The three flows share one cost: each one moves a long hexadecimal string by hand, through another app.

**Linking a device** ([Protocol §8](../PROTOCOL.md#8-adding-removing-and-recovering-devices), M3.1):
- The new device shows `arveil-pair:v1:…`, 242 characters, with no copy button. The person carries it to the administration device.
- Before [#117](https://github.com/Ulzuhan/arveil/pull/117), the new device stopped listening after 90 seconds while its screen still counted down ten minutes. The administration device then waited its own 90 seconds and failed, and the code was spent. Each retry used one of the four rendezvous an address may open every ten minutes.
- The new device also has to paste the realm's `arveil-bootstrap:v0:…` string. No screen in the app shows it; only the relay's log does.
- The administration device signs and publishes the new credential and manifest as soon as the handshake completes, **before** anyone compares the numbers. The comparison only decides whether the new device applies the grant. If the code is replaced on its way, the replacement device is authorized and the mismatch appears afterwards; revoking it takes the CLI.

**Joining a realm** ([Protocol §3](../PROTOCOL.md#3-realm-bootstrap-and-identity)):
- A new person receives two strings: the bootstrap, about 245 characters, and a 64-character invitation that only the relay host can create.

**Adding a contact** ([Protocol §4](../PROTOCOL.md#4-contact-verification-and-routes), M3.2):
- A person shares `arveil-route:v1:…`, 406 characters.
- The safety number is computed locally from both roots, so the person who shared the route sees no number until they also have the other's route.
- The app requires "We compared the numbers" before it creates a conversation. In practice the flow either stops there, or the box is ticked without comparing. A verification that did not happen is worse than an honest "unverified".
- The conversation it creates is joined by the other side automatically, with no request to accept.

The design already expected QR codes: [Protocol §3](../PROTOCOL.md#3-realm-bootstrap-and-identity) and §8, item F1 of the [client design](../CLIENT_DESIGN.md), and the open risk in the [threat model](../THREAT_MODEL.md) that "a decorative QR does not authenticate the channel".

What comparable messengers do:
- **Linking:** Signal, WhatsApp, Matrix and passkeys scan a QR from one screen with the other device's camera.
- **Onboarding:** servers hand out a single link or QR with an expiry and a number of uses. Examples are Matrix registration tokens, Delta Chat account QR codes and SimpleX one-time links.
- **Contacts:** Signal, WhatsApp, Threema, Matrix and SimpleX let people talk before verifying. They show the verification state, warn when a key changes and offer verification by scanning in person or comparing numbers later. In Delta Chat one scan verifies both sides.

## Principles

1. **Between two devices in front of the person, a code travels by camera, not through another app.**
2. **When it has to travel remotely, it is one `https` link.** Its secret sits in the URL fragment, which browsers do not send to any server.
3. **Connecting and verifying are separate steps.** Verification is visible and optional. Scanning in person verifies.
4. **No device is authorized before the person confirms on the screen that authorizes it.**
5. **Pasting always works.** It covers devices without a camera, a refused camera permission, and accessibility.

## Decision (proposed)

### 1. One payload, three uses

A payload is deterministic CBOR `{version, kind, …}`, encoded as base64url without padding. The kinds are `join`, `link` and `contact`. The same payload can travel three ways:
- **as a QR code** of the whole link, in byte mode with error correction M;
- **as a link:** `https://arveil.kaicorplabs.com/<kind>#<payload>`;
- **pasted:** the app accepts the link or the bare payload.

Every payload carries the realm bootstrap it belongs to: the realm signing key, the realm Noise key and one endpoint URL. The client computes `realm_id` from the signing key instead of trusting a copied one. Payloads above 600 bytes are refused before parsing. The client never fetches the link; it parses it locally.

The older strings (`arveil-bootstrap`, invitation hex, `arveil-pair:v1`, `arveil-route:v1`) stay accepted when pasted until a later release removes them.

### 2. Joining: `join`

`{version, kind: "join", realm_signing_key, realm_noise_key, url, invitation}`, where `invitation` is the 32-byte token.
- `arveil-relay invite` prints the link and a terminal QR next to the token. The link base can be configured with `-link-base`.
- An invitation created in the app ([ADR-013](ADR-013-realm-administration-from-the-app.md)) may also carry the inviter's contact (§4). After joining, the new person already has a conversation with whoever invited them.
- The invitation is single-use and short-lived, as today. If someone else redeems an intercepted link first, the invited person sees "invitation already used" and the administrator sees who redeemed it. Being admitted grants no access to anyone's messages or keys ([ADR-003](ADR-003-zero-trust-server.md), [ADR-005](ADR-005-cryptographic-identity.md)).

### 3. Linking a device: `link`, started by the device that holds the root

The roles are reversed. The device that holds the root starts; the new device scans.

1. **The administration device opens the rendezvous.** In "Link a device" it calls `pair_begin` from its member session; the frame and its limits do not change. It then generates a one-time X25519 key for this pairing and shows a `link` payload as a QR, with a share button and a countdown: `{version, kind: "link", realm keys, url, pair_id, capability, responder_key}`.
2. **The new device scans it** in "Link with my other device", or opens the link. It learns the realm and the responder key, with nothing to paste. It creates its device keys and is the Noise `IK` initiator towards `responder_key`. Message 1 carries its four public keys and an optional self-description such as "Pixel 8 · Android 15"; the description is shown but never trusted.
3. **Both screens show the same short number**, derived from the handshake hash as today. The administration device asks "Link Pixel 8?" and shows the number.
4. **Only when the person confirms there** does the administration device sign the credential and manifest N+1, publish them and put the grant in the last slot.
5. **When the new device confirms depends on how it got the payload.**
   - From the camera, it applies the grant as soon as it arrives. It already authenticated the responder key visually, and `IK` binds it.
   - From a link or a paste, the payload crossed another channel, so the new device also asks the person to confirm the number before applying the grant.

Consequences:
- The realm cannot answer on its own. The responder key never reaches the realm, and message 1 cannot be built without it.
- Someone who photographs the QR and answers first takes the write-once slot. The real new device then fails visibly, and the administration device shows a device the person does not recognise. Nothing is signed unless the person confirms it.
- Every rendezvous is now opened by a member. Once clients from before this change are gone, `pair_begin` can be refused on provisional sessions. That removes the only unauthenticated write surface of the protocol.
- A Mac without a camera receives the link by AirDrop, Messages or any other channel. The confirmation on both screens covers that path.
- The relay frames and limits stay as they are. The `arveil-pair:v1` flow keeps working for one release.

### 4. Contacts: `contact`, connected first and verified when wanted

`{version, kind: "contact", realm keys, url, route fields, secret}`.
- The route fields are those of `arveil-route:v1`: device id, credential hash, root key, mailbox, write capability and HPKE key.
- `secret` is 16 random bytes, remembered by the device that shows the card.

**Two ways to share:**
- **"Show my code"** displays a QR for use in person. Its secret is valid while the screen is open and for at most ten minutes, and only once.
- **"Share my contact"** creates a link through the system share sheet. Its secret stays valid for 30 days and can be revoked.

**Opening a card.** The person sees who it is and "Start talking". There is no mandatory comparison. The app creates the conversation, and its first message is a new MLS application event, `hello {secret}`. Older clients drop an unknown kind, so this is additive.

**Receiving.**
- A conversation created by someone who is not a contact arrives as a **request**: "Ana wants to talk to you (used your link from 12 September)", with Accept and Decline. An unknown or expired secret still produces a request, marked "did not use any of your links".
- A conversation from a contact is joined directly, and its members are listed in its details.
- This replaces today's silent join and follows [Protocol §5](../PROTOCOL.md#5-mls-groups-keypackages-and-authorization), under which the roster is presented to the user.

**Verification states:**
- **Unverified** is the default, and it is shown in the conversation header and details.
- **Verified in person** needs one scan. The scanning side read the root from the other's screen, so it marks that contact verified. The side that showed the code marks the scanner verified when its `hello` returns the in-person secret inside the end-to-end channel.
- **Verified by comparison** is reached from the conversation details at any time. Both sides already hold both roots, so both see the same number, and one can scan the other's code if they meet later.
- Verification stays a property of the root, as in M3.2. Changing a verified contact's root raises a warning and requires verifying again.

**What the card must bind.** A card is only as good as the binding between its route fields and its root. Before a conversation uses a card, the client checks the device keys it names against a root-signed device credential, as [Protocol §5](../PROTOCOL.md#5-mls-groups-keypackages-and-authorization) requires. The KeyPackage claimed for that device must match the same credential. Today neither `arveil-route:v1` nor the KeyPackage claim is checked that way. That review is tracked separately and is a precondition for this section.

**For families (open question):** a list of "People on this server" that members opt into, with the names of [ADR-011](ADR-011-shared-display-names.md).

### 5. The link pages

`arveil.kaicorplabs.com` serves `/join`, `/link` and `/contact` as static pages in English and Spanish.
- The pages load nothing from third parties and use a strict content security policy with `Referrer-Policy: no-referrer`. Their preview metadata is generic.
- **Android.** The app declares these paths as verified [App Links](https://developer.android.com/training/app-links). The site publishes `/.well-known/assetlinks.json` with the package name and the SHA-256 of the release certificate. When the app is installed, Android opens it directly and the page never loads.
- **macOS.** Universal links need an Apple Developer ID, which the project does not have. The app registers the `arveil:` scheme instead, and the page offers an "Open in Arveil" button. Its small inline script copies the fragment into an `arveil://` URL.
- **Without the app,** the page explains how to install it (the APK or `brew install --cask arveil`) and offers a button to copy the link. The app's paste field accepts it.
- **Other relays.** A relay run by someone else can point `-link-base` at its own page. Android only opens the app directly for the domain the app declares; elsewhere, the button or a paste still works.

### 6. Camera and QR libraries

- The camera opens only after the person taps "Scan", as item F1 of the client design already requires. A refused permission leaves the paste field.
- **Android** declares `CAMERA`.
- **macOS** adds the sandbox entitlement `com.apple.security.device.camera` and a usage description.
- QR generation is small and deterministic, and can live in the Rust core.
- The scanner is a new dependency, and its choice gets a supply-chain review:
  - `mobile_scanner` uses ML Kit on Android, whose bundled model is not open source, and AVFoundation on macOS;
  - a zxing-cpp based scanner is fully open source.
  - Either way the scanner must work offline and send nothing.

## What each party learns

| Party | Learns | Does not learn |
|---|---|---|
| The realm | That a member opened a rendezvous, as it learns today from the administration device; that a conversation was created | Responder keys, secrets, names, or whether a conversation began from a card |
| The web server | That someone visited `/join`, `/link` or `/contact` (IP and time); link previews fetch the page without the fragment | The fragment: invitations, capabilities, keys or secrets |
| The channel used for a link (WhatsApp, Messages…) | The link, as with today's strings; it may keep it in its backups | Anything the app does with it |

The link carries a bearer secret, like today's strings. The mitigations are single use and a short lifetime for invitations and linking, a lifetime and revocation for contact links, and the request step for contacts. A card's write capability is long-lived, as the route's is today: whoever holds it can drop envelopes in that mailbox, but not read them.

## Alternatives

| Alternative | Reason not to adopt it |
|---|---|
| Keep text codes and only add copy and share buttons | Still two or three pastes through other apps; the only authentication of a pairing remains that the code arrives intact |
| The new device shows the QR and the administration device scans it, as in Signal and WhatsApp | The new device would need the realm bootstrap before showing anything, and the administration device is often a Mac, where scanning a phone is awkward |
| Short typed codes with a PAKE (as in Magic Wormhole) | Good without a camera, but a new cryptographic construction and dependency; the confirmation on both screens already covers that path |
| Mandatory verification before the first message | This is today's design. It stops the flow or teaches people to tick a box without comparing |
| Custom `arveil://` links only, with no web page | Messaging apps do not make them tappable, so a remote invitation would be text to copy again |
| Universal links on macOS | Require an Apple Developer ID |

## Consequences

- **Client:** a scanner, a QR renderer, App Links on Android and the `arveil:` scheme on macOS; the linking roles reversed; contact requests; verification in the conversation details.
- **Protocol:** a new MLS event kind (`hello`) and a rule that authorization follows confirmation. The relay only gains `-link-base` and printed links.
- **Website:** the three link pages and `assetlinks.json`, deployed with the site.
- **Removed:** the checkbox "We compared the numbers" and the silent join of conversations started by strangers.
- **Fixes to ship first:** the order of authorization and confirmation and the binding of routes to root-signed credentials are fixes in their own right. They should not wait for the rest of this record.

## Acceptance criteria

1. **Linking.** A phone is linked to a Mac by scanning the Mac's screen, with no text copied or pasted. The credential is published only after the person confirms on the Mac. A second device racing with a photograph of the QR is visible, and gets no authorization unless confirmed.
2. **Joining.** A person joins a realm with one link or QR. The invitation appears in no web server or relay log.
3. **Contacts.**
   - Scanning in person connects two people and marks both verified with one scan.
   - Sharing a link connects them unverified, and the receiver sees a request.
   - Both see the same number in the conversation details.
4. **Old strings.** They still work when pasted.
5. **Camera.** It is not requested until "Scan" is tapped. Refusing it leaves pasting available.
6. **Link pages.** They load no third-party resources and send no referrer. With the app installed on Android, a tap on a link opens the app directly.
7. **Older clients.** A client without this change that receives a `hello` event keeps working and stores nothing.

## Open questions

- Which scanner library to use, after its supply-chain review.
- Whether a card's long-lived write capability should become a separate, revocable capability per card.
- Whether to offer the "People on this server" list, and who may see it.
- Whether links for relays that are not the project's should use the project domain by default.
