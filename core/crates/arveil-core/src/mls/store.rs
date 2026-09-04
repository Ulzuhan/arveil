//! mls-rs storage providers over the core's shared SQLite connection.
//!
//! Every write lands in whatever transaction the application currently holds
//! on the connection (see `SharedConn::unit_of_work`). mls-rs only writes
//! group state on an explicit `write_to_storage`, which is what makes the
//! send and receive units of the domain model single transactions.

use mls_rs_codec::{MlsDecode, MlsEncode};
use mls_rs_core::error::IntoAnyError;
use mls_rs_core::group::{EpochRecord, GroupState, GroupStateStorage};
use mls_rs_core::key_package::{KeyPackageData, KeyPackageStorage};
use mls_rs_core::psk::{ExternalPskId, PreSharedKey, PreSharedKeyStorage};
use rusqlite::{OptionalExtension, params};
use zeroize::Zeroizing;

use crate::storage::SharedConn;

#[derive(Debug, thiserror::Error)]
pub enum StoreError {
    #[error("sqlite: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("codec: {0}")]
    Codec(#[from] mls_rs_codec::Error),
}

impl IntoAnyError for StoreError {
    fn into_dyn_error(self) -> Result<Box<dyn std::error::Error + Send + Sync>, Self> {
        Ok(Box::new(self))
    }
}

/// Group state and epoch records.
#[derive(Clone, Debug)]
pub struct SqliteGroupStore {
    conn: SharedConn,
}

impl SqliteGroupStore {
    pub fn new(conn: SharedConn) -> Self {
        Self { conn }
    }
}

#[cfg_attr(not(mls_build_async), maybe_async::must_be_sync)]
#[cfg_attr(mls_build_async, maybe_async::must_be_async)]
impl GroupStateStorage for SqliteGroupStore {
    type Error = StoreError;

    async fn state(&self, group_id: &[u8]) -> Result<Option<Zeroizing<Vec<u8>>>, Self::Error> {
        let data: Option<Vec<u8>> = self
            .conn
            .lock()
            .query_row(
                "SELECT data FROM mls_group_state WHERE group_id = ?1",
                params![group_id],
                |r| r.get(0),
            )
            .optional()?;
        Ok(data.map(Zeroizing::new))
    }

    async fn epoch(
        &self,
        group_id: &[u8],
        epoch_id: u64,
    ) -> Result<Option<Zeroizing<Vec<u8>>>, Self::Error> {
        let data: Option<Vec<u8>> = self
            .conn
            .lock()
            .query_row(
                "SELECT data FROM mls_epoch WHERE group_id = ?1 AND epoch_id = ?2",
                params![group_id, epoch_id as i64],
                |r| r.get(0),
            )
            .optional()?;
        Ok(data.map(Zeroizing::new))
    }

    async fn write(
        &mut self,
        state: GroupState,
        epoch_inserts: Vec<EpochRecord>,
        epoch_updates: Vec<EpochRecord>,
    ) -> Result<(), Self::Error> {
        let conn = self.conn.lock();
        conn.execute(
            "INSERT INTO mls_group_state (group_id, data) VALUES (?1, ?2)
             ON CONFLICT(group_id) DO UPDATE SET data = excluded.data",
            params![state.id, state.data.as_slice()],
        )?;
        for record in epoch_inserts.into_iter().chain(epoch_updates) {
            conn.execute(
                "INSERT INTO mls_epoch (group_id, epoch_id, data) VALUES (?1, ?2, ?3)
                 ON CONFLICT(group_id, epoch_id) DO UPDATE SET data = excluded.data",
                params![state.id, record.id as i64, record.data.as_slice()],
            )?;
        }
        Ok(())
    }

    async fn max_epoch_id(&self, group_id: &[u8]) -> Result<Option<u64>, Self::Error> {
        let max: Option<i64> = self.conn.lock().query_row(
            "SELECT MAX(epoch_id) FROM mls_epoch WHERE group_id = ?1",
            params![group_id],
            |r| r.get(0),
        )?;
        Ok(max.map(|m| m as u64))
    }
}

/// Private material of published KeyPackages, keyed by KeyPackage reference.
#[derive(Clone, Debug)]
pub struct SqliteKeyPackageStore {
    conn: SharedConn,
}

impl SqliteKeyPackageStore {
    pub fn new(conn: SharedConn) -> Self {
        Self { conn }
    }
}

#[cfg_attr(not(mls_build_async), maybe_async::must_be_sync)]
#[cfg_attr(mls_build_async, maybe_async::must_be_async)]
impl KeyPackageStorage for SqliteKeyPackageStore {
    type Error = StoreError;

    async fn delete(&mut self, id: &[u8]) -> Result<(), Self::Error> {
        self.conn
            .lock()
            .execute("DELETE FROM mls_key_package WHERE id = ?1", params![id])?;
        Ok(())
    }

    async fn insert(&mut self, id: Vec<u8>, pkg: KeyPackageData) -> Result<(), Self::Error> {
        let data = pkg.mls_encode_to_vec()?;
        self.conn.lock().execute(
            "INSERT INTO mls_key_package (id, data, expiration) VALUES (?1, ?2, ?3)
             ON CONFLICT(id) DO UPDATE SET data = excluded.data, expiration = excluded.expiration",
            params![id, data, pkg.expiration as i64],
        )?;
        Ok(())
    }

    async fn get(&self, id: &[u8]) -> Result<Option<KeyPackageData>, Self::Error> {
        let data: Option<Vec<u8>> = self
            .conn
            .lock()
            .query_row(
                "SELECT data FROM mls_key_package WHERE id = ?1",
                params![id],
                |r| r.get(0),
            )
            .optional()?;
        match data {
            Some(bytes) => Ok(Some(KeyPackageData::mls_decode(&mut bytes.as_slice())?)),
            None => Ok(None),
        }
    }
}

/// External pre-shared keys. Arveil does not use external PSKs in Phase 0;
/// the table exists so the provider is complete and lookups are honest.
#[derive(Clone, Debug)]
pub struct SqlitePskStore {
    conn: SharedConn,
}

impl SqlitePskStore {
    pub fn new(conn: SharedConn) -> Self {
        Self { conn }
    }
}

#[cfg_attr(not(mls_build_async), maybe_async::must_be_sync)]
#[cfg_attr(mls_build_async, maybe_async::must_be_async)]
impl PreSharedKeyStorage for SqlitePskStore {
    type Error = StoreError;

    async fn get(&self, id: &ExternalPskId) -> Result<Option<PreSharedKey>, Self::Error> {
        let psk: Option<Vec<u8>> = self
            .conn
            .lock()
            .query_row(
                "SELECT psk FROM mls_psk WHERE id = ?1",
                params![id.as_ref()],
                |r| r.get(0),
            )
            .optional()?;
        Ok(psk.map(PreSharedKey::from))
    }
}
