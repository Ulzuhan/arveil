//! Identity kit and history archive commands (PROTOCOL §9, ADR-006).
//!
//! Three separate mechanisms, three separate secrets:
//! `kit export` / `kit restore` recover **who you are**, `device link`
//! enrols **a device**, `archive export` / `archive import` move **history**.
//! Neither file carries device private keys or MLS state, so importing a
//! backup can never revive an old epoch or ignore a revocation.

use std::path::Path;

use arveil_core::recovery::{self, ARCHIVE_VERSION, ArchiveRecord, HistoryArchive, Secret};

use crate::carrier::{CliError, err};
use crate::chat::cli_error;
use arveil_app::RecoveryRequest;

use crate::commands::{now, open_client, open_session};

fn read(path: &Path) -> Result<Vec<u8>, CliError> {
    std::fs::read(path).map_err(err("read file"))
}

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

/// `arveil archive export --data-dir D <path>`
pub fn archive_export(data_dir: &Path, path: &Path) -> Result<(), CliError> {
    let c = open_client(data_dir)?;
    let identity_id = c
        .identity_id()
        .map_err(err("identity"))?
        .ok_or_else(|| CliError("no identity".into()))?;
    let delivery = c.delivery().map_err(err("delivery"))?;
    let downloads = data_dir.join("downloads");
    let mut records = Vec::new();
    let mut files = 0;
    for e in delivery.all_events().map_err(err("events"))? {
        // A received file is archived with its bytes when this device still
        // has them; the relay's copy expires and is not the archive.
        let (file_name, file) = match e.kind.as_str() {
            "received-file" => {
                let name = String::from_utf8_lossy(&e.body).to_string();
                match std::fs::read(downloads.join(&name)) {
                    Ok(bytes) => {
                        files += 1;
                        (Some(name), bytes)
                    }
                    Err(_) => (Some(name), Vec::new()),
                }
            }
            _ => (None, Vec::new()),
        };
        records.push(ArchiveRecord {
            group_id: e.group_id,
            event_id: e.event_id,
            kind: e.kind,
            body: e.body,
            created_at: e.created_at,
            file_name,
            file,
        });
    }
    let archive = HistoryArchive {
        version: ARCHIVE_VERSION,
        identity_id,
        exported_at: now(),
        records,
    };
    let secret = Secret::generate();
    write(
        path,
        &recovery::archive_seal(&archive, &secret).map_err(err("archive"))?,
    )?;
    println!(
        "archive: {} record(s), {files} file(s) written to {}",
        archive.records.len(),
        path.display()
    );
    println!("secret: {}", secret.to_string_once());
    println!(
        "This copy is plaintext history under its own key: storing it widens where the past can be read."
    );
    Ok(())
}

/// `arveil archive import --data-dir D <path> <secret>`
pub fn archive_import(data_dir: &Path, path: &Path, secret: &str) -> Result<(), CliError> {
    let secret = Secret::parse(secret).map_err(err("secret"))?;
    let archive = recovery::archive_open(&read(path)?, &secret).map_err(err("archive"))?;
    let c = open_client(data_dir)?;
    let (imported, duplicates) = c.archive_import(&archive.records).map_err(err("archive"))?;
    let downloads = data_dir.join("downloads");
    let mut files = 0;
    for r in &archive.records {
        if let (Some(name), false) = (&r.file_name, r.file.is_empty()) {
            std::fs::create_dir_all(&downloads).map_err(err("downloads"))?;
            std::fs::write(downloads.join(name), &r.file).map_err(err("write file"))?;
            files += 1;
        }
    }
    println!(
        "imported: {imported} archived record(s), {duplicates} already present, {files} file(s)"
    );
    println!(
        "These are historical records of identity {}. They are not new events, they were not \
         re-sent, and they carry no MLS state.",
        hex::encode(&archive.identity_id)
    );
    Ok(())
}
