# ADR-014 — Activity notices from the relay

- **Status:** relay and core protocol implemented on 2026-10-02 (sections 1 and 2, relay schema 7), not yet deployed. The Android service, the macOS subscription and the retirement of ntfy (sections 3 to 5) are proposed and follow as separate increments.
- **Date:** 2026-10-02.
- **Scope:** how a device learns that its mailbox has something while Arveil is not on screen, on Android and macOS, without Google, without a second app and without a second server. It replaces the experimental Android ntfy/UnifiedPush receiver described in [attachments and notifications](../CLIENT_FILES_NOTIFICATIONS.md) and the M3.4 hint of the [protocol](../PROTOCOL.md).

*Versión en español: [../es/adr/ADR-014-relay-activity-notices.md](../es/adr/ADR-014-relay-activity-notices.md)*

## Context

What exists on 2026-10-02:
- **Relay (M3.4).** A device may register one http(s) URL with `NotifyHintSet`. When its mailbox goes from empty to non-empty, the relay POSTs `arveil-hint/v1` to it: one attempt of five seconds, no retries, and any HTTP answer counted as sent.
- **Android (PR #141, experimental in betas 5 and 6).** That URL belongs to a self-hosted ntfy server. The phone needs the F-Droid ntfy app as UnifiedPush distributor, and the person types the ntfy server address in **Settings → Notifications**. Arveil checks that the endpoint belongs to that server and refuses ntfy.sh.
- **macOS.** No push. With "Keep Arveil in the background" on, the open profile syncs every ten seconds.

The problems:
1. **Three extra parts for one fact.** An ntfy server, the ntfy app and UnifiedPush, to say something the relay already knows: this mailbox has mail.
2. **A question nobody should have to answer.** The person is asked for an address the operator knows and that has nothing to do with their identity.
3. **Outbound requests from the relay.** The relay POSTs to URLs devices give it. Limiting destinations, resolved addresses and redirects is still pending.
4. **Outside the Noise channel.** ntfy endpoints are bearer capabilities in URLs, the ntfy server keeps its own logs, and the hint travels outside the protections of [ADR-008](ADR-008-carrier-independent-transport.md).
5. **A lost hint is never repeated.** Normal sync recovers the messages, but the notice is gone.
6. **The protocol already had an answer.** [Protocol §6](../PROTOCOL.md#channel-frame-catalog) specifies a `mailbox_wakeup` frame from realm to client over the channel. M3.4 went around it.

How messengers solve this without Google: on Android, SimpleX Chat keeps a foreground service connected to its own servers ("instant" mode), or polls periodically. ntfy is itself such a service, connected to another server. Only iOS forces a provider (APNs), and Arveil has no iOS client (M3b.7 has not started).

## Decision (proposed)

### 1. The relay announces activity over the channel

- **Subscribe.** `MailboxWatch {}` subscribes the session to the mailboxes of its device. The relay answers `Ack` and immediately sends a wakeup if any of them is non-empty. A reconnect therefore recovers a notice lost while offline, with no retries and no durable notification state.
- **Notice.** `MailboxWakeup {}` is an unsolicited frame from the relay, with frame id 0. It is sent when a watched mailbox goes from empty to non-empty. It carries no mailbox id, count, sender or size.
- **One subscription per device.** A new subscription replaces and closes the previous one.
- **Keepalive.** `Ping`/`Pong` already exist. The client pings at an interval measured per carrier during acceptance, because tunnels and NATs close idle connections within minutes or less.
- **Fixed size.** Watch frames and their pings are padded to one size, so an observer of the carrier cannot tell a notice from a keepalive by length.
- **Compatibility.** Older clients never send `MailboxWatch` and never receive unsolicited frames.

### 2. A watch-only key per device

On Android the profile must stay closed: MLS and device keys must not sit in memory while the phone is locked. The service therefore uses a key that can do nothing but watch.
- **Separate key.** The device generates an X25519 *watch key* and registers its public half with `WatchKeySet { key }` from a member session; an empty key removes it. It is neither derived from nor equal to the device's transport key.
- **Watch session.** A Noise session whose static key is a registered watch key may send only `Ping`, `MailboxWatch` and `EndpointListGet`. Every other frame is refused as it is for a provisional session: `EnvelopeFetch`, `EnvelopeAck`, `EnvelopePut`, blobs, KeyPackages, manifests, invitations and `NotifyHintSet`.
- **Lifecycle.** Revoking the device credential deletes its watch key and closes its watch sessions. Recovery and rotation replace it. A device holds at most one.
- **Storage.** The private half is encrypted under an Android Keystore key, as `PushStore` does today. It never enters profile backups or exports.
- **If stolen.** The thief learns when that device's mailbox has mail, until the device is revoked or the key replaced. The key cannot read, fetch, acknowledge or send, and does not say who wrote.

Two options were discarded. Keeping the profile unlocked in the service, as macOS does, leaves MLS and device private keys in memory on a locked phone and weakens the "theft of a locked device" defense of the [threat model](../THREAT_MODEL.md#2-adversaries-and-scenarios). Putting the watch key in the `DeviceCredential` would require the root to sign every rotation; binding it to the device that registered it is enough, because the relay already knows which mailbox belongs to which device.

### 3. Android: Arveil keeps the connection itself

- **Service.** An opt-in foreground service holds one watch session. It follows the signed endpoint list in priority order (LAN, tailnet, public), reconnects with backoff on network changes, and starts after a reboot if the person enabled that.
- **Notification.** On `MailboxWakeup` it shows the existing generic notification, grouped until a successful foreground sync, without opening the profile. The grouping and visibility rules of PR #141 are reused.
- **System requirements.** The service shows the persistent notification Android requires; its channel can be silenced. It asks to be exempted from battery optimization. The service type is `specialUse`: `dataSync` is limited to six hours on Android 15, and Arveil is distributed outside Google Play. Each Android version is checked during acceptance.
- **Implementation.** The Noise channel lives in the Rust core. The service calls a small Rust entry point over JNI that only opens a watch session and reports wakeups; it does not start Flutter. The alternative is a headless Flutter engine, which is heavier. Noise is not reimplemented in Kotlin.
- **Fallback.** A person who declines the persistent service can choose a periodic check with WorkManager, at least every 15 minutes. It opens a watch session, sees whether there is mail and closes.

### 4. macOS uses the same subscription

With "Keep Arveil in the background" on, the open profile already holds a member session. It sends `MailboxWatch` on that session and syncs on `MailboxWakeup` instead of every ten seconds. macOS needs no watch key while the open profile holds the session.

### 5. ntfy and the M3.4 hint are retired

- **Client.** The next client release removes the ntfy settings, the UnifiedPush connector and `ArveilPushService`. On first start it clears the registered hint by sending an empty `NotifyHintSet`.
- **Relay.** It keeps accepting `NotifyHintSet` for one release cycle, only to clear it. Then it removes the frame, `sendHint`, `arveil-hintsink` and `scripts/test_ntfy_hints.py`, and drops the `notify_hints` table in a migration. Stored URLs are deleted, not migrated.
- **Kept from PR #141.** The generic notification, its grouping, the Keystore-backed store and the visibility tests.

## What each party learns

| Party | Today, with ntfy | With this decision |
|---|---|---|
| Relay | When a mailbox goes non-empty (already known) and the registered URL | The same transitions, plus when each opted-in device is connected and from which IP, continuously |
| ntfy server | The phone's IP and persistent connection, its topic, the time of each hint | Does not exist |
| Carrier (for example Cloudflare Tunnel) | Relay→ntfy and phone→ntfy traffic, if it routes them | The phone's persistent connection: IP changes, connection times and frame timing; not the frames, nor which ones are notices |
| Holder of a stolen watch key | — | When that mailbox has mail, until revocation |
| Holder of a leaked ntfy endpoint | Can publish notifications to the phone | — |

Presence is the real cost. Notices therefore stay opt-in and off by default. The settings text says it plainly: the server will know when your phone is connected and from which network. When the phone has a tailnet route it is preferred, so a public tunnel does not see the persistent connection.

The content of conversations is unaffected. A notice says only that a mailbox has something; the client still fetches over the Noise channel and verifies and decrypts with MLS, and the relay receives no key.

## Alternatives

| Alternative | Reason not to adopt it |
|---|---|
| Keep ntfy and UnifiedPush, but announce the ntfy server in the signed endpoint list | Removes the typed address, but keeps two extra components, the second app, bearer URLs outside Noise and outbound requests from the relay |
| FCM / Google Play services | Google learns token, timing and application; excluded from the start |
| Keep the profile unlocked in an Android service | Device and MLS keys in memory while the phone is locked |
| Periodic polling only | Delays of 15 minutes or more; kept as a fallback |
| Arveil as its own UnifiedPush distributor | The same connection with an extra protocol in between, and no benefit for a single app |

## Consequences

- One fewer server for operators, one fewer app for families, no address to type.
- The relay keeps one long-lived connection per opted-in device. Memory and file descriptors grow with them, and per-address limits apply to watch sessions too.
- The relay no longer makes outbound requests, so the pending destination policy disappears.
- New Android surface: a foreground service, a JNI entry point, a boot receiver and the battery-optimization request.
- Battery cost depends on the carrier's keepalive. LAN and tailnet are measured separately from the public tunnel.
- Android, or a manufacturer's battery manager, may still kill the service. A notice is a hint; normal sync remains the source of truth.
- iOS, if it comes, will need APNs and its own decision.

## Acceptance criteria

1. A watch session refuses every frame other than `Ping`, `MailboxWatch` and `EndpointListGet`, including fetch, ack, put, blobs, KeyPackages, manifests, invitations and `NotifyHintSet`.
2. Revoking the device closes its watch sessions and refuses its watch key at the next handshake.
3. One wakeup on the empty to non-empty transition; none for later envelopes until the mailbox is empty again; one on subscribing to a non-empty mailbox.
4. Capture behind a TLS-terminating tunnel: notices and pings cannot be told apart by size.
5. Physical Android phone: screen off and Doze, battery saver, Wi-Fi to mobile data and back, reboot, process death, removal from Recents, force stop and reopening. Delay and battery use are measured over LAN or tailnet and over the public tunnel.
6. The notification shows no sender, conversation or count; the profile is not opened and unread markers do not change.
7. Upgrading from beta 6 with ntfy enabled clears the relay hint and removes the ntfy settings without leaving a misleading toggle.
8. macOS stops polling every ten seconds and still receives activity through the subscription.
9. A hostile relay that floods wakeups: the client shows at most one notification until the next sync and rate-limits its reconnections.

## Open questions

- JNI entry point or headless Flutter engine.
- Keepalive interval per carrier, and whether the client should keep the tailnet route even when a public route answers first.
- Whether notices keep arriving with the profile closed (as the ntfy receiver does today) or only after the profile has been opened once since boot.

References: [protocol](../PROTOCOL.md#channel-frame-catalog), [threat model](../THREAT_MODEL.md), [ADR-008](ADR-008-carrier-independent-transport.md), [ADR-015](ADR-015-delivery-metadata-and-anonymous-sender.md), [Android Doze](https://developer.android.com/training/monitoring-device-state/doze-standby), [foreground service timeouts](https://developer.android.com/develop/background-work/services/fgs/timeout).
