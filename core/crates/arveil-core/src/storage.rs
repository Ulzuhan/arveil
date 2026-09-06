//! Local encrypted database: one SQLite connection shared by everything the
//! core persists, so that a *unit of work* (see `docs/DOMAIN_MODEL.md` §5) is
//! literally one SQLite transaction.
//!
//! Encryption at rest (M2.6): given a 32-byte key as 64 hex characters, the
//! file is opened through SQLCipher with that raw key, which covers every
//! table on this connection (identity, MLS provider state, outbox, events)
//! and the WAL. Without a key the file is plain SQLite, and `arveil status`
//! says so rather than implying protection that is not there. Human-chosen
//! passwords are refused on purpose (`docs/PROTOCOL.md` §9): the key is high
//! entropy or nothing. The key reaches this module as an argument; reading
//! the environment is the caller's job.

use std::path::Path;
use std::sync::Arc;

use parking_lot::{ReentrantMutex, ReentrantMutexGuard};
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
        "ARVEIL_DB_KEY must be 32 bytes as 64 hex characters (generate one with `openssl rand -hex 32`)"
    )]
    BadKey,
    #[error("this database is encrypted with a different key, or it is not an Arveil database")]
    WrongKey,
    #[error("this build has no SQLCipher, so ARVEIL_DB_KEY cannot be honoured")]
    NoSqlcipher,
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

/// Apply the raw key and prove it opens the file. The key pragma must be
/// the first statement on the connection; the read that follows is what
/// tells a wrong key from a right one, since SQLCipher only fails when it
/// tries to decrypt a page.
fn unlock(conn: &Connection, key: &str) -> Result<(), StorageError> {
    let key = key.trim();
    if key.len() != 64 || !key.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(StorageError::BadKey);
    }
    let version: Option<String> = conn
        .query_row("PRAGMA cipher_version", [], |r| r.get(0))
        .ok();
    if version.is_none_or(|v| v.is_empty()) {
        return Err(StorageError::NoSqlcipher);
    }
    // The key is validated hex above, so this literal cannot inject.
    conn.execute_batch(&format!("PRAGMA key = \"x'{key}'\";"))?;
    conn.query_row("SELECT count(*) FROM sqlite_master", [], |_| Ok(()))
        .map_err(|_| StorageError::WrongKey)?;
    Ok(())
}

/// Shared handle to the core's single connection. Cloning shares it.
///
/// A unit of work retains exclusive ownership of the connection until it
/// commits or rolls back. The mutex is reentrant because MLS storage callbacks
/// access this same connection while the transaction is active.
#[derive(Clone, Debug)]
pub struct SharedConn(Arc<ReentrantMutex<Connection>>);

/// A transaction that has begun and not yet ended. Dropping it rolls back,
/// which is what keeps an unwind from leaving one open on a connection the
/// next caller will use.
struct OpenTransaction<'a> {
    connection: &'a Connection,
}

impl OpenTransaction<'_> {
    fn rollback(&mut self) {
        // Best effort: if rollback itself fails the connection is unusable
        // anyway, and the session that owns it is already ending.
        let _ = self.connection.execute_batch("ROLLBACK");
    }
}

impl Drop for OpenTransaction<'_> {
    fn drop(&mut self) {
        self.rollback();
    }
}

impl SharedConn {
    /// In-memory database for tests and throwaway state.
    pub fn open_in_memory() -> Result<Self, StorageError> {
        Self::init(Connection::open_in_memory()?, false)
    }

    /// File-backed database with the ADR-004 durability pragmas applied.
    pub fn open_file(path: &Path) -> Result<Self, StorageError> {
        Self::open_file_keyed(path, None)
    }

    /// The same, encrypted at rest when `key` is 64 hex characters.
    pub fn open_file_keyed(path: &Path, key: Option<&str>) -> Result<Self, StorageError> {
        let conn = Connection::open(path)?;
        if let Some(key) = key {
            unlock(&conn, key)?;
        }
        Self::init(conn, true)
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
        Ok(Self(Arc::new(ReentrantMutex::new(conn))))
    }

    /// Lock the connection for one statement or one short sequence.
    pub fn lock(&self) -> ReentrantMutexGuard<'_, Connection> {
        self.0.lock()
    }

    /// Run `f` inside one transaction. Commits if `f` returns `Ok`, rolls
    /// back otherwise, and rolls back if `f` panics: an unwind that left the
    /// transaction open would hand the next caller a connection already
    /// inside one. Other threads cannot interleave statements before the
    /// transaction ends. `f` must not open its own transaction.
    pub fn unit_of_work<T, E>(&self, f: impl FnOnce(&Self) -> Result<T, E>) -> Result<T, E>
    where
        E: From<rusqlite::Error>,
    {
        let transaction = self.lock();
        transaction.execute_batch("BEGIN IMMEDIATE")?;
        // Declared after the lock, so it runs while the lock is still held.
        let mut open = OpenTransaction {
            connection: &transaction,
        };
        match f(self) {
            Ok(value) => {
                std::mem::forget(open);
                transaction.execute_batch("COMMIT")?;
                Ok(value)
            }
            Err(e) => {
                open.rollback();
                std::mem::forget(open);
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

    /// A file database with a key holds no readable header, no table names
    /// and no payload; the wrong key does not open it.
    #[test]
    fn a_keyed_database_is_unreadable_without_its_key() {
        let dir = std::env::temp_dir().join(format!("arveil-cipher-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("client.db");
        let _ = std::fs::remove_file(&path);
        let key = "a".repeat(64);
        {
            let c = SharedConn::open_file_keyed(&path, Some(&key)).unwrap();
            c.lock()
                .execute_batch(
                    "CREATE TABLE secrets (v TEXT); INSERT INTO secrets VALUES ('hola familia')",
                )
                .unwrap();
        }
        let raw = std::fs::read(&path).unwrap();
        assert!(!raw.starts_with(b"SQLite format 3"), "plaintext header");
        for needle in [b"hola familia".as_slice(), b"secrets".as_slice()] {
            assert!(
                !raw.windows(needle.len()).any(|w| w == needle),
                "{} found in the database file",
                String::from_utf8_lossy(needle)
            );
        }
        // The same key opens it again; another key does not, and neither
        // does opening it without one.
        SharedConn::open_file_keyed(&path, Some(&key)).unwrap();
        assert!(matches!(
            SharedConn::open_file_keyed(&path, Some(&"b".repeat(64))),
            Err(StorageError::WrongKey)
        ));
        assert!(matches!(
            SharedConn::open_file_keyed(&path, Some("not-hex")),
            Err(StorageError::BadKey)
        ));
        assert!(SharedConn::open_file(&path).is_err());
        std::fs::remove_dir_all(&dir).ok();
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

    #[test]
    fn a_panic_inside_a_unit_of_work_rolls_back_and_leaves_the_connection_usable() {
        let conn = SharedConn::open_in_memory().unwrap();
        conn.lock()
            .execute_batch("CREATE TABLE scratch (v BLOB)")
            .unwrap();

        let panicking = conn.clone();
        let panicked = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _: Result<(), rusqlite::Error> = panicking.unit_of_work(|c| {
                c.lock()
                    .execute("INSERT INTO scratch (v) VALUES (x'01')", [])?;
                panic!("the work gave up half way");
            });
        }));
        assert!(panicked.is_err(), "the panic must reach the caller");

        // The insert is gone, and no transaction was left open: a new one
        // can begin and commit on the same connection.
        assert_eq!(conn.count("scratch").unwrap(), 0);
        conn.unit_of_work(|c| {
            c.lock()
                .execute("INSERT INTO scratch (v) VALUES (x'02')", [])
                .map(|_| ())
        })
        .unwrap();
        assert_eq!(conn.count("scratch").unwrap(), 1);
    }

    #[test]
    fn unit_of_work_prevents_interleaved_statements() {
        use std::sync::mpsc;

        let conn = SharedConn::open_in_memory().unwrap();
        conn.lock()
            .execute_batch("CREATE TABLE ordering (position INTEGER PRIMARY KEY, actor TEXT)")
            .unwrap();

        let other = conn.clone();
        let (start_tx, start_rx) = mpsc::channel();
        let (attempting_tx, attempting_rx) = mpsc::channel();
        let worker = std::thread::spawn(move || {
            start_rx.recv().unwrap();
            attempting_tx.send(()).unwrap();
            other
                .lock()
                .execute("INSERT INTO ordering (actor) VALUES ('other')", [])
                .unwrap();
        });

        conn.unit_of_work(|c| {
            c.lock()
                .execute("INSERT INTO ordering (actor) VALUES ('first')", [])?;
            start_tx.send(()).unwrap();
            attempting_rx.recv().unwrap();
            c.lock()
                .execute("INSERT INTO ordering (actor) VALUES ('second')", [])?;
            Ok::<_, rusqlite::Error>(())
        })
        .unwrap();
        worker.join().unwrap();

        let actors = conn
            .lock()
            .prepare("SELECT actor FROM ordering ORDER BY position")
            .unwrap()
            .query_map([], |row| row.get::<_, String>(0))
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        assert_eq!(actors, ["first", "second", "other"]);
    }
}
