//! Identity kit and history archive commands (PROTOCOL §9, ADR-006).
//!
//! Three separate mechanisms, three separate secrets:
//! `kit export` / `kit restore` recover **who you are**, `device link`
//! enrols **a device**, `archive export` / `archive import` move **history**.
//! Neither file carries device private keys or MLS state, so importing a
//! backup can never revive an old epoch or ignore a revocation.

use std::path::Path;

use crate::carrier::{CliError, err};
use crate::chat::cli_error;
use arveil_app::RecoveryRequest;

use crate::commands::open_session;

fn write(path: &Path, bytes: &[u8]) -> Result<(), CliError> {
    std::fs::write(path, bytes).map_err(err("write file"))
}

/// `arveil kit export --data-dir D <path>`
pub fn kit_export(data_dir: &Path, path: &Path) -> Result<(), CliError> {
    let kit = open_session(data_dir)?.export_kit().map_err(cli_error)?;
    write(path, &kit.encrypted)?;
    println!("kit: written to {}", path.display());
    println!("secret: {}", kit.secret);
    println!(
        "Keep that secret away from the file and from this realm: together they are the identity."
    );
    Ok(())
}

/// Restore into a clean profile, or retry the same persisted recovery after
/// an interrupted request. Uses the same atomic preparation as the GUI.
pub fn kit_restore(
    data_dir: &Path,
    bootstrap: &str,
    path: &Path,
    secret: &str,
) -> Result<(), CliError> {
    // Bound the read before handing untrusted files to the recovery service.
    use std::io::Read;
    let mut encrypted = Vec::new();
    std::fs::File::open(path)
        .map_err(err("read kit"))?
        .take(4 * 1024 * 1024 + 1)
        .read_to_end(&mut encrypted)
        .map_err(err("read kit"))?;
    let result = open_session(data_dir)?
        .restore_kit(RecoveryRequest {
            bootstrap: bootstrap.to_owned(),
            encrypted,
            secret: secret.to_owned(),
        })
        .map_err(cli_error)?;
    println!("restored: identity {}", hex::encode(result.identity_id));
    println!("recovered: the realm accepted the new device");
    if result.rollback_warning {
        println!(
            "warning: the realm held manifest {} while this kit knows {}. The realm was restored from an older snapshot, or it is hiding versions: check revocations against a surviving device or a contact.",
            result.previous_sequence, result.kit_sequence
        );
    }
    println!("route: {}", result.route);
    println!("history: none. Import an archive, or ask a member to add this device to each group.");
    Ok(())
}

/// Export through the same bounded service as the GUI.
pub fn archive_export(data_dir: &Path, path: &Path) -> Result<(), CliError> {
    let archive = open_session(data_dir)?
        .export_archive()
        .map_err(cli_error)?;
    write(path, &archive.encrypted)?;
    println!(
        "archive: {} record(s), {} file(s), {} unavailable file(s) written to {}",
        archive.records,
        archive.files,
        archive.unavailable_files,
        path.display()
    );
    println!("secret: {}", archive.secret);
    println!(
        "Store the encrypted archive and its secret separately. This copy widens where past history can be read."
    );
    Ok(())
}

/// Import into the matching identity, without creating files or live events.
pub fn archive_import(data_dir: &Path, path: &Path, secret: &str) -> Result<(), CliError> {
    use std::io::Read;
    let mut encrypted = Vec::new();
    std::fs::File::open(path)
        .map_err(err("read archive"))?
        .take(arveil_app::MAX_ARCHIVE_BYTES as u64 + 1)
        .read_to_end(&mut encrypted)
        .map_err(err("read archive"))?;
    let result = open_session(data_dir)?
        .import_archive(arveil_app::ArchiveImport {
            encrypted,
            secret: secret.to_owned(),
        })
        .map_err(cli_error)?;
    println!(
        "imported: {} archived record(s), {} already present",
        result.imported, result.duplicates
    );
    println!(
        "Historical records only: no messages re-sent, no MLS state restored. Files remain in the profile database; export them explicitly in the app."
    );
    Ok(())
}
