//! Personal invitation operations live in the encrypted profile, not Dart.
use super::{Client, ClientError};
use rusqlite::{OptionalExtension, params};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InvitationOperation {
    pub id: Vec<u8>,
    pub direction: String,
    pub link: String,
    pub request_key: Vec<u8>,
    pub claim_key: Vec<u8>,
    pub secret: Vec<u8>,
    pub state: String,
    pub created_at: i64,
    pub expires_at: i64,
    pub claimant: Vec<u8>,
    pub group_id: Vec<u8>,
    pub key_package: Vec<u8>,
    pub checked_at: i64,
}
#[derive(Clone, Debug)]
pub struct InvitationHello {
    pub group_id: Vec<u8>,
    pub invitation_id: Vec<u8>,
    pub sender: Vec<u8>,
    pub name: Option<String>,
}
const COLUMNS: &str = "id,direction,link,request_key,claim_key,secret,state,created_at,expires_at,claimant,group_id,key_package,checked_at";
fn row(r: &rusqlite::Row<'_>) -> rusqlite::Result<InvitationOperation> {
    Ok(InvitationOperation {
        id: r.get(0)?,
        direction: r.get(1)?,
        link: r.get(2)?,
        request_key: r.get(3)?,
        claim_key: r.get(4)?,
        secret: r.get(5)?,
        state: r.get(6)?,
        created_at: r.get(7)?,
        expires_at: r.get(8)?,
        claimant: r.get(9)?,
        group_id: r.get(10)?,
        key_package: r.get(11)?,
        checked_at: r.get(12)?,
    })
}
impl Client {
    /// Only call after this relay definitively rejects redemption. A timeout
    /// never releases a pending enrollment, nor does a later-phase failure.
    pub fn invitation_rejected_enrollment(&self, id: &[u8]) -> Result<bool, ClientError> {
        Ok(self.conn.lock().execute("DELETE FROM enrollment WHERE invite_hash=?1 AND phase='redeeming' AND NOT EXISTS(SELECT 1 FROM realm WHERE enrolled=1)", [id])? == 1)
    }

    pub fn invitation_operation(
        &self,
        id: &[u8],
        direction: &str,
    ) -> Result<Option<InvitationOperation>, ClientError> {
        Ok(self
            .conn
            .lock()
            .query_row(
                &format!(
                    "SELECT {COLUMNS} FROM invitation_operations WHERE id=?1 AND direction=?2"
                ),
                params![id, direction],
                row,
            )
            .optional()?)
    }
    pub fn invitation_operations(
        &self,
        direction: &str,
    ) -> Result<Vec<InvitationOperation>, ClientError> {
        let conn = self.conn.lock();
        let mut stmt=conn.prepare(&format!("SELECT {COLUMNS} FROM invitation_operations WHERE direction=?1 ORDER BY created_at DESC,id"))?;
        Ok(stmt
            .query_map([direction], row)?
            .collect::<Result<_, _>>()?)
    }
    pub fn invitation_operation_save(&self, o: &InvitationOperation) -> Result<(), ClientError> {
        self.conn.lock().execute("INSERT INTO invitation_operations(id,direction,link,request_key,claim_key,secret,state,created_at,expires_at,claimant,group_id,key_package,checked_at) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13) ON CONFLICT(id,direction) DO UPDATE SET link=excluded.link,request_key=excluded.request_key,claim_key=excluded.claim_key,secret=excluded.secret,state=excluded.state,created_at=excluded.created_at,expires_at=excluded.expires_at,claimant=excluded.claimant,group_id=excluded.group_id,key_package=excluded.key_package,checked_at=excluded.checked_at",params![o.id,o.direction,o.link,o.request_key,o.claim_key,o.secret,o.state,o.created_at,o.expires_at,o.claimant,o.group_id,o.key_package,o.checked_at])?;
        Ok(())
    }
    /// Store only a hello already matched against this device's invitation secret.
    pub fn invitation_hello_save(&self, h: &InvitationHello) -> Result<(), ClientError> {
        self.conn.lock().execute("INSERT OR IGNORE INTO invitation_hellos(group_id,invitation_id,sender,name) VALUES(?1,?2,?3,?4)",params![h.group_id,h.invitation_id,h.sender,h.name])?;
        Ok(())
    }
    pub fn invitation_hellos(&self) -> Result<Vec<InvitationHello>, ClientError> {
        let conn = self.conn.lock();
        let mut stmt =
            conn.prepare("SELECT group_id,invitation_id,sender,name FROM invitation_hellos")?;
        Ok(stmt
            .query_map([], |r| {
                Ok(InvitationHello {
                    group_id: r.get(0)?,
                    invitation_id: r.get(1)?,
                    sender: r.get(2)?,
                    name: r.get(3)?,
                })
            })?
            .collect::<Result<_, _>>()?)
    }
    pub fn invitation_hello_remove(&self, group: &[u8]) -> Result<(), ClientError> {
        self.conn
            .lock()
            .execute("DELETE FROM invitation_hellos WHERE group_id=?1", [group])?;
        Ok(())
    }
    /// Drop no proof until both the invitation and the delivery retention have
    /// elapsed. Incoming prepared operations survive so an outbox can finish.
    pub fn invitation_cleanup(&self, now: i64) -> Result<(), ClientError> {
        let cutoff = now - 37 * 24 * 3600;
        self.conn.lock().execute("UPDATE invitation_operations SET link='',secret=X'',key_package=X'' WHERE (direction='outgoing' AND expires_at<?1) OR (direction='incoming' AND state='complete')",[cutoff])?;
        self.conn.lock().execute("DELETE FROM invitation_hellos WHERE invitation_id IN (SELECT id FROM invitation_operations WHERE direction='outgoing' AND expires_at<?1)",[cutoff])?;
        self.conn.lock().execute(
            "DELETE FROM invitation_operations WHERE direction='outgoing' AND expires_at<?1",
            [cutoff],
        )?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::storage::SharedConn;
    #[test]
    fn encrypted_reopen_preserves_progress_and_transaction_rollback() {
        let mut rand = [0; 8];
        getrandom::fill(&mut rand).unwrap();
        let path =
            std::env::temp_dir().join(format!("arveil-invitation-store-{}.db", hex::encode(rand)));
        let key = "49".repeat(32);
        let op = InvitationOperation {
            id: vec![1; 32],
            direction: "incoming".into(),
            link: "PRIVATE_INVITATION_FIXTURE".into(),
            request_key: vec![],
            claim_key: vec![2; 24],
            secret: vec![3; 16],
            state: "enrolled".into(),
            created_at: 1,
            expires_at: 2,
            claimant: vec![4; 32],
            group_id: vec![],
            key_package: vec![5; 100],
            checked_at: 1,
        };
        {
            let c = Client::open(SharedConn::open_file_keyed(&path, Some(&key)).unwrap()).unwrap();
            c.invitation_operation_save(&op).unwrap();
            let failed: Result<(), ClientError> = c.unit_of_work(|| {
                let mut next = op.clone();
                next.group_id = vec![6; 32];
                next.state = "prepared".into();
                c.invitation_operation_save(&next)?;
                Err(rusqlite::Error::InvalidQuery.into())
            });
            assert!(failed.is_err());
        }
        assert!(
            !std::fs::read(&path)
                .unwrap()
                .windows(op.link.len())
                .any(|b| b == op.link.as_bytes())
        );
        {
            let c = Client::open(SharedConn::open_file_keyed(&path, Some(&key)).unwrap()).unwrap();
            assert_eq!(
                c.invitation_operation(&op.id, "incoming").unwrap(),
                Some(op.clone())
            );
            let mut completed = op.clone();
            completed.state = "complete".into();
            completed.group_id = vec![6; 32];
            c.invitation_operation_save(&completed).unwrap();
            c.invitation_cleanup(3).unwrap();
            let stored = c.invitation_operation(&op.id, "incoming").unwrap().unwrap();
            assert!(
                stored.link.is_empty() && stored.secret.is_empty() && stored.key_package.is_empty()
            );
            assert_eq!(stored.group_id, completed.group_id);
        }
        let _ = std::fs::remove_file(path);
    }
}
