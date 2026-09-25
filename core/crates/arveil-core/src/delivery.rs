//! Durable outbox and inbox (DOMAIN_MODEL §5, invariants I-04 and I-05).
//!
//! **Send unit**: the caller opens one unit of work, advances MLS
//! (`write_to_storage`), records the local event and enqueues one outbox row
//! per recipient device with the *sealed bytes*. Nothing is sent before that
//! transaction commits; retransmissions reuse the stored bytes and never
//! re-run MLS encryption from an older state.
//!
//! **Receive unit**: the caller opens one unit of work, records the delivery
//! in the inbox (deduplication), processes the MLS message and stores the
//! event. Only after the commit is the relay ACKed. A duplicate delivery is
//! detected before any MLS processing.

use rusqlite::{OptionalExtension, params};

use crate::storage::SharedConn;

#[path = "attachment_store.rs"]
mod attachment_store;
pub use attachment_store::AttachmentRow;

/// Delivery tables, part of the version 1 baseline in [`crate::schema`].
/// Frozen: a change to these tables is a new migration, not an edit here.
pub const DELIVERY_SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS outbox (
    id          INTEGER PRIMARY KEY,
    mailbox_id  BLOB NOT NULL,
    delivery_id BLOB NOT NULL,
    event_id    BLOB,
    hpke_enc    BLOB NOT NULL,
    ciphertext  BLOB NOT NULL,
    state       TEXT NOT NULL DEFAULT 'sealed',
    attempts    INTEGER NOT NULL DEFAULT 0,
    expires_at  INTEGER,
    created_at  INTEGER NOT NULL DEFAULT (unixepoch()),
    UNIQUE (mailbox_id, delivery_id)
);
CREATE TABLE IF NOT EXISTS inbox (
    mailbox_id  BLOB NOT NULL,
    delivery_id BLOB NOT NULL,
    seq         INTEGER NOT NULL,
    received_at INTEGER NOT NULL DEFAULT (unixepoch()),
    acked       INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (mailbox_id, delivery_id)
);
CREATE TABLE IF NOT EXISTS mailbox_cursor (
    mailbox_id BLOB PRIMARY KEY,
    cursor     INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS events (
    id         INTEGER PRIMARY KEY,
    group_id   BLOB NOT NULL,
    event_id   BLOB NOT NULL UNIQUE,
    kind       TEXT NOT NULL,
    body       BLOB NOT NULL,
    created_at INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE TABLE IF NOT EXISTS attachment_transfers (
    event_id BLOB PRIMARY KEY REFERENCES events(event_id),
    outgoing INTEGER NOT NULL,
    name TEXT NOT NULL,
    size INTEGER NOT NULL,
    state TEXT NOT NULL,
    descriptor BLOB NOT NULL,
    offset INTEGER NOT NULL DEFAULT 0,
    committed INTEGER NOT NULL DEFAULT 0,
    expires_at INTEGER
);
CREATE TABLE IF NOT EXISTS attachment_chunks (
    event_id BLOB NOT NULL REFERENCES attachment_transfers(event_id),
    offset INTEGER NOT NULL,
    data BLOB NOT NULL,
    PRIMARY KEY (event_id, offset)
);
";

/// One event as the archive carries it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ExportedEvent {
    pub group_id: Vec<u8>,
    pub event_id: Vec<u8>,
    pub kind: String,
    pub body: Vec<u8>,
    pub created_at: i64,
}

/// A local event: `(event_id, kind, body)`.
pub type EventRow = (Vec<u8>, String, Vec<u8>);

/// The device that wrote an event, as MLS authenticated it, and the
/// identity this profile knows for that device, if any yet.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EventSender {
    pub device_id: Vec<u8>,
    pub identity_id: Option<Vec<u8>>,
}

/// A stored event with its position in the conversation.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PagedEvent {
    pub cursor: i64,
    pub event_id: Vec<u8>,
    pub kind: String,
    pub body: Vec<u8>,
    /// Unix seconds when this device recorded it: arrival for what it
    /// received, creation for what it sent.
    pub created_at: i64,
    /// Empty for events recorded before senders were kept, and for events
    /// no MLS sender stands behind.
    pub sender_device: Option<Vec<u8>>,
    pub sender_identity: Option<Vec<u8>>,
}

/// One sealed envelope waiting for, or accepted by, the relay.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OutboxRow {
    pub id: i64,
    pub mailbox_id: Vec<u8>,
    pub delivery_id: Vec<u8>,
    pub event_id: Option<Vec<u8>>,
    pub hpke_enc: Vec<u8>,
    pub ciphertext: Vec<u8>,
    pub state: String,
    pub attempts: i64,
}

pub struct Delivery {
    conn: SharedConn,
}

impl Delivery {
    /// Pending and failed/expired notifications; acceptance is not delivery.
    pub fn notification_counts(&self, event: &[u8], now: i64) -> rusqlite::Result<(u32, u32)> {
        self.conn.lock().query_row(
            "SELECT COALESCE(SUM(state = 'sealed'), 0),
                    COALESCE(SUM(state = 'undeliverable' OR (state = 'accepted' AND expires_at <= ?2)), 0)
             FROM outbox WHERE event_id = ?1",
            params![event, now], |r| Ok((r.get(0)?, r.get(1)?)),
        )
    }

    /// Wrap an open profile connection. Opening the connection already
    /// brought its schema up to date (see [`crate::schema`]).
    pub fn open(conn: SharedConn) -> Result<Self, rusqlite::Error> {
        Ok(Self { conn })
    }

    /// Enqueue one sealed envelope for the event it carries. Call inside
    /// the send unit of work.
    pub fn enqueue(
        &self,
        mailbox_id: &[u8],
        delivery_id: &[u8],
        event_id: Option<&[u8]>,
        hpke_enc: &[u8],
        ciphertext: &[u8],
    ) -> Result<(), rusqlite::Error> {
        self.conn.lock().execute(
            "INSERT INTO outbox (mailbox_id, delivery_id, event_id, hpke_enc, ciphertext) VALUES (?1, ?2, ?3, ?4, ?5)",
            params![mailbox_id, delivery_id, event_id, hpke_enc, ciphertext],
        )?;
        Ok(())
    }

    /// Delivery state of every envelope produced for an event, as the
    /// sender can truthfully know it: `queued`, `accepted` (with the relay's
    /// effective expiry) or `expired-unknown` once that expiry has passed.
    /// Relay acceptance never becomes "delivered" or "read" (DOMAIN_MODEL §6).
    pub fn states_for_event(
        &self,
        event_id: &[u8],
        now: i64,
    ) -> Result<Vec<(Vec<u8>, String)>, rusqlite::Error> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT mailbox_id, state, expires_at FROM outbox WHERE event_id = ?1 ORDER BY id",
        )?;
        let rows = stmt.query_map(params![event_id], |r| {
            let mailbox: Vec<u8> = r.get(0)?;
            let state: String = r.get(1)?;
            let expires: Option<i64> = r.get(2)?;
            let label = match (state.as_str(), expires) {
                ("sealed", _) => "queued".to_string(),
                ("accepted", Some(t)) if t <= now => "expired/unknown".to_string(),
                ("accepted", Some(t)) => format!("accepted (relay keeps it until {t})"),
                ("accepted", None) => "accepted".to_string(),
                ("undeliverable", _) => "undeliverable (mailbox refused)".to_string(),
                (other, _) => other.to_string(),
            };
            Ok((mailbox, label))
        })?;
        rows.collect()
    }

    /// Record a local event. Call inside the send or receive unit of work.
    pub fn record_event(
        &self,
        group_id: &[u8],
        event_id: &[u8],
        kind: &str,
        body: &[u8],
    ) -> Result<(), rusqlite::Error> {
        self.record_event_by(group_id, event_id, kind, body, None)
    }

    /// Record a local event together with who wrote it.
    pub fn record_event_by(
        &self,
        group_id: &[u8],
        event_id: &[u8],
        kind: &str,
        body: &[u8],
        sender: Option<&EventSender>,
    ) -> Result<(), rusqlite::Error> {
        self.conn.lock().execute(
            "INSERT INTO events (group_id, event_id, kind, body, sender_device, sender_identity)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                group_id,
                event_id,
                kind,
                body,
                sender.map(|s| &s.device_id),
                sender.and_then(|s| s.identity_id.as_ref()),
            ],
        )?;
        Ok(())
    }

    /// Rows still to be published, oldest first. The bytes are the ones to
    /// retransmit; they are never regenerated.
    pub fn pending(&self) -> Result<Vec<OutboxRow>, rusqlite::Error> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT id, mailbox_id, delivery_id, event_id, hpke_enc, ciphertext, state, attempts
             FROM outbox WHERE state = 'sealed' ORDER BY id",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok(OutboxRow {
                id: r.get(0)?,
                mailbox_id: r.get(1)?,
                delivery_id: r.get(2)?,
                event_id: r.get(3)?,
                hpke_enc: r.get(4)?,
                ciphertext: r.get(5)?,
                state: r.get(6)?,
                attempts: r.get(7)?,
            })
        })?;
        rows.collect()
    }

    pub fn mark_attempt(&self, id: i64) -> Result<(), rusqlite::Error> {
        self.conn.lock().execute(
            "UPDATE outbox SET attempts = attempts + 1 WHERE id = ?1",
            params![id],
        )?;
        Ok(())
    }

    /// The relay refused this envelope for good (revoked capability, gone
    /// mailbox). The row stays for the history; it is never retried and
    /// never counted as delivered.
    pub fn mark_undeliverable(&self, id: i64) -> Result<(), rusqlite::Error> {
        self.conn.lock().execute(
            "UPDATE outbox SET state = 'undeliverable' WHERE id = ?1",
            params![id],
        )?;
        Ok(())
    }

    /// The relay confirmed durable custody until `expires_at`. Idempotent.
    pub fn mark_accepted(&self, id: i64, expires_at: Option<i64>) -> Result<(), rusqlite::Error> {
        self.conn.lock().execute(
            "UPDATE outbox SET state = 'accepted', expires_at = COALESCE(?2, expires_at) WHERE id = ?1",
            params![id, expires_at],
        )?;
        Ok(())
    }

    /// Record an incoming delivery. Returns `false` if it was already
    /// recorded (duplicate). Call inside the receive unit of work, before
    /// any MLS processing.
    pub fn record_incoming(
        &self,
        mailbox_id: &[u8],
        delivery_id: &[u8],
        seq: i64,
    ) -> Result<bool, rusqlite::Error> {
        let n = self.conn.lock().execute(
            "INSERT OR IGNORE INTO inbox (mailbox_id, delivery_id, seq) VALUES (?1, ?2, ?3)",
            params![mailbox_id, delivery_id, seq],
        )?;
        Ok(n == 1)
    }

    /// Deliveries recorded but not yet ACKed to the relay.
    pub fn unacked(&self, mailbox_id: &[u8]) -> Result<Vec<Vec<u8>>, rusqlite::Error> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT delivery_id FROM inbox WHERE mailbox_id = ?1 AND acked = 0 ORDER BY seq",
        )?;
        let rows = stmt.query_map(params![mailbox_id], |r| r.get(0))?;
        rows.collect()
    }

    pub fn mark_acked(
        &self,
        mailbox_id: &[u8],
        delivery_ids: &[Vec<u8>],
    ) -> Result<(), rusqlite::Error> {
        let conn = self.conn.lock();
        for d in delivery_ids {
            conn.execute(
                "UPDATE inbox SET acked = 1 WHERE mailbox_id = ?1 AND delivery_id = ?2",
                params![mailbox_id, d],
            )?;
        }
        Ok(())
    }

    pub fn cursor(&self, mailbox_id: &[u8]) -> Result<i64, rusqlite::Error> {
        Ok(self
            .conn
            .lock()
            .query_row(
                "SELECT cursor FROM mailbox_cursor WHERE mailbox_id = ?1",
                params![mailbox_id],
                |r| r.get(0),
            )
            .optional()?
            .unwrap_or(0))
    }

    pub fn set_cursor(&self, mailbox_id: &[u8], cursor: i64) -> Result<(), rusqlite::Error> {
        self.conn.lock().execute(
            "INSERT INTO mailbox_cursor (mailbox_id, cursor) VALUES (?1, ?2)
             ON CONFLICT(mailbox_id) DO UPDATE
             SET cursor = MAX(mailbox_cursor.cursor, excluded.cursor)",
            params![mailbox_id, cursor],
        )?;
        Ok(())
    }

    pub fn event_count(&self) -> Result<i64, rusqlite::Error> {
        self.conn.count("events")
    }

    /// Events of one kind across all groups: `(event_id, kind, body)`.
    pub fn events_of_kind(&self, kind: &str) -> Result<Vec<EventRow>, rusqlite::Error> {
        let conn = self.conn.lock();
        let mut stmt =
            conn.prepare("SELECT event_id, kind, body FROM events WHERE kind = ?1 ORDER BY id")?;
        let rows = stmt.query_map(params![kind], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?;
        rows.collect()
    }

    /// Move an event to another kind with a new body (a pending file that
    /// was downloaded, or found unavailable).
    pub fn update_event(
        &self,
        event_id: &[u8],
        kind: &str,
        body: &[u8],
    ) -> Result<(), rusqlite::Error> {
        self.conn.lock().execute(
            "UPDATE events SET kind = ?2, body = ?3 WHERE event_id = ?1",
            params![event_id, kind, body],
        )?;
        Ok(())
    }

    /// Events of a group: `(event_id, kind, body)` in local order.
    /// Every local event with its conversation and time, for the archive.
    pub fn all_events(&self) -> Result<Vec<ExportedEvent>, rusqlite::Error> {
        let conn = self.conn.lock();
        let mut stmt = conn
            .prepare("SELECT group_id, event_id, kind, body, created_at FROM events ORDER BY id")?;
        let rows = stmt.query_map([], |r| {
            Ok(ExportedEvent {
                group_id: r.get(0)?,
                event_id: r.get(1)?,
                kind: r.get(2)?,
                body: r.get(3)?,
                created_at: r.get(4)?,
            })
        })?;
        rows.collect()
    }

    /// How many events one conversation holds, without reading any of
    /// them: a summary needs the number, not the bodies.
    pub fn events_count(&self, group_id: &[u8]) -> Result<usize, rusqlite::Error> {
        let conn = self.conn.lock();
        let count: i64 = conn.query_row(
            "SELECT count(*) FROM events WHERE group_id = ?1",
            params![group_id],
            |r| r.get(0),
        )?;
        Ok(count as usize)
    }

    /// One page of a conversation's events, newest first. `before` excludes
    /// everything at or above that cursor, so a page never shifts under a
    /// reader: an event recorded meanwhile takes a higher identifier and
    /// belongs to a newer page, never to one already read.
    pub fn events_page(
        &self,
        group_id: &[u8],
        before: Option<i64>,
        limit: usize,
    ) -> Result<Vec<PagedEvent>, rusqlite::Error> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT id, event_id, kind, body, created_at, sender_device, sender_identity
             FROM events
             WHERE group_id = ?1 AND (?2 IS NULL OR id < ?2)
             ORDER BY id DESC LIMIT ?3",
        )?;
        let rows = stmt.query_map(params![group_id, before, limit as i64], |r| {
            Ok(PagedEvent {
                cursor: r.get(0)?,
                event_id: r.get(1)?,
                kind: r.get(2)?,
                body: r.get(3)?,
                created_at: r.get(4)?,
                sender_device: r.get(5)?,
                sender_identity: r.get(6)?,
            })
        })?;
        rows.collect()
    }

    pub fn events(&self, group_id: &[u8]) -> Result<Vec<EventRow>, rusqlite::Error> {
        let conn = self.conn.lock();
        let mut stmt = conn
            .prepare("SELECT event_id, kind, body FROM events WHERE group_id = ?1 ORDER BY id")?;
        let rows = stmt.query_map(params![group_id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?;
        rows.collect()
    }
}

#[cfg(test)]
mod tests;
