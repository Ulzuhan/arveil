//! Q1 for mls-rs: `GroupStateStorage` over a shared `rusqlite::Connection`.
//!
//! The point is not the schema. The point is that the connection is *ours*:
//! the application opens the transaction, inserts its outbox row, asks mls-rs
//! to `write_to_storage()` through this provider, and then commits or rolls
//! back. Both writes share the transaction, so they succeed or vanish together.
//!
//! Not handled here (fine for a spike, required for the real core):
//! epoch retention trimming, key package and PSK storage over the same
//! connection, and the busy/locking behaviour of a shared connection.

use std::sync::{Arc, Mutex, MutexGuard};

use mls_rs::client_builder::MlsConfig;
use mls_rs::error::MlsError;
use mls_rs::identity::SigningIdentity;
use mls_rs::identity::basic::{BasicCredential, BasicIdentityProvider};
use mls_rs::{CipherSuite, CipherSuiteProvider, Client, CryptoProvider};
use mls_rs_core::error::IntoAnyError;
use mls_rs_core::group::{EpochRecord, GroupState, GroupStateStorage};
use mls_rs_crypto_rustcrypto::RustCryptoProvider;
use rusqlite::{Connection, OptionalExtension, params};
use zeroize::Zeroizing;

const CIPHERSUITE: CipherSuite = CipherSuite::CURVE25519_AES128;

pub const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS mls_group_state (
    group_id BLOB PRIMARY KEY,
    data     BLOB NOT NULL
);
CREATE TABLE IF NOT EXISTS mls_epoch (
    group_id BLOB NOT NULL,
    epoch_id INTEGER NOT NULL,
    data     BLOB NOT NULL,
    PRIMARY KEY (group_id, epoch_id)
);
CREATE TABLE IF NOT EXISTS outbox (
    id      INTEGER PRIMARY KEY,
    payload BLOB NOT NULL
);
";

#[derive(Debug)]
pub struct SqliteStorageError(pub rusqlite::Error);

impl From<rusqlite::Error> for SqliteStorageError {
    fn from(e: rusqlite::Error) -> Self {
        Self(e)
    }
}

impl IntoAnyError for SqliteStorageError {
    fn into_dyn_error(self) -> Result<Box<dyn std::error::Error + Send + Sync>, Self> {
        Ok(Box::new(self.0))
    }
}

/// Shared handle to one SQLite connection. Cloning shares the connection.
#[derive(Clone)]
pub struct SharedConn(Arc<Mutex<Connection>>);

impl SharedConn {
    pub fn open_in_memory() -> rusqlite::Result<Self> {
        let conn = Connection::open_in_memory()?;
        conn.execute_batch(SCHEMA)?;
        Ok(Self(Arc::new(Mutex::new(conn))))
    }

    pub fn lock(&self) -> MutexGuard<'_, Connection> {
        self.0.lock().expect("connection mutex poisoned")
    }

    pub fn count(&self, table: &str) -> i64 {
        self.lock()
            .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |r| r.get(0))
            .expect("count")
    }
}

/// `GroupStateStorage` that writes into whatever transaction is open on the
/// shared connection. If none is open, each statement autocommits, which is
/// exactly the behaviour the real core must never rely on.
#[derive(Clone)]
pub struct TxSqliteGroupStorage {
    conn: SharedConn,
}

impl TxSqliteGroupStorage {
    pub fn new(conn: SharedConn) -> Self {
        Self { conn }
    }
}

#[cfg_attr(not(mls_build_async), maybe_async::must_be_sync)]
#[cfg_attr(mls_build_async, maybe_async::must_be_async)]
impl GroupStateStorage for TxSqliteGroupStorage {
    type Error = SqliteStorageError;

    async fn state(&self, group_id: &[u8]) -> Result<Option<Zeroizing<Vec<u8>>>, Self::Error> {
        let conn = self.conn.lock();
        let data: Option<Vec<u8>> = conn
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
        let conn = self.conn.lock();
        let data: Option<Vec<u8>> = conn
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
        let conn = self.conn.lock();
        let max: Option<i64> = conn.query_row(
            "SELECT MAX(epoch_id) FROM mls_epoch WHERE group_id = ?1",
            params![group_id],
            |r| r.get(0),
        )?;
        Ok(max.map(|m| m as u64))
    }
}

pub fn make_client_with_storage(
    name: &str,
    storage: TxSqliteGroupStorage,
) -> Result<Client<impl MlsConfig>, MlsError> {
    let crypto = RustCryptoProvider::default();
    let suite = crypto
        .cipher_suite_provider(CIPHERSUITE)
        .expect("cipher suite");
    let (secret, public) = suite.signature_key_generate().expect("signing key");
    let identity = SigningIdentity::new(
        BasicCredential::new(name.as_bytes().to_vec()).into_credential(),
        public,
    );
    Ok(Client::builder()
        .identity_provider(BasicIdentityProvider)
        .crypto_provider(crypto)
        .group_state_storage(storage)
        .signing_identity(identity, secret, CIPHERSUITE)
        .build())
}

/// The Q1 experiment. Returns counts of `(outbox, group_state)` rows and
/// whether `load_group` succeeds, after a rolled-back transaction and after a
/// committed one.
pub struct Q1Outcome {
    pub after_rollback: (i64, i64, bool),
    pub after_commit: (i64, i64, bool),
}

pub fn q1_shared_transaction() -> Result<Q1Outcome, MlsError> {
    let conn = SharedConn::open_in_memory().expect("sqlite");
    let client = make_client_with_storage("alice", TxSqliteGroupStorage::new(conn.clone()))?;

    let mut group = client.group_builder()?.build()?;
    let group_id = group.group_id().to_vec();

    // One unit of work: our outbox row + the MLS group state. Roll it back.
    conn.lock().execute_batch("BEGIN").expect("begin");
    conn.lock()
        .execute(
            "INSERT INTO outbox (payload) VALUES (?1)",
            params![b"ciphertext-1"],
        )
        .expect("outbox insert");
    group.write_to_storage()?;
    conn.lock().execute_batch("ROLLBACK").expect("rollback");
    let after_rollback = (
        conn.count("outbox"),
        conn.count("mls_group_state"),
        client.load_group(&group_id).is_ok(),
    );

    // Same unit of work, committed.
    conn.lock().execute_batch("BEGIN").expect("begin");
    conn.lock()
        .execute(
            "INSERT INTO outbox (payload) VALUES (?1)",
            params![b"ciphertext-1"],
        )
        .expect("outbox insert");
    group.write_to_storage()?;
    conn.lock().execute_batch("COMMIT").expect("commit");
    let after_commit = (
        conn.count("outbox"),
        conn.count("mls_group_state"),
        client.load_group(&group_id).is_ok(),
    );

    Ok(Q1Outcome {
        after_rollback,
        after_commit,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Q1 for mls-rs, answered: the group state write participates in the
    /// application's transaction because the provider runs on the same
    /// connection and mls-rs only writes on the explicit `write_to_storage`.
    /// https://github.com/Ulzuhan/arveil/issues/15
    #[test]
    fn q1_group_state_and_outbox_row_commit_or_roll_back_together() {
        let outcome = q1_shared_transaction().expect("q1");
        assert_eq!(
            outcome.after_rollback,
            (0, 0, false),
            "rollback discards both the outbox row and the MLS group state"
        );
        assert_eq!(
            outcome.after_commit,
            (1, 1, true),
            "commit persists both, and the group is loadable afterwards"
        );
    }
}
