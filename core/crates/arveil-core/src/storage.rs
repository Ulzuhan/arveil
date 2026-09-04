//! Local encrypted database: one SQLite connection shared by everything the
//! core persists, so that a *unit of work* (see `docs/DOMAIN_MODEL.md` §5) is
//! literally one SQLite transaction.
//!
//! Phase 0 scope: plain SQLite with the durability settings of ADR-004.
//! SQLCipher and the OS-wrapped key are Phase 2 work.

use std::path::Path;
use std::sync::{Arc, Mutex, MutexGuard};

use rusqlite::Connection;

/// Durability profile required by ADR-004 for every database that holds
/// cryptographic state. Applied to file-backed connections; in-memory
/// databases used by tests ignore the journal settings.
const PRAGMAS: &str = "
PRAGMA journal_mode = WAL;
PRAGMA synchronous = FULL;
PRAGMA busy_timeout = 5000;
PRAGMA foreign_keys = ON;
";

const SCHEMA: &str = "
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
CREATE TABLE IF NOT EXISTS mls_key_package (
    id         BLOB PRIMARY KEY,
    data       BLOB NOT NULL,
    expiration INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS mls_psk (
    id  BLOB PRIMARY KEY,
    psk BLOB NOT NULL
);
";

#[derive(Debug, thiserror::Error)]
pub enum StorageError {
    #[error("sqlite: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error(
        "embedded SQLite {found} is older than the required {required} (ADR-004 WAL-reset fix)"
    )]
    SqliteTooOld {
        found: &'static str,
        required: &'static str,
    },
}

/// Minimum SQLite version carrying the WAL-reset fix required by ADR-004.
pub const MIN_SQLITE_VERSION: &str = "3.51.3";
const MIN_SQLITE_VERSION_NUMBER: i32 = 3_051_003;

/// Shared handle to the core's single connection. Cloning shares it.
///
/// The mutex is held only for the duration of one statement; transactions
/// are expressed with explicit `BEGIN`/`COMMIT`/`ROLLBACK` statements so that
/// library callbacks (the MLS storage providers) can run inside them without
/// holding the lock across a callback.
#[derive(Clone, Debug)]
pub struct SharedConn(Arc<Mutex<Connection>>);

impl SharedConn {
    /// In-memory database for tests and throwaway state.
    pub fn open_in_memory() -> Result<Self, StorageError> {
        Self::init(Connection::open_in_memory()?, false)
    }

    /// File-backed database with the ADR-004 durability pragmas applied.
    pub fn open_file(path: &Path) -> Result<Self, StorageError> {
        Self::init(Connection::open(path)?, true)
    }

    fn init(conn: Connection, durable: bool) -> Result<Self, StorageError> {
        if rusqlite::version_number() < MIN_SQLITE_VERSION_NUMBER {
            return Err(StorageError::SqliteTooOld {
                found: rusqlite::version(),
                required: MIN_SQLITE_VERSION,
            });
        }
        if durable {
            conn.execute_batch(PRAGMAS)?;
        }
        conn.execute_batch(SCHEMA)?;
        Ok(Self(Arc::new(Mutex::new(conn))))
    }

    /// Lock the connection for one statement or one short sequence.
    pub fn lock(&self) -> MutexGuard<'_, Connection> {
        self.0.lock().expect("sqlite connection mutex poisoned")
    }

    /// Run `f` inside one transaction. Commits if `f` returns `Ok`, rolls
    /// back otherwise. `f` must not hold the lock across calls that may lock
    /// again, and must not open its own transaction.
    pub fn unit_of_work<T, E>(&self, f: impl FnOnce(&Self) -> Result<T, E>) -> Result<T, E>
    where
        E: From<rusqlite::Error>,
    {
        self.lock().execute_batch("BEGIN IMMEDIATE")?;
        match f(self) {
            Ok(value) => {
                self.lock().execute_batch("COMMIT")?;
                Ok(value)
            }
            Err(e) => {
                // Best effort: if rollback itself fails the connection is unusable anyway.
                let _ = self.lock().execute_batch("ROLLBACK");
                Err(e)
            }
        }
    }

    /// Row count of a table; test and diagnostics helper.
    pub fn count(&self, table: &str) -> Result<i64, rusqlite::Error> {
        self.lock()
            .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |r| r.get(0))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn embedded_sqlite_meets_adr_004_minimum() {
        assert!(
            rusqlite::version_number() >= MIN_SQLITE_VERSION_NUMBER,
            "bundled SQLite {} is older than {MIN_SQLITE_VERSION}",
            rusqlite::version()
        );
    }

    #[test]
    fn unit_of_work_commits_or_rolls_back() {
        let conn = SharedConn::open_in_memory().unwrap();
        conn.lock()
            .execute_batch("CREATE TABLE scratch (v BLOB)")
            .unwrap();
        let insert = |c: &SharedConn| {
            c.lock()
                .execute("INSERT INTO scratch (v) VALUES (x'01')", [])
        };

        let failed: Result<(), rusqlite::Error> = conn.unit_of_work(|c| {
            insert(c)?;
            Err(rusqlite::Error::InvalidQuery)
        });
        assert!(failed.is_err());
        assert_eq!(conn.count("scratch").unwrap(), 0);

        conn.unit_of_work(|c| insert(c).map(|_| ())).unwrap();
        assert_eq!(conn.count("scratch").unwrap(), 1);
    }
}
