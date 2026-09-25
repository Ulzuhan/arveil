//! Explicit, resumable GUI transfers. No plaintext cache or host path is stored.
use super::*;
use arveil_core::delivery::AttachmentRow;

#[cfg(test)]
#[path = "attachment_ui_tests.rs"]
mod tests;

// The relay's 25 MiB ceiling includes the 16-byte AEAD tag.
pub const MAX_ATTACHMENT_BYTES: usize = attachments::MAX_FILE_BYTES - 16;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AttachmentState {
    Pending,
    Transferring,
    Ready,
    Sent,
    Cancelled,
    Unavailable,
    Expired,
    Invalid,
    Legacy,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AttachmentSummary {
    pub name: String,
    pub size: u64,
    pub outgoing: bool,
    pub state: AttachmentState,
    pub transferred: u64,
    pub total: u64,
}

fn state(value: &str) -> AttachmentState {
    match value {
        "pending" => AttachmentState::Pending,
        "transferring" => AttachmentState::Transferring,
        "ready" => AttachmentState::Ready,
        "sent" => AttachmentState::Sent,
        "cancelled" => AttachmentState::Cancelled,
        "unavailable" => AttachmentState::Unavailable,
        "expired" => AttachmentState::Expired,
        _ => AttachmentState::Invalid,
    }
}

fn descriptor(bytes: &[u8], remote: bool) -> Result<FileDescriptor, CliError> {
    let d = FileDescriptor::decode(bytes).map_err(protocol_error("attachment"))?;
    if d.size > MAX_ATTACHMENT_BYTES as u64
        || d.file_key.len() != 32
        || d.nonce.len() != 12
        || d.ciphertext_hash.len() != 32
        || (remote && (d.blob_id.len() != 16 || d.read_capability.len() != 32))
    {
        return Err(CliError::Domain("invalid attachment descriptor".into()));
    }
    Ok(d)
}

pub(super) fn summary(
    delivery: &Delivery,
    id: &[u8],
    kind: &str,
    body: &[u8],
) -> Result<Option<AttachmentSummary>, CliError> {
    if let Some(row) = delivery.attachment(id)? {
        return Ok(Some(AttachmentSummary {
            name: row.name,
            size: row.size,
            outgoing: row.outgoing,
            state: state(&row.state),
            transferred: row.offset,
            total: row.size + 16,
        }));
    }
    if kind == "file-pending" {
        return Ok(Some(match descriptor(body, true) {
            Ok(d) => AttachmentSummary {
                name: d.safe_name(),
                size: d.size,
                outgoing: false,
                state: AttachmentState::Pending,
                transferred: 0,
                total: d.size + 16,
            },
            Err(_) => AttachmentSummary {
                name: "Adjunto no válido".into(),
                size: 0,
                outgoing: false,
                state: AttachmentState::Invalid,
                transferred: 0,
                total: 0,
            },
        }));
    }
    Ok((kind.contains("file")).then(|| AttachmentSummary {
        name: "Adjunto anterior".into(),
        size: 0,
        outgoing: kind == "sent-file",
        state: AttachmentState::Legacy,
        transferred: 0,
        total: 0,
    }))
}

fn require_private(config: &ProfileConfig) -> Result<(), CliError> {
    if !config.is_encrypted() || !config.manual_attachments {
        return Err(CliError::Domain(
            "managed attachments require an encrypted GUI profile".into(),
        ));
    }
    Ok(())
}

fn checked_event(
    delivery: &Delivery,
    group: &[u8],
    id: &[u8],
) -> Result<(String, Vec<u8>), CliError> {
    delivery
        .event(group, id)?
        .ok_or_else(|| CliError::Domain("no attachment in this conversation".into()))
}

fn ensure_row(delivery: &Delivery, group: &[u8], id: &[u8]) -> Result<AttachmentRow, CliError> {
    let (kind, body) = checked_event(delivery, group, id)?;
    if let Some(row) = delivery.attachment(id)? {
        return Ok(row);
    }
    if kind != "file-pending" {
        return Err(CliError::Domain("attachment has no managed copy".into()));
    }
    let d = descriptor(&body, true)?;
    let row = AttachmentRow {
        outgoing: false,
        name: d.safe_name(),
        size: d.size,
        state: "pending".into(),
        descriptor: body,
        offset: 0,
        committed: false,
        expires_at: None,
    };
    delivery.attachment_create(id, &row)?;
    Ok(row)
}

pub(super) fn queue(
    config: &ProfileConfig,
    group: &[u8],
    name: &str,
    bytes: &[u8],
) -> Result<Vec<u8>, CliError> {
    require_private(config)?;
    if bytes.len() > MAX_ATTACHMENT_BYTES {
        return Err(CliError::Domain("attachment exceeds size limit".into()));
    }
    let (s, engine) = session(config)?;
    let conv = select_conversation(&s, Some(&hex::encode(group)))?;
    let mls = engine
        .load_group(&conv.group_id)
        .map_err(storage_error("mls"))?;
    guard_revoked(&conv, &mls)?;
    let encrypted = attachments::encrypt(bytes).map_err(protocol_error("attachment"))?;
    let mut d = FileDescriptor {
        version: attachments::VERSION,
        blob_id: vec![],
        read_capability: vec![],
        file_key: encrypted.file_key,
        nonce: encrypted.nonce,
        ciphertext_hash: encrypted.ciphertext_hash,
        size: bytes.len() as u64,
        name: name.into(),
        mime: "application/octet-stream".into(),
    };
    d.name = d.safe_name();
    let encoded = d.encode().map_err(protocol_error("attachment"))?;
    let id = random_delivery_id()?;
    s.client.unit_of_work(|| {
        s.delivery
            .record_event_by(group, &id, "file-outgoing", &[], Some(&own_sender(&s)))?;
        s.delivery.attachment_create(
            &id,
            &AttachmentRow {
                outgoing: true,
                name: d.name,
                size: d.size,
                state: "pending".into(),
                descriptor: encoded,
                offset: 0,
                committed: false,
                expires_at: None,
            },
        )?;
        for (index, chunk) in encrypted.ciphertext.chunks(BLOB_CHUNK).enumerate() {
            s.delivery
                .attachment_chunk(&id, (index * BLOB_CHUNK) as u64, chunk)?;
        }
        Ok::<_, CliError>(())
    })?;
    Ok(id)
}

pub(super) fn cancel(config: &ProfileConfig, group: &[u8], id: &[u8]) -> Result<(), CliError> {
    require_private(config)?;
    let s = local(config)?;
    s.client.unit_of_work(|| {
        let row = ensure_row(&s.delivery, group, id)?;
        if row.state == "sent" || row.state == "ready" {
            return Err(CliError::Domain(
                "completed attachments cannot be cancelled".into(),
            ));
        }
        s.delivery.attachment_clear_bytes(id)?;
        s.delivery.attachment_state(id, "cancelled")?;
        Ok(())
    })
}

pub(super) fn export(config: &ProfileConfig, group: &[u8], id: &[u8]) -> Result<Vec<u8>, CliError> {
    require_private(config)?;
    let s = local(config)?;
    available_bytes(&s.delivery, group, id)
}

/// Verify an existing local copy without downloading or changing transfer policy.
/// Archive export also uses this when invoked by the CLI on a GUI profile.
pub(super) fn available_bytes(
    delivery: &Delivery,
    group: &[u8],
    id: &[u8],
) -> Result<Vec<u8>, CliError> {
    checked_event(delivery, group, id)?;
    let row = delivery
        .attachment(id)?
        .ok_or_else(|| CliError::Domain("download the attachment first".into()))?;
    if !matches!(row.state.as_str(), "ready" | "sent") {
        return Err(CliError::Domain(
            "attachment is not ready for export".into(),
        ));
    }
    let d = descriptor(&row.descriptor, true)?;
    let bytes = delivery.attachment_bytes(id, attachments::MAX_FILE_BYTES)?;
    verified_plaintext(&d, &bytes)
}

fn verified_plaintext(d: &FileDescriptor, bytes: &[u8]) -> Result<Vec<u8>, CliError> {
    if bytes.len() as u64 != d.size + 16 {
        return Err(CliError::Protocol("attachment size mismatch".into()));
    }
    let plain =
        attachments::decrypt(d, bytes).map_err(protocol_error("attachment authentication"))?;
    if plain.len() as u64 != d.size {
        return Err(CliError::Protocol("attachment size mismatch".into()));
    }
    Ok(plain)
}

fn active(delivery: &Delivery, id: &[u8]) -> Result<bool, CliError> {
    Ok(delivery
        .attachment(id)?
        .is_some_and(|r| r.state == "transferring"))
}

pub(super) async fn resume(
    config: &ProfileConfig,
    bootstrap: &str,
    group: &[u8],
    id: &[u8],
) -> Result<(), CliError> {
    require_private(config)?;
    let (s, _) = session(config)?;
    let row = ensure_row(&s.delivery, group, id)?;
    if matches!(row.state.as_str(), "sent" | "ready") {
        return Ok(());
    }
    if row.state == "invalid" || (row.outgoing && row.state == "cancelled") {
        return Err(CliError::Domain("attachment cannot be resumed".into()));
    }
    s.delivery.attachment_state(id, "transferring")?;
    let result = if row.outgoing {
        upload(config, &s, bootstrap, group, id, row).await
    } else {
        download(config, &s, bootstrap, id, row).await
    };
    if result.is_err() && active(&s.delivery, id)? {
        s.delivery.attachment_state(id, "pending")?;
    }
    result
}

async fn upload(
    config: &ProfileConfig,
    s: &Session,
    bootstrap: &str,
    group_id: &[u8],
    id: &[u8],
    row: AttachmentRow,
) -> Result<(), CliError> {
    let mut d = descriptor(&row.descriptor, false)?;
    let bytes = s
        .delivery
        .attachment_bytes(id, attachments::MAX_FILE_BYTES)?;
    verified_plaintext(&d, &bytes)?;
    let b = Bootstrap::parse(bootstrap)?;
    if !row.committed || row.expires_at.is_some_and(|t| t <= onboarding::now()) {
        let mut conn = connect(config, s, &b).await?;
        if !active(&s.delivery, id)? {
            return Ok(());
        }
        let resumed = if d.blob_id.is_empty() {
            None
        } else {
            match conn
                .request(Payload::BlobResume {
                    blob_id: d.blob_id.clone(),
                })
                .await
            {
                Ok(Payload::BlobOffset { offset }) if offset <= bytes.len() as u64 => {
                    Some(offset as usize)
                }
                Err(CliError::Relay {
                    code: 403 | 409 | 410,
                    ..
                }) => None,
                Err(e) => return Err(e),
                _ => return Err(CliError::Protocol("invalid upload offset".into())),
            }
        };
        if !active(&s.delivery, id)? {
            return Ok(());
        }
        let mut offset = match resumed {
            Some(offset) => offset,
            None => {
                let (blob, cap, _) = begin_upload(&mut conn, bytes.len()).await?;
                if !active(&s.delivery, id)? {
                    return Ok(());
                }
                d.blob_id = blob;
                d.read_capability = cap;
                s.delivery.attachment_descriptor(
                    id,
                    &d.encode().map_err(protocol_error("attachment"))?,
                    None,
                )?;
                0
            }
        };
        s.delivery.attachment_offset(id, offset as u64)?;
        let mut chunks = 0;
        while offset < bytes.len() {
            let end = (offset + BLOB_CHUNK).min(bytes.len());
            let reply = conn
                .request(Payload::BlobChunk {
                    blob_id: d.blob_id.clone(),
                    offset: offset as u64,
                    data: bytes[offset..end].to_vec(),
                })
                .await?;
            if !active(&s.delivery, id)? {
                return Ok(());
            }
            if !matches!(reply, Payload::Ack) {
                return Err(CliError::Protocol("unexpected upload reply".into()));
            }
            offset = end;
            s.delivery.attachment_offset(id, offset as u64)?;
            chunks += 1;
            if crash_after_chunks().is_some_and(|limit| chunks >= limit) {
                return Err(CliError::Interrupted {
                    exit_code: 4,
                    message: "test upload interruption".into(),
                });
            }
        }
        let reply = conn
            .request(Payload::BlobCommit {
                blob_id: d.blob_id.clone(),
                ciphertext_hash: d.ciphertext_hash.clone(),
                requested_expiry: blob_expiry(config),
            })
            .await?;
        if !active(&s.delivery, id)? {
            return Ok(());
        }
        let Payload::BlobCommitted { effective_expiry } = reply else {
            return Err(CliError::Protocol("unexpected blob commit reply".into()));
        };
        s.delivery.attachment_descriptor(
            id,
            &d.encode().map_err(protocol_error("attachment"))?,
            Some(effective_expiry),
        )?;
        conn.close().await;
    }
    if !active(&s.delivery, id)? {
        return Ok(());
    }
    // Reload after network yields; another command may have advanced this group.
    let (fresh, engine) = session(config)?;
    let conv = select_conversation(&fresh, Some(&hex::encode(group_id)))?;
    let mut group = engine.load_group(group_id).map_err(storage_error("mls"))?;
    guard_revoked(&conv, &group)?;
    let body = d.encode().map_err(protocol_error("attachment"))?;
    let fan = fresh
        .client
        .unit_of_work(|| {
            let msg = group
                .encrypt_application_message(
                    &encode_event("file", &body).map_err(|_| rusqlite::Error::InvalidQuery)?,
                    Default::default(),
                )
                .map_err(|_| rusqlite::Error::InvalidQuery)?;
            group
                .write_to_storage()
                .map_err(|_| rusqlite::Error::InvalidQuery)?;
            fresh.delivery.update_event(id, "sent-file", &[])?;
            fresh.delivery.attachment_state(id, "sent")?;
            let encoded = msg.to_bytes().map_err(|_| rusqlite::Error::InvalidQuery)?;
            enqueue_for_all(&fresh, &conv.peers, Some(id), &encoded)
        })
        .map_err(storage_error("attachment send unit"))?;
    record_message(
        MessageReceipt {
            group_id: group_id.to_vec(),
            event_id: id.to_vec(),
            kind: MessageKind::File,
            local_acceptance: fan.local_acceptance(),
        },
        group.current_epoch(),
    );
    fan.record_queued_deliveries(id);
    let mut conn = connect(config, &fresh, &b).await?;
    publish_pending(config, &fresh, &mut conn).await?;
    conn.close().await;
    Ok(())
}

async fn download(
    config: &ProfileConfig,
    s: &Session,
    bootstrap: &str,
    id: &[u8],
    row: AttachmentRow,
) -> Result<(), CliError> {
    let d = descriptor(&row.descriptor, true)?;
    let mut bytes = s
        .delivery
        .attachment_bytes(id, attachments::MAX_FILE_BYTES)?;
    let total = d.size + 16;
    if bytes.len() as u64 > total {
        return Err(CliError::Protocol("invalid partial attachment".into()));
    }
    let b = Bootstrap::parse(bootstrap)?;
    let mut conn = connect(config, s, &b).await?;
    if !active(&s.delivery, id)? {
        return Ok(());
    }
    let mut chunks = 0;
    while (bytes.len() as u64) < total {
        let reply = conn
            .request(Payload::BlobFetch {
                blob_id: d.blob_id.clone(),
                read_capability: d.read_capability.clone(),
                offset: bytes.len() as u64,
                length: BLOB_CHUNK as u32,
            })
            .await;
        if !active(&s.delivery, id)? {
            return Ok(());
        }
        let (reported, data) = match reply {
            Ok(Payload::BlobData { total_size, data }) => (total_size, data),
            Err(CliError::Relay {
                code: code @ (403 | 410),
                ..
            }) => {
                let state = if code == 410 {
                    "expired"
                } else {
                    "unavailable"
                };
                s.delivery.attachment_state(id, state)?;
                return Ok(());
            }
            Err(e) => return Err(e),
            _ => return Err(CliError::Protocol("unexpected download reply".into())),
        };
        if reported != total
            || data.is_empty()
            || data.len() > BLOB_CHUNK
            || data.len() as u64 > total - bytes.len() as u64
        {
            s.delivery.attachment_state(id, "invalid")?;
            return Err(CliError::Protocol("invalid attachment chunk".into()));
        }
        s.client
            .unit_of_work(|| {
                s.delivery.attachment_chunk(id, bytes.len() as u64, &data)?;
                s.delivery
                    .attachment_offset(id, (bytes.len() + data.len()) as u64)
            })
            .map_err(storage_error("attachment chunk"))?;
        bytes.extend_from_slice(&data);
        chunks += 1;
        if crash_after_download_chunks().is_some_and(|limit| chunks >= limit) {
            return Err(CliError::Interrupted {
                exit_code: 4,
                message: "test download interruption".into(),
            });
        }
    }
    if let Err(e) = verified_plaintext(&d, &bytes) {
        s.client
            .unit_of_work(|| {
                s.delivery.attachment_clear_bytes(id)?;
                s.delivery.attachment_state(id, "invalid")
            })
            .map_err(storage_error("attachment"))?;
        return Err(e);
    }
    s.delivery.attachment_state(id, "ready")?;
    conn.close().await;
    Ok(())
}
