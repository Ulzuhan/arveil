//! Identity kit and history archive commands (PROTOCOL §9, ADR-006).
//!
//! Three separate mechanisms, three separate secrets:
//! `kit export` / `kit restore` recover **who you are**, `device link`
//! enrols **a device**, `archive export` / `archive import` move **history**.
//! Neither file carries device private keys or MLS state, so importing a
//! backup can never revive an old epoch or ignore a revocation.

use std::path::Path;

use arveil_core::channel::codec::Payload;
use arveil_core::delivery::Delivery;
use arveil_core::recovery::{
    self, ARCHIVE_VERSION, ArchiveRecord, HistoryArchive, IdentityKit, KIT_VERSION, Secret,
};

use crate::carrier::{Bootstrap, CliError, Connection, block_on, err};
use crate::commands::{finish_enrollment, now, open_client};

fn read(path: &Path) -> Result<Vec<u8>, CliError> {
    std::fs::read(path).map_err(err("read file"))
}

fn write(path: &Path, bytes: &[u8]) -> Result<(), CliError> {
    std::fs::write(path, bytes).map_err(err("write file"))
}

/// `arveil kit export --data-dir D <path>`
pub fn kit_export(data_dir: &Path, path: &Path) -> Result<(), CliError> {
    let c = open_client(data_dir)?;
    let root = c.root().map_err(err("identity"))?.ok_or_else(|| {
        CliError(
            "this device holds no root key; export the kit from the administration device".into(),
        )
    })?;
    let latest_manifest = c
        .latest_manifest()
        .map_err(err("manifest"))?
        .ok_or_else(|| CliError("no manifest to export".into()))?;
    let state = c
        .manifest_state()
        .map_err(err("manifest"))?
        .ok_or_else(|| CliError("no manifest to export".into()))?;
    let kit = IdentityKit {
        version: KIT_VERSION,
        root_seed: root.signing.to_bytes().to_vec(),
        identity_id: root.identity_id(),
        manifest_sequence: state.sequence,
        latest_manifest,
        exported_at: now(),
    };
    let secret = Secret::generate();
    write(
        path,
        &recovery::kit_seal(&kit, &secret).map_err(err("kit"))?,
    )?;
    println!(
        "kit: identity {} at manifest {} written to {}",
        hex::encode(&kit.identity_id),
        kit.manifest_sequence,
        path.display()
    );
    println!("secret: {}", secret.to_string_once());
    println!(
        "Keep that secret away from the file and from this realm: together they are the identity."
    );
    Ok(())
}

/// `arveil kit restore --data-dir NEW <bootstrap> <path> <secret>`
///
/// Total loss: a clean client, the kit and its secret. The root signs a
/// credential for the new device and a manifest that revokes everything the
/// chain listed, and the realm accepts it because the root is the authority.
pub fn kit_restore(
    data_dir: &Path,
    bootstrap: &str,
    path: &Path,
    secret: &str,
) -> Result<(), CliError> {
    let b = Bootstrap::parse(bootstrap)?;
    let secret = Secret::parse(secret).map_err(err("secret"))?;
    let kit = recovery::kit_open(&read(path)?, &secret).map_err(err("kit"))?;
    let c = open_client(data_dir)?;
    let identity_id = c
        .identity_restore(&kit.root_seed, &kit.latest_manifest)
        .map_err(err("restore"))?;
    println!(
        "restored: identity {} from a kit exported at manifest {}",
        hex::encode(&identity_id),
        kit.manifest_sequence
    );
    let (device, manifest) = c.device_new(now()).map_err(err("device"))?;
    c.realm_save(&b.realm_id, &b.signing_key, &b.noise_public, &b.url)
        .map_err(err("realm"))?;
    println!(
        "device: {} (new keys; every earlier device is revoked by manifest {})",
        hex::encode(device.keys.device_id),
        kit.manifest_sequence + 1
    );

    block_on(async {
        let mut conn = Connection::open(
            &b.url,
            &b.realm_id,
            &b.noise_public,
            &device.keys.transport_noise,
        )
        .await?;
        let previous = match conn
            .request(Payload::RecoverIdentity {
                credential: device.credential.clone(),
                manifest,
            })
            .await
        {
            Ok(Payload::Recovered {
                previous_sequence, ..
            }) => previous_sequence,
            Ok(other) => return Err(CliError(format!("unexpected reply: {other:?}"))),
            Err(e) if e.0.contains("(409)") => {
                return Err(CliError(format!(
                    "{e}. The kit is older than what the realm holds: recover the newest \
                     manifest from a surviving device or a contact before using this kit"
                )));
            }
            Err(e) => return Err(e),
        };
        println!("recovered: the realm accepted the new device");
        // A realm restored from a snapshot older than the kit is reported,
        // never silently accepted as the truth (I-08).
        if previous < kit.manifest_sequence {
            println!(
                "warning: the realm held manifest {previous} while this kit knows {}. \
                 The realm was restored from an older snapshot, or it is hiding versions: \
                 check revocations against a surviving device or a contact.",
                kit.manifest_sequence
            );
        }
        match conn.request(Payload::EndpointListGet).await? {
            Payload::EndpointList { signed } => {
                let list = c
                    .realm_accept_endpoint_list(&b.realm_id, &signed)
                    .map_err(err("endpoint list"))?;
                println!("endpoint list: sequence {} stored", list.sequence);
            }
            other => return Err(CliError(format!("unexpected reply: {other:?}"))),
        }
        c.realm_mark_enrolled(&b.realm_id).map_err(err("realm"))?;
        finish_enrollment(&c, &mut conn, &device).await?;
        println!(
            "history: none. Import an archive, or ask a member to add this device to each group."
        );
        conn.close().await;
        Ok::<_, CliError>(())
    })?
}

/// `arveil archive export --data-dir D <path>`
pub fn archive_export(data_dir: &Path, path: &Path) -> Result<(), CliError> {
    let c = open_client(data_dir)?;
    let identity_id = c
        .identity_id()
        .map_err(err("identity"))?
        .ok_or_else(|| CliError("no identity".into()))?;
    let delivery = Delivery::open(c.conn.clone()).map_err(err("delivery"))?;
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
