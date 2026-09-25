//! Versioned schema of the local profile database.
//!
//! `PRAGMA user_version` records the last migration a database has seen. A
//! database made before versioning existed reads 0, and so does a new one.
//! Each migration runs in its own transaction together with the version it
//! sets, so a failure leaves the previous version and its rows as they were.
//!
//! A database written by a newer build is refused before anything on this
//! connection writes to it: this build cannot know what the newer one
//! changed. Builds made before versioning existed do not check the version
//! at all, which is why migrations prefer additive changes.
//!
//! Migrations never change once released. A new table, column or data fix
//! is a new entry at the end of [`MIGRATIONS`], never an edit of the schema
//! text an earlier migration applied.

use std::collections::BTreeMap;

use rusqlite::Connection;

use crate::storage::StorageError;

/// The newest profile schema this build reads and writes.
pub const PROFILE_SCHEMA_VERSION: u32 = 1;

/// One step from `version - 1` to `version`.
pub(crate) struct Migration {
    pub(crate) version: u32,
    pub(crate) apply: fn(&Connection) -> Result<(), StorageError>,
}

const MIGRATIONS: &[Migration] = &[Migration {
    version: 1,
    apply: baseline,
}];

/// Bring `conn` up to [`PROFILE_SCHEMA_VERSION`].
pub(crate) fn migrate(conn: &Connection) -> Result<(), StorageError> {
    migrate_with(conn, MIGRATIONS)
}

/// The version `conn` records. Reading it writes nothing.
pub fn schema_version(conn: &Connection) -> Result<u32, StorageError> {
    let raw: i64 = conn.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    u32::try_from(raw).map_err(|_| StorageError::UnsupportedSchema {
        table: "user_version".into(),
        detail: format!("negative schema version {raw}"),
    })
}

pub(crate) fn migrate_with(
    conn: &Connection,
    migrations: &[Migration],
) -> Result<(), StorageError> {
    let supported = migrations.last().map_or(0, |m| m.version);
    let found = schema_version(conn)?;
    if found > supported {
        return Err(StorageError::SchemaTooNew { found, supported });
    }
    for migration in migrations.iter().filter(|m| m.version > found) {
        conn.execute_batch("BEGIN IMMEDIATE")?;
        // Read again under the write lock: another connection may have
        // applied this step while this one waited for it.
        let result = schema_version(conn).and_then(|current| {
            if current >= migration.version {
                return Ok(());
            }
            (migration.apply)(conn)?;
            conn.pragma_update(None, "user_version", migration.version)?;
            Ok(())
        });
        match result {
            Ok(()) => conn.execute_batch("COMMIT")?,
            Err(error) => {
                // Best effort: if the rollback itself fails, closing the
                // connection discards the uncommitted work anyway.
                let _ = conn.execute_batch("ROLLBACK");
                return Err(error);
            }
        }
    }
    Ok(())
}

/// Every table as the builds before versioning created them. Those builds
/// applied this text with `CREATE TABLE IF NOT EXISTS` on every open, so
/// running it here adds whatever tables an older profile is missing and
/// leaves the rest alone.
fn baseline_schema() -> String {
    [
        crate::storage::MLS_SCHEMA,
        crate::client::CLIENT_SCHEMA,
        crate::delivery::DELIVERY_SCHEMA,
    ]
    .concat()
}

/// Columns added to an existing table before versioning existed, without
/// a migration. A profile older than the change lacks them; each one is
/// nullable, so adding it keeps every row as it was.
const BASELINE_REPAIRS: &[(&str, &str, &str)] = &[
    // Contact names arrived with Phase 4.
    (
        "contacts",
        "name",
        "ALTER TABLE contacts ADD COLUMN name TEXT",
    ),
];

/// Version 1: adopt a profile made before versioning. A table that exists
/// with another shape is either a known additive gap, repaired here, or
/// the work of an unsupported development build, refused without change.
fn baseline(conn: &Connection) -> Result<(), StorageError> {
    let schema = baseline_schema();
    conn.execute_batch(&schema)?;

    let reference = Connection::open_in_memory()?;
    reference.execute_batch(&schema)?;
    for table in tables(&reference)? {
        let expected = columns(&reference, &table)?;
        let mut actual = columns(conn, &table)?;
        let missing: Vec<&String> = expected
            .keys()
            .filter(|n| !actual.contains_key(*n))
            .collect();
        for name in &missing {
            let (_, _, repair) = BASELINE_REPAIRS
                .iter()
                .find(|(t, c, _)| *t == table && c == name)
                .ok_or_else(|| StorageError::UnsupportedSchema {
                    table: table.clone(),
                    detail: format!("missing column {name}"),
                })?;
            conn.execute_batch(repair)?;
        }
        if !missing.is_empty() {
            actual = columns(conn, &table)?;
        }
        if actual != expected {
            let detail = actual
                .iter()
                .find(|(name, shape)| expected.get(*name) != Some(shape))
                .map_or_else(
                    || "unexpected column layout".to_string(),
                    |(name, _)| format!("column {name} differs"),
                );
            return Err(StorageError::UnsupportedSchema { table, detail });
        }
    }
    Ok(())
}

/// Declared type, NOT NULL, default and primary-key position of a column.
type ColumnShape = (String, bool, Option<String>, i64);

fn tables(conn: &Connection) -> Result<Vec<String>, StorageError> {
    let mut stmt = conn.prepare(
        "SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
    )?;
    let names = stmt
        .query_map([], |r| r.get(0))?
        .collect::<Result<Vec<String>, _>>()?;
    Ok(names)
}

fn columns(conn: &Connection, table: &str) -> Result<BTreeMap<String, ColumnShape>, StorageError> {
    let mut stmt =
        conn.prepare("SELECT name, type, \"notnull\", dflt_value, pk FROM pragma_table_info(?1)")?;
    let columns = stmt
        .query_map([table], |r| {
            Ok((
                r.get::<_, String>(0)?,
                (r.get(1)?, r.get::<_, i64>(2)? != 0, r.get(3)?, r.get(4)?),
            ))
        })?
        .collect::<Result<BTreeMap<_, _>, _>>()?;
    Ok(columns)
}

#[cfg(test)]
#[path = "schema_tests.rs"]
mod tests;
