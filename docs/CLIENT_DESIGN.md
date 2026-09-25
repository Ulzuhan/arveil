# Client design: visual system and implementation plan

[Versión española](es/CLIENT_DESIGN.md). The Spanish document is the normative source; this condensed English translation must be updated in the same review, and the Spanish text prevails if they diverge.

Status: visual direction approved on September 25, 2026 from mockups of the main screens. Implemented: A0 (schema versioning), A1 (sender and time in live history), A1b (sender in the encrypted history), A2 (conversation summary and unread counts), A3 (kit state, device notices and sync status), B1 (tokens, theme and components), B2 (Spanish and English), C1 (adaptive navigation and shortcuts), C2 (chat list) and C3 (conversation); the rest is pending. The plan runs inside [M3b.5](PHASE3B.md), before the test with three external users. It changes neither the protocol nor the relay, except optional package F1 (QR invitation), which needs its own format review.

## Why, and what not

Current screens use default Material components: one `ColorScheme.fromSeed` without a dark theme, the profile page as home with stacked panels, hardcoded Spanish strings and delivery states written as long sentences. They work and are tested, but they are not good enough to evaluate the experience with external users.

The goal is visual and interaction quality comparable to mainstream messengers in the principal flows, with its own identity. No other app's visual identity is copied and no feature Arveil lacks is imitated. The visual system is built to allow personalization.

Out of scope: reactions, quoted replies, forwarding, typing indicators, read receipts, voice notes, calls, stories, push notifications, sender-declared send time, whole-history search and preference sync between devices. Several need MLS message format changes, and phase 3b excludes protocol redesign.

## Principles

1. **Honest states.** Pending, accepted by the server and failure are distinct. Never double ticks or "read": the protocol has no read receipts and M3b.3 forbids confusing relay acceptance with human reading. Without push in the beta, show the last successful sync.
2. **Visible, understandable security.** Contact verification, devices and the identity kit are part of the product. A contact adding or removing a device appears as a notice in the conversation. Notices inform without blocking unless the risk requires it.
3. **Local first.** Reading and writing work offline; no connection is a notice, not a modal error.
4. **Rust is the source of truth.** New data the UI needs (sender, conversation summary, unread, recovery state) is added to the Rust contract. Dart keeps no second durable domain database; only global appearance preferences live outside Rust.
5. **Accessible by construction.** AA contrast enforced by a test over the tokens, touch targets of at least 48 dp on Android and 44 pt on Apple systems, screen reader labels and scalable text.
6. **No leaks from the client itself.** Fonts, icons and backgrounds ship inside the app; nothing is downloaded at runtime (for example, no dynamic `google_fonts` fetching). No analytics. Documentation screenshots contain no real invitations, routes, addresses or identifiers.
7. **Bilingual.** Spanish and English UI with one glossary: relay/realm → "servidor"/"server"; KeyPackages → "claves para grupos nuevos"/"keys for new groups"; history archive → "historial cifrado"/"encrypted history"; pairing → "vincular dispositivo"/"link a device". Technical terms remain in diagnostics and operations documentation.

## Visual system

Reference mockups cover welcome, chat list, group conversation, contact verification, settings, a three-pane desktop layout and an offline dark-mode conversation. They are private to the maintainer; public screenshots will come from the implemented app (E3). The [Spanish document](es/CLIENT_DESIGN.md#sistema-visual) holds the normative token tables. In summary:

- **Color:** warm paper ground `#F4F1EA` / `#0E1413`, ink `#16211F` / `#E6ECEA`, brand accent `#245B51` / `#8FD0C0`, own bubble `#DDEAE4` / `#1D4740`, amber attention `#F6E7CC`+`#6B4108` / `#3A2A12`+`#F2C98A`, danger `#A2382B` / `#F2A59B`. Five avatar tones and four sender-name colors per theme, assigned deterministically from the identity ID. On September 25, 2026 every text/background pair measured at least 5.05:1; B1 turns this into an automated test.
- **Type:** Newsreader for screen titles, Instrument Sans for the UI, IBM Plex Mono for safety numbers and identifiers. All SIL OFL 1.1, bundled under `clients/flutter/assets/fonts/` with licenses registered.
- **Shape and icons:** bubbles radius 18 with 6 at the tail, cards 20, primary buttons 16 and 52 high; spacing in multiples of 4; Material outlined icons already bundled with Flutter (Apache-2.0), chosen in B1 over the Lucide candidate to avoid a download and a dependency; motion up to 200 ms, disabled when the system asks for reduced motion. B1 also added a `lineStrong` token, because the decorative `line` colour lacked 3:1 as a control border.
- **Brand:** the ivory ribbon A (`#F6EFDF`) on pine green `#245B51` from `assets/brand/`, the macOS and Android app icon since `0.1.0+11`. The app uses its vector `mark.svg` on the welcome screen, desktop header and splash; the mockups' arch is only a decorative background motif.

## Screens and navigation

Welcome, step-by-step enrollment, chats, conversation, new chat, contacts, contact verification, settings (identity; security and recovery; connection; app), devices, encrypted history, keys for new groups, and appearance. Each replaces an existing page listed in the Spanish table.

- **Compact (< 600 dp):** bottom bar with Chats, Contacts and Settings. **Medium (600–839 dp):** the same with wider margins. **Expanded (≥ 840 dp):** list and conversation side by side; from 1200 dp a group details pane may stay open.
- Enrollment lives outside the main navigation.
- Shortcuts (⌘ on macOS, Ctrl elsewhere): ⌘N new chat, ⌘K search chats, ⌥↑/⌥↓ previous/next chat, ⌘, settings, Esc closes a pane or dialog; on desktop Enter sends and Shift+Enter inserts a line.
- Delivery: empty `delivery` → attention alert ("saved only on this device"); pending → clock; all `accepted…` → one check, "accepted by the server", never "read"; any `undeliverable…` → danger alert; any `expired/unknown` → attention alert. Long press or secondary click shows per-mailbox detail.
- Every `AttachmentStateView` state has its own presentation; `Pending` never downloads automatically and a 403 is not presented as expiry.

## Personalization

**First version, in the beta (D1):** system/light/dark theme; six curated accents validated by the contrast test (no free color picker); plain or four to six app-drawn vector chat backgrounds with light and dark variants behind opaque bubbles; text size 90–130 % on top of the system setting; system/Spanish/English language. These global preferences reveal nothing about the profile and are needed before unlocking it, so they are stored as atomically written JSON in the app support directory, outside `profile/`. They must never contain conversation IDs, names, routes or images.

**Second version, after the beta:** per-conversation background or accent and a user photo as background. Anything tied to a conversation or containing a user image lives **inside the encrypted profile**, managed by Rust, under the profile's backup exclusion. Preferences are not synced between devices.

## Data the UI needs

Findings from September 25, 2026: `HistoryEventView` has no sender or time, and the receive path in `arveil-app` records events without the sender that `mls-rs` identifies through `sender_index` (resolved for live history by A1). `ConversationView` has no last message, last activity or unread count, and there is no read marker (resolved by A2). The profile database has no schema versioning (`CREATE TABLE IF NOT EXISTS` only; resolved by A0). Kit export or deferral lives only in panel memory (resolved by A3). The last sync time exists only in the Dart conversation controller, which syncs every 10 seconds while open; that is acceptable as presentation state.

## Implementation plan

One small PR per package with its own tests. Relative size: S (up to a day), M (one or two days), L (more than two days). Ordered by dependency, without a calendar. Details and acceptance tests are in the [Spanish plan](es/CLIENT_DESIGN.md#plan-de-implementación).

| Package | Size | Depends on | Summary |
|---|---|---|---|
| A0 Profile schema versioning (implemented) | M | — | `PRAGMA user_version`, ordered transactional migrations, typed rejection of a future version without touching data; existing unversioned databases (builds up to `0.1.0+11`) are version 0 |
| A1 Sender and time in history (implemented) | M | A0 | Store the sender device and identity from the MLS member credential; `HistoryEventView` gains sender, label, own flag and `created_at` (local recording time, not send time) |
| A1b Sender in the encrypted history (implemented) | S | A1 | Optional sender field inside archive format v1, like `file_present`, so older builds keep importing; `archived_events` gains the column; imported records stay imported history, not proof of authorship |
| A2 Conversation summary and unread (implemented) | M | A1 | Last event, unread count and last activity in `ConversationView`; monotonic local read marker with `mark_read`; Rust orders by activity |
| A3 Recovery state and system notices (implemented) | S | A0 | Persist last successful kit export; record a local notice when an accepted manifest changes a contact's active devices; Dart sync-status projection from typed errors |
| B1 Tokens, theme and components (implemented) | L | — | `ThemeExtension` tokens, light and dark themes, bundled fonts and icons, component set, splash from the brand mark (the app icon exists since `0.1.0+11`); contrast unit test and component goldens on the macOS CI job |
| B2 Spanish/English localization (implemented) | M | — | `gen-l10n` ARB files with Spanish as template; extract every visible string; tests keep finding the Spanish text, the normative language, and a separate test walks the app in English |
| C1 Adaptive navigation and shortcuts (implemented) | M | B1 | Three size classes, separate enrollment route, desktop shortcuts with tested focus order; ⌘K arrives with the search in C2 |
| C2 Chat list (implemented) | S | A2, A3, C1 | Full rows, persistent kit notice, sync indicator, name search with ⌘K, empty state |
| C3 Conversation (implemented) | M | A1, A3, C1 | Grouped bubbles, date separators, delivery detail, attachment states, system notices, offline banner, composer, `mark_read`, desktop details pane |
| C4 Welcome and enrollment | M | B1, B2 | Three entry points, step-by-step invitation flow, pairing and restore, kit with "Later" and visible risk |
| C5 Contacts, verification and settings | M | B1, B2, A3 | Contacts and new chat, safety-number grid, sectioned settings, devices, encrypted history and keys migrated |
| D1 Appearance | M | B1, C1 | First-version personalization with immediate changes and safe defaults |
| E1 Accessibility | M | C2–C5, D1 | Semantics labels, focus order, 200 % text without overflow, reduced motion; manual TalkBack (physical Android) and VoiceOver (macOS) review |
| E2 Secret-free diagnostics | S | C5 | Exported report with version, OS, locale, profile state and typed error codes only; a test searches it for test-profile secrets |
| E3 Documentation and screenshots | S | E1, E2 | Update installation, client foundation and platform docs in both languages |
| F1 QR invitation (optional) | L | B1 | Versioned join payload documented as one-use sensitive data; relay `invite` may print a QR; camera only after tapping "Scan"; paste always available; never logged |
| F2 In-conversation search (optional) | S | B1 | Bounded Rust query over the open conversation; the search button stays hidden until it exists |

A and B can proceed in parallel.

## Exit conditions for the redesign

- Every screen uses tokens and components; outside `design/` and `l10n/` no hardcoded colors or visible strings remain.
- Goldens for the main screens at 390×844 and 1280×800 in light and dark; the contrast test passes.
- `flutter analyze`, widget and integration tests, Rust tests with `--locked`, Clippy, and all four phase scripts when the query layer changes.
- Upgrading from `0.1.0+10` with a populated profile keeps identity, conversations, history and read markers on the Android emulator and macOS, following the [client package procedure](CLIENT_RELEASES.md).
- A new packaged candidate passes the package audit, with results recorded in the [platform matrix](PLATFORMS.md).
- Spanish and English documentation updated.

Meeting these conditions does not close M3b.5: physical-hardware acceptance, three external users, versioned server images and the capability-expiry decision remain, and can proceed in parallel.

## Implementation notes

- Regenerate `flutter_rust_bridge` bindings when the bridge API changes; CI checks for drift.
- A new `arveil-core` dependency requires refreshing the `spikes/mls` lockfile, which uses the core by path, and `cargo test --locked` in both.
- Run `flutter analyze` on the whole project, not only `lib/`.
- Keep `unsafe_code` forbidden in the core and application layer.
