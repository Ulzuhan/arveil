//! Portable history, without identity secrets, MLS state or relay capabilities.
use super::*;
pub use arveil_core::recovery::MAX_ARCHIVE_BYTES;
use arveil_core::recovery::{self, ARCHIVE_VERSION, ArchiveRecord, HistoryArchive, Secret};

#[derive(Clone, PartialEq, Eq)]
pub struct ArchiveExport {
    pub encrypted: Vec<u8>,
    pub secret: String,
    pub records: u32,
    pub files: u32,
    pub unavailable_files: u32,
}
impl std::fmt::Debug for ArchiveExport {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("ArchiveExport([redacted])")
    }
}
#[derive(Clone, PartialEq, Eq)]
pub struct ArchiveImport {
    pub encrypted: Vec<u8>,
    pub secret: String,
}
impl std::fmt::Debug for ArchiveImport {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("ArchiveImport([redacted])")
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ArchiveReceipt {
    pub imported: u32,
    pub duplicates: u32,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ArchiveEntry {
    pub group_id: Vec<u8>,
    pub event_id: Vec<u8>,
    pub kind: String,
    pub text: String,
    pub created_at: i64,
    pub file_name: Option<String>,
    pub file_size: Option<u64>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ArchivePage {
    pub entries: Vec<ArchiveEntry>,
    pub next: Option<i64>,
}

fn invalid() -> CliError {
    CliError::Domain("invalid archive, wrong identity or archive limit exceeded".into())
}

fn safe_name(name: &str) -> String {
    let name: String = name
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or("file")
        .trim_start_matches('.')
        .chars()
        .filter(|c| !c.is_control())
        .take(120)
        .collect();
    if name.is_empty() { "file".into() } else { name }
}

fn normalize(r: &mut ArchiveRecord) -> Result<(), CliError> {
    if r.group_id.is_empty()
        || r.group_id.len() > 128
        || r.event_id.len() != 16
        || r.body.len() > 1024 * 1024
        || r.file.len() > MAX_ATTACHMENT_BYTES
    {
        return Err(invalid());
    }
    match r.kind.as_str() {
        "sent" | "received" => {
            std::str::from_utf8(&r.body).map_err(|_| invalid())?;
            if r.file_name.is_some() || r.file_present || !r.file.is_empty() {
                return Err(invalid());
            }
        }
        "received-file" | "sent-file" | "file-pending" | "file-outgoing" => {
            // Old CLI archives may carry paths or descriptors in the body.
            // Neither is restored as a path or a live attachment capability.
            let name = r
                .file_name
                .as_deref()
                .map(safe_name)
                .unwrap_or_else(|| "file".into());
            r.body = name.as_bytes().to_vec();
            r.file_name = Some(name);
            r.kind = if matches!(r.kind.as_str(), "sent-file" | "file-outgoing") {
                "sent-file"
            } else {
                "received-file"
            }
            .into();
        }
        _ => return Err(invalid()),
    }
    Ok(())
}

pub(super) fn export(config: &ProfileConfig) -> Result<ArchiveExport, CliError> {
    let s = local(config)?;
    let identity_id = s.identity_id.ok_or_else(invalid)?;
    let snapshot = s.client.archive_snapshot().map_err(|_| invalid())?;
    let mut records = Vec::with_capacity(snapshot.len());
    let (mut files, mut unavailable_files, mut size) = (0, 0, 0usize);
    for (live, mut r) in snapshot {
        if live
            && r.kind.contains("file")
            && let Some(summary) =
                attachment_ui::summary(&s.delivery, &r.event_id, &r.kind, &r.body)?
        {
            r.file_name = Some(summary.name);
            if matches!(
                summary.state,
                AttachmentState::Ready | AttachmentState::Sent
            ) {
                if size.saturating_add(summary.size as usize) > recovery::MAX_ARCHIVE_PAYLOAD_BYTES
                {
                    return Err(invalid());
                }
                r.file = attachment_ui::export(config, &r.group_id, &r.event_id)?;
                r.file_present = true;
            }
        }
        normalize(&mut r)?;
        size = size.saturating_add(r.body.len() + r.file.len() + 512);
        if size > recovery::MAX_ARCHIVE_PAYLOAD_BYTES {
            return Err(invalid());
        }
        if r.file_name.is_some() {
            if r.file.is_empty() && !r.file_present {
                unavailable_files += 1;
            } else {
                files += 1;
            }
        }
        records.push(r);
    }
    let archive = HistoryArchive {
        version: ARCHIVE_VERSION,
        identity_id,
        exported_at: onboarding::now(),
        records,
    };
    let secret = Secret::generate();
    let encrypted = recovery::archive_seal(&archive, &secret).map_err(|_| invalid())?;
    if encrypted.len() > MAX_ARCHIVE_BYTES {
        return Err(invalid());
    }
    Ok(ArchiveExport {
        encrypted,
        secret: secret.to_string_once(),
        records: archive.records.len() as u32,
        files,
        unavailable_files,
    })
}

pub(super) fn import(
    config: &ProfileConfig,
    request: ArchiveImport,
) -> Result<ArchiveReceipt, CliError> {
    if request.encrypted.len() > MAX_ARCHIVE_BYTES {
        return Err(invalid());
    }
    let secret = Secret::parse(&request.secret).map_err(|_| invalid())?;
    let mut archive = recovery::archive_open(&request.encrypted, &secret).map_err(|_| invalid())?;
    let client = open_client(config)?;
    if archive.records.len() > recovery::MAX_ARCHIVE_RECORDS
        || archive.identity_id.len() != 32
        || client
            .identity_id()
            .map_err(storage_error("identity"))?
            .as_ref()
            != Some(&archive.identity_id)
    {
        return Err(invalid());
    }
    for record in &mut archive.records {
        normalize(record)?;
    }
    let (imported, duplicates) = client
        .archive_import(&archive.records)
        .map_err(storage_error("archive"))?;
    Ok(ArchiveReceipt {
        imported: imported as u32,
        duplicates: duplicates as u32,
    })
}

pub(super) fn page(
    config: &ProfileConfig,
    before: Option<i64>,
    limit: u32,
) -> Result<ArchivePage, CliError> {
    let limit = limit.clamp(1, 100) as usize;
    let mut rows = open_client(config)?
        .archive_page(before, limit + 1)
        .map_err(storage_error("archive"))?;
    let next = if rows.len() > limit {
        Some(rows[limit - 1].0)
    } else {
        None
    };
    rows.truncate(limit);
    let entries = rows
        .into_iter()
        .map(|(_, mut r, file_size)| {
            normalize(&mut r)?;
            Ok(ArchiveEntry {
                group_id: r.group_id,
                event_id: r.event_id,
                kind: r.kind,
                text: String::from_utf8(r.body).map_err(|_| invalid())?,
                created_at: r.created_at,
                file_name: r.file_name,
                file_size,
            })
        })
        .collect::<Result<_, CliError>>()?;
    Ok(ArchivePage { entries, next })
}

pub(super) fn file(
    config: &ProfileConfig,
    group: &[u8],
    event: &[u8],
) -> Result<Vec<u8>, CliError> {
    open_client(config)?
        .archive_file(group, event)
        .map_err(storage_error("archive"))?
        .ok_or_else(invalid)
}

#[cfg(test)]
#[path = "archive_tests.rs"]
mod tests;
