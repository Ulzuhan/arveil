//! GUI attachment state shares the event/MLS transaction and encrypted database.
//! Bytes are ciphertext; descriptors (including keys) never leave the profile.
use super::Delivery;
use rusqlite::{OptionalExtension, params};

pub struct AttachmentRow {
    pub outgoing: bool,
    pub name: String,
    pub size: u64,
    pub state: String,
    pub descriptor: Vec<u8>,
    pub offset: u64,
    pub committed: bool,
    pub expires_at: Option<u64>,
}

impl Delivery {
    /// Scoped lookup: an identifier from another conversation is never accepted.
    pub fn event(&self, group: &[u8], id: &[u8]) -> rusqlite::Result<Option<(String, Vec<u8>)>> {
        self.conn
            .lock()
            .query_row(
                "SELECT kind, body FROM events WHERE group_id = ?1 AND event_id = ?2",
                params![group, id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()
    }

    pub fn attachment(&self, id: &[u8]) -> rusqlite::Result<Option<AttachmentRow>> {
        self.conn
            .lock()
            .query_row(
                "SELECT outgoing, name, size, state, descriptor, offset, committed, expires_at
             FROM attachment_transfers WHERE event_id = ?1",
                [id],
                |r| {
                    Ok(AttachmentRow {
                        outgoing: r.get(0)?,
                        name: r.get(1)?,
                        size: uint(r.get(2)?)?,
                        state: r.get(3)?,
                        descriptor: r.get(4)?,
                        offset: uint(r.get(5)?)?,
                        committed: r.get(6)?,
                        expires_at: r.get::<_, Option<i64>>(7)?.map(uint).transpose()?,
                    })
                },
            )
            .optional()
    }

    pub fn attachment_create(&self, id: &[u8], row: &AttachmentRow) -> rusqlite::Result<()> {
        self.conn.lock().execute(
            "INSERT INTO attachment_transfers (event_id, outgoing, name, size, state, descriptor)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                id,
                row.outgoing,
                row.name,
                integer(row.size)?,
                row.state,
                row.descriptor
            ],
        )?;
        Ok(())
    }

    pub fn attachment_state(&self, id: &[u8], state: &str) -> rusqlite::Result<()> {
        self.conn.lock().execute(
            "UPDATE attachment_transfers SET state = ?2 WHERE event_id = ?1",
            params![id, state],
        )?;
        Ok(())
    }

    pub fn attachment_offset(&self, id: &[u8], offset: u64) -> rusqlite::Result<()> {
        self.conn.lock().execute(
            "UPDATE attachment_transfers SET offset = ?2 WHERE event_id = ?1",
            params![id, integer(offset)?],
        )?;
        Ok(())
    }

    pub fn attachment_descriptor(
        &self,
        id: &[u8],
        descriptor: &[u8],
        expiry: Option<u64>,
    ) -> rusqlite::Result<()> {
        self.conn.lock().execute(
            "UPDATE attachment_transfers SET descriptor = ?2, committed = ?3, expires_at = ?4 WHERE event_id = ?1",
            params![id, descriptor, expiry.is_some(), expiry.map(integer).transpose()?],
        )?;
        Ok(())
    }

    pub fn attachment_chunk(&self, id: &[u8], offset: u64, bytes: &[u8]) -> rusqlite::Result<()> {
        self.conn.lock().execute(
            "INSERT INTO attachment_chunks (event_id, offset, data) VALUES (?1, ?2, ?3)",
            params![id, integer(offset)?, bytes],
        )?;
        Ok(())
    }

    /// Reject gaps, overlapping chunks and oversized local data before allocation.
    pub fn attachment_bytes(&self, id: &[u8], max: usize) -> rusqlite::Result<Vec<u8>> {
        let conn = self.conn.lock();
        let mut statement = conn.prepare(
            "SELECT offset, data FROM attachment_chunks WHERE event_id = ?1 ORDER BY offset",
        )?;
        let mut rows = statement.query([id])?;
        let mut bytes = Vec::new();
        while let Some(row) = rows.next()? {
            let offset = uint(row.get(0)?)?;
            let chunk = row.get_ref(1)?.as_blob()?;
            if offset != bytes.len() as u64 || chunk.len() > max.saturating_sub(bytes.len()) {
                return Err(rusqlite::Error::InvalidQuery);
            }
            bytes.extend_from_slice(chunk);
        }
        Ok(bytes)
    }

    /// Caller wraps this with the state change in its unit of work.
    pub fn attachment_clear_bytes(&self, id: &[u8]) -> rusqlite::Result<()> {
        self.conn
            .lock()
            .execute("DELETE FROM attachment_chunks WHERE event_id = ?1", [id])?;
        self.attachment_offset(id, 0)
    }
}

fn integer(value: u64) -> rusqlite::Result<i64> {
    i64::try_from(value).map_err(|_| rusqlite::Error::InvalidQuery)
}
fn uint(value: i64) -> rusqlite::Result<u64> {
    u64::try_from(value).map_err(|_| rusqlite::Error::InvalidQuery)
}
