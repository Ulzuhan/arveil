use std::path::PathBuf;

use super::*;
use crate::storage::SharedConn;

/// A fresh profile path for one test; the directory is recreated empty.
fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("arveil-schema-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir.join("client.db")
}

fn cleanup(path: &std::path::Path) {
    std::fs::remove_dir_all(path.parent().unwrap()).ok();
}

fn version_of(conn: &Connection) -> u32 {
    schema_version(conn).unwrap()
}

fn count(conn: &Connection, table: &str) -> i64 {
    conn.query_row(&format!("SELECT count(*) FROM {table}"), [], |r| r.get(0))
        .unwrap()
}

fn schema_text(conn: &Connection) -> String {
    conn.query_row(
        "SELECT group_concat(sql, ';') FROM (SELECT sql FROM sqlite_schema ORDER BY name)",
        [],
        |r| r.get(0),
    )
    .unwrap()
}

#[test]
fn migrations_are_contiguous_and_end_at_the_current_version() {
    for (index, migration) in MIGRATIONS.iter().enumerate() {
        assert_eq!(migration.version, index as u32 + 1);
    }
    assert_eq!(MIGRATIONS.last().unwrap().version, PROFILE_SCHEMA_VERSION);
}

#[test]
fn a_new_profile_starts_at_the_current_version_with_every_table() {
    let conn = SharedConn::open_in_memory().unwrap();
    let conn = conn.lock();
    assert_eq!(version_of(&conn), PROFILE_SCHEMA_VERSION);

    let reference = Connection::open_in_memory().unwrap();
    reference.execute_batch(&baseline_schema()).unwrap();
    assert_eq!(tables(&conn).unwrap(), tables(&reference).unwrap());
}

/// What every build before versioning left behind: the baseline tables it
/// knew about, version 0, and rows that must survive adoption.
#[test]
fn an_unversioned_profile_is_adopted_with_its_rows() {
    let path = scratch("adopt");
    {
        let old = Connection::open(&path).unwrap();
        old.execute_batch(&baseline_schema()).unwrap();
        // Tables a later build added do not exist yet.
        old.execute_batch("DROP TABLE realm; DROP TABLE peer_manifests;")
            .unwrap();
        old.execute_batch(
            "INSERT INTO events (group_id, event_id, kind, body)
                 VALUES (x'01', x'02', 'received', CAST('hola' AS BLOB));
             INSERT INTO contacts (identity_id, root_public, name)
                 VALUES (x'03', x'04', 'Lucía');",
        )
        .unwrap();
        assert_eq!(version_of(&old), 0);
    }

    let conn = SharedConn::open_file(&path).unwrap();
    let conn = conn.lock();
    assert_eq!(version_of(&conn), PROFILE_SCHEMA_VERSION);
    assert_eq!(count(&conn, "events"), 1);
    let (body, name): (Vec<u8>, String) = conn
        .query_row(
            "SELECT body, (SELECT name FROM contacts) FROM events",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert_eq!(
        (body.as_slice(), name.as_str()),
        (b"hola".as_slice(), "Lucía")
    );
    // The missing tables were added, empty.
    assert_eq!(count(&conn, "realm"), 0);
    assert_eq!(count(&conn, "peer_manifests"), 0);
    drop(conn);
    cleanup(&path);
}

/// Contact names arrived with Phase 4 by editing the table text in place;
/// a profile from before has the table without the column.
#[test]
fn a_contact_table_from_before_names_gains_the_column() {
    let path = scratch("repair");
    {
        let old = Connection::open(&path).unwrap();
        old.execute_batch(&baseline_schema()).unwrap();
        old.execute_batch(
            "DROP TABLE contacts;
             CREATE TABLE contacts (
                 identity_id BLOB PRIMARY KEY,
                 root_public BLOB NOT NULL,
                 verified    INTEGER NOT NULL DEFAULT 0,
                 verified_at INTEGER,
                 first_seen  INTEGER NOT NULL DEFAULT (unixepoch())
             );
             INSERT INTO contacts (identity_id, root_public, verified) VALUES (x'05', x'06', 1);",
        )
        .unwrap();
    }

    let conn = SharedConn::open_file(&path).unwrap();
    let conn = conn.lock();
    assert_eq!(version_of(&conn), PROFILE_SCHEMA_VERSION);
    let row: (Vec<u8>, bool, Option<String>) = conn
        .query_row(
            "SELECT identity_id, verified, name FROM contacts",
            [],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .unwrap();
    assert_eq!(row, (vec![5], true, None));
    drop(conn);
    cleanup(&path);
}

/// A shape no supported build wrote (here the Phase 0 identity table) is
/// refused, and the rollback leaves its tables and rows as it found them.
#[test]
fn an_unsupported_shape_is_refused_and_left_as_it_was() {
    let path = scratch("unsupported");
    {
        let old = Connection::open(&path).unwrap();
        old.execute_batch(
            "CREATE TABLE identity (
                 id          INTEGER PRIMARY KEY CHECK (id = 1),
                 root_seed   BLOB NOT NULL,
                 identity_id BLOB NOT NULL
             );
             INSERT INTO identity VALUES (1, x'07', x'08');",
        )
        .unwrap();
    }
    let before = {
        let old = Connection::open(&path).unwrap();
        schema_text(&old)
    };

    match SharedConn::open_file(&path) {
        Err(StorageError::UnsupportedSchema { table, .. }) => assert_eq!(table, "identity"),
        other => panic!("expected an unsupported schema, got {other:?}"),
    }

    let after = Connection::open(&path).unwrap();
    assert_eq!(version_of(&after), 0);
    assert_eq!(
        schema_text(&after),
        before,
        "baseline tables were rolled back"
    );
    assert_eq!(count(&after, "identity"), 1);
    drop(after);
    cleanup(&path);
}

/// A profile from a newer build is refused before anything writes to it,
/// including the journal-mode pragma.
#[test]
fn a_newer_profile_is_refused_without_writes() {
    let path = scratch("newer");
    {
        let newer = Connection::open(&path).unwrap();
        newer
            .execute_batch("CREATE TABLE future (v BLOB); PRAGMA user_version = 7;")
            .unwrap();
    }
    let before = std::fs::read(&path).unwrap();

    match SharedConn::open_file(&path) {
        Err(StorageError::SchemaTooNew { found, supported }) => {
            assert_eq!((found, supported), (7, PROFILE_SCHEMA_VERSION));
        }
        other => panic!("expected a newer schema, got {other:?}"),
    }
    assert_eq!(std::fs::read(&path).unwrap(), before);
    assert!(!path.with_extension("db-wal").exists());
    cleanup(&path);
}

/// The same check works through SQLCipher, after the key opened the file.
#[test]
fn a_newer_encrypted_profile_is_refused() {
    let path = scratch("newer-keyed");
    let key = "c".repeat(64);
    drop(SharedConn::open_file_keyed(&path, Some(&key)).unwrap());
    {
        let newer = Connection::open(&path).unwrap();
        newer
            .execute_batch(&format!(
                "PRAGMA key = \"x'{key}'\"; PRAGMA user_version = 9;"
            ))
            .unwrap();
    }

    assert!(matches!(
        SharedConn::open_file_keyed(&path, Some(&key)),
        Err(StorageError::SchemaTooNew { found: 9, .. })
    ));
    // A wrong key is still a wrong key, not a version problem.
    assert!(matches!(
        SharedConn::open_file_keyed(&path, Some(&"d".repeat(64))),
        Err(StorageError::WrongKey)
    ));
    cleanup(&path);
}

#[test]
fn a_negative_version_is_refused() {
    let path = scratch("negative");
    {
        let odd = Connection::open(&path).unwrap();
        odd.execute_batch("PRAGMA user_version = -1;").unwrap();
    }
    assert!(matches!(
        SharedConn::open_file(&path),
        Err(StorageError::UnsupportedSchema { table, .. }) if table == "user_version"
    ));
    cleanup(&path);
}

fn create_step(conn: &Connection) -> Result<(), StorageError> {
    conn.execute_batch("CREATE TABLE step_two (v BLOB)")?;
    Ok(())
}

fn broken_step(conn: &Connection) -> Result<(), StorageError> {
    conn.execute_batch("CREATE TABLE step_two (v BLOB)")?;
    Err(StorageError::UnsupportedSchema {
        table: "step_two".into(),
        detail: "failed half way on purpose".into(),
    })
}

#[test]
fn a_failed_migration_keeps_the_previous_version_and_a_later_one_resumes() {
    let conn = Connection::open_in_memory().unwrap();
    let broken = [
        Migration {
            version: 1,
            apply: baseline,
        },
        Migration {
            version: 2,
            apply: broken_step,
        },
    ];
    assert!(migrate_with(&conn, &broken).is_err());
    assert_eq!(version_of(&conn), 1, "the baseline committed on its own");
    let exists: i64 = conn
        .query_row(
            "SELECT count(*) FROM sqlite_schema WHERE name = 'step_two'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(exists, 0, "the failed step left nothing behind");

    let fixed = [
        Migration {
            version: 1,
            apply: baseline,
        },
        Migration {
            version: 2,
            apply: create_step,
        },
    ];
    migrate_with(&conn, &fixed).unwrap();
    assert_eq!(version_of(&conn), 2);
    assert_eq!(count(&conn, "step_two"), 0);
}

#[test]
fn reopening_changes_nothing() {
    let path = scratch("reopen");
    let first = SharedConn::open_file(&path).unwrap();
    first
        .lock()
        .execute(
            "INSERT INTO events (group_id, event_id, kind, body) VALUES (x'09', x'0a', 'sent', x'0b')",
            [],
        )
        .unwrap();
    let schema = schema_text(&first.lock());
    drop(first);

    let second = SharedConn::open_file(&path).unwrap();
    let second = second.lock();
    assert_eq!(version_of(&second), PROFILE_SCHEMA_VERSION);
    assert_eq!(schema_text(&second), schema);
    assert_eq!(count(&second, "events"), 1);
    drop(second);
    cleanup(&path);
}
