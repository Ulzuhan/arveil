//! Revocation journal, on the same encrypted connection as MLS and the outbox.
use super::Client;
use rusqlite::{OptionalExtension, params};

pub struct Revocation {
    pub device_id: Vec<u8>,
    pub notification_id: Vec<u8>,
    pub relay_published: bool,
}

impl Client {
    /// Call in the unit that signs the revocation. A retry retains its marker.
    pub(super) fn revocation_start(&self, device: &[u8], marker: &[u8]) -> rusqlite::Result<()> {
        self.conn.lock().execute(
            "INSERT OR IGNORE INTO device_revocations (device_id, notification_id) VALUES (?1, ?2)",
            params![device, marker],
        )?;
        Ok(())
    }

    pub fn revocations(&self) -> rusqlite::Result<Vec<Revocation>> {
        self.conn.lock().prepare(
            "SELECT device_id, notification_id, relay_published FROM device_revocations ORDER BY rowid",
        )?.query_map([], |r| Ok(Revocation {
            device_id: r.get(0)?, notification_id: r.get(1)?, relay_published: r.get(2)?,
        }))?.collect()
    }

    pub fn revocation_published(&self, device: &[u8]) -> rusqlite::Result<()> {
        self.conn.lock().execute(
            "UPDATE device_revocations SET relay_published = 1 WHERE device_id = ?1",
            [device],
        )?;
        Ok(())
    }

    pub fn revocation_group_queued(&self, device: &[u8], group: &[u8]) -> rusqlite::Result<bool> {
        Ok(self
            .conn
            .lock()
            .query_row(
                "SELECT 1 FROM revocation_groups WHERE device_id = ?1 AND group_id = ?2",
                params![device, group],
                |_| Ok(()),
            )
            .optional()?
            .is_some())
    }

    /// Atomic with MLS persistence and the envelopes it produced.
    pub fn revocation_group_record(
        &self,
        device: &[u8],
        group: &[u8],
        without_route: usize,
    ) -> rusqlite::Result<()> {
        self.conn.lock().execute(
            "INSERT INTO revocation_groups (device_id, group_id, without_route) VALUES (?1, ?2, ?3)
             ON CONFLICT(device_id, group_id) DO UPDATE SET without_route = without_route + excluded.without_route",
            params![device, group, without_route as i64],
        )?;
        Ok(())
    }

    pub fn revocation_without_route(&self, device: &[u8]) -> rusqlite::Result<u32> {
        self.conn.lock().query_row(
            "SELECT COALESCE(SUM(without_route), 0) FROM revocation_groups WHERE device_id = ?1",
            [device],
            |r| r.get(0),
        )
    }
}
