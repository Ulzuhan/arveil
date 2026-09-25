//! Bounded archive access; imported files stay in the profile's encrypted DB.
use super::Client;
use crate::recovery::{ArchiveRecord, MAX_ARCHIVE_PAYLOAD_BYTES, MAX_ARCHIVE_RECORDS};
use rusqlite::{OptionalExtension, params};

impl Client {
    /// Snapshot of live and imported history. A live event wins the same ID.
    /// Check aggregate lengths before reading bodies from a potentially large DB.
    pub fn archive_snapshot(&self) -> rusqlite::Result<Vec<(bool, ArchiveRecord)>> {
        self.unit_of_work(|| {
        let conn = self.conn.lock();
        // Local notices describe this profile's view of a conversation;
        // they are not history anybody wrote, so archives leave them out.
        // Live events name their author as history does: the identity
        // stored with the event, the roster's identity for its device, or
        // this profile's own for what this device sent.
        let sql = format!("SELECT 1 AS live, group_id, event_id, kind, body, created_at, NULL AS file_name, X'' AS file, 0 AS file_present,
                COALESCE(e.sender_identity,
                    (SELECT p.peer_identity FROM peers p
                      WHERE p.group_id = e.group_id AND p.device_id = e.sender_device),
                    CASE WHEN e.kind IN ({own}) THEN (SELECT identity_id FROM identity WHERE id = 1) END)
                  AS sender_identity
            FROM events e
            WHERE kind != '{notice}'
            UNION ALL SELECT 0, a.group_id, a.event_id, kind, body, created_at, file_name, COALESCE(f.bytes, X''), f.bytes IS NOT NULL, a.sender_identity
            FROM archived_events a LEFT JOIN archived_files f USING(group_id,event_id)
            WHERE NOT EXISTS(SELECT 1 FROM events e WHERE e.group_id=a.group_id AND e.event_id=a.event_id)",
            own = crate::delivery::OWN_KINDS
                .iter()
                .map(|kind| format!("'{kind}'"))
                .collect::<Vec<_>>()
                .join(", "),
            notice = crate::delivery::DEVICES_CHANGED);
        let (count, size): (i64, i64) = conn.query_row(&format!(
            "SELECT count(*), COALESCE(sum(length(body)+length(file)+length(group_id)+length(event_id)+length(kind)+COALESCE(length(file_name),0)+COALESCE(length(sender_identity),0)+256),0) FROM ({sql})"
        ), [], |r| Ok((r.get(0)?,r.get(1)?)))?;
        if count > MAX_ARCHIVE_RECORDS as i64 || size > MAX_ARCHIVE_PAYLOAD_BYTES as i64 {
            return Err(rusqlite::Error::InvalidQuery);
        }
        conn.prepare(&sql)?
            .query_map([], |r| {
                Ok((
                    r.get(0)?,
                    ArchiveRecord {
                        group_id: r.get(1)?,
                        event_id: r.get(2)?,
                        kind: r.get(3)?,
                        body: r.get(4)?,
                        created_at: r.get(5)?,
                        file_name: r.get(6)?,
                        file: r.get(7)?,
                        file_present: r.get(8)?,
                        sender_identity: r.get(9)?,
                    },
                ))
            })?
            .collect()
        })
    }

    /// Stable descending row-id cursor. File payloads are never loaded for a page.
    pub fn archive_page(
        &self,
        before: Option<i64>,
        limit: usize,
    ) -> rusqlite::Result<Vec<(i64, ArchiveRecord, Option<u64>)>> {
        let conn = self.conn.lock();
        let mut statement = conn.prepare(
            "SELECT a.rowid, a.group_id,a.event_id,kind,body,created_at,file_name,length(f.bytes),a.sender_identity
             FROM archived_events a LEFT JOIN archived_files f USING(group_id,event_id)
             WHERE a.rowid < ?1 ORDER BY a.rowid DESC LIMIT ?2",
        )?;
        statement
            .query_map(
                params![before.unwrap_or(i64::MAX), limit.clamp(1, 101) as i64],
                |r| {
                    Ok((
                        r.get(0)?,
                        ArchiveRecord {
                            group_id: r.get(1)?,
                            event_id: r.get(2)?,
                            kind: r.get(3)?,
                            body: r.get(4)?,
                            created_at: r.get(5)?,
                            file_name: r.get(6)?,
                            file: vec![],
                            file_present: false,
                            sender_identity: r.get(8)?,
                        },
                        r.get::<_, Option<i64>>(7)?.map(|n| n as u64),
                    ))
                },
            )?
            .collect()
    }

    pub fn archive_file(&self, group: &[u8], event: &[u8]) -> rusqlite::Result<Option<Vec<u8>>> {
        self.conn
            .lock()
            .query_row(
                "SELECT bytes FROM archived_files WHERE group_id=?1 AND event_id=?2",
                params![group, event],
                |r| r.get(0),
            )
            .optional()
    }
}
