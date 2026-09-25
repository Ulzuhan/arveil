//! Own-device inventory and durable revocation. Queries do no network work.
use crate::*;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeviceInventory {
    pub administrator: bool,
    pub manifest_sequence: u64,
    pub unknown_active: u32,
    pub unknown_revoked: u32,
    pub devices: Vec<ManagedDevice>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ManagedDevice {
    pub device_id: Vec<u8>,
    pub current: bool,
    pub revoked: bool,
    pub revocation: Option<RevocationProgress>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RevocationProgress {
    pub relay_published: bool,
    pub groups_waiting: u32,
    pub notifications_pending: u32,
    pub notifications_unconfirmed: u32,
    pub without_route: u32,
}

pub(super) fn inventory(config: &ProfileConfig) -> Result<DeviceInventory, CliError> {
    let (s, engine) = session(config)?;
    let own = s.client.own_devices().map_err(storage_error("devices"))?;
    let manifest = s
        .client
        .latest_manifest_body()
        .map_err(storage_error("manifest"))?
        .ok_or_else(|| CliError::Domain("no manifest".into()))?;
    let journals = s
        .client
        .revocations()
        .map_err(storage_error("revocations"))?;
    let mut rosters = vec![];
    for conv in s
        .client
        .conversations()
        .map_err(storage_error("conversations"))?
    {
        let group = engine
            .load_group(&conv.group_id)
            .map_err(storage_error("mls load"))?;
        rosters.push(roster_device_ids(&group));
    }
    let unknown = |hashes: &[serde_bytes::ByteBuf]| {
        hashes
            .iter()
            .filter(|h| !own.iter().any(|d| d.credential_hash == h.as_slice()))
            .count() as u32
    };
    let mut devices = vec![];
    for d in &own {
        let revocation = journals
            .iter()
            .find(|r| r.device_id == d.device_id)
            .map(|r| {
                let (pending, unconfirmed) = s
                    .delivery
                    .notification_counts(&r.notification_id, onboarding::now() as i64)
                    .map_err(storage_error("notifications"))?;
                Ok::<_, CliError>(RevocationProgress {
                    relay_published: r.relay_published,
                    groups_waiting: rosters
                        .iter()
                        .filter(|ids| ids.contains(&d.device_id))
                        .count() as u32,
                    notifications_pending: pending,
                    notifications_unconfirmed: unconfirmed,
                    without_route: s
                        .client
                        .revocation_without_route(&d.device_id)
                        .map_err(storage_error("notifications"))?,
                })
            })
            .transpose()?;
        devices.push(ManagedDevice {
            device_id: d.device_id.clone(),
            current: d.device_id == s.device.keys.device_id,
            revoked: d.revoked,
            revocation,
        });
    }
    Ok(DeviceInventory {
        administrator: s
            .client
            .root()
            .map_err(storage_error("identity"))?
            .is_some(),
        manifest_sequence: manifest.manifest_sequence,
        unknown_active: unknown(&manifest.active_credential_hashes),
        unknown_revoked: unknown(&manifest.revoked_credential_hashes),
        devices,
    })
}

/// No awaits: read the latest MLS state and commit each group's work atomically.
/// The journal suppresses duplicate application messages after a retry/restart.
pub(super) fn prepare(config: &ProfileConfig) -> Result<(), CliError> {
    let (s, engine) = session(config)?;
    for r in s
        .client
        .revocations()
        .map_err(storage_error("revocations"))?
    {
        let manifest = s
            .client
            .latest_manifest()
            .map_err(storage_error("manifest"))?
            .ok_or_else(|| CliError::Domain("no manifest".into()))?;
        for conv in s
            .client
            .conversations()
            .map_err(storage_error("conversations"))?
        {
            let queued = s
                .client
                .revocation_group_queued(&r.device_id, &conv.group_id)
                .map_err(storage_error("revocation journal"))?;
            let mut group = engine
                .load_group(&conv.group_id)
                .map_err(storage_error("mls load"))?;
            let in_group = roster_device_ids(&group).contains(&r.device_id);
            let remove = in_group && i_am_committer(&s, &group);
            if queued && !remove {
                continue;
            }
            let event = if queued {
                None
            } else {
                Some(manifest_message(&mut group, &manifest)?)
            };
            let removal = if remove {
                let index = group
                    .roster()
                    .members()
                    .into_iter()
                    .find(|m| {
                        m.signing_identity
                            .credential
                            .as_basic()
                            .is_some_and(|c| c.identifier == r.device_id)
                    })
                    .ok_or_else(|| CliError::Domain("revoked device missing from roster".into()))?
                    .index;
                let commit = group
                    .commit_builder()
                    .remove_member(index)
                    .map_err(domain_error("mls remove"))?
                    .build()
                    .map_err(domain_error("mls commit"))?;
                group
                    .apply_pending_commit()
                    .map_err(protocol_error("mls apply"))?;
                Some(
                    commit
                        .commit_message
                        .to_bytes()
                        .map_err(protocol_error("commit"))?,
                )
            } else {
                None
            };
            s.client
                .unit_of_work(|| {
                    group
                        .write_to_storage()
                        .map_err(|_| rusqlite::Error::InvalidQuery)?;
                    let mut missing = 0;
                    for bytes in event.iter().chain(removal.iter()) {
                        missing +=
                            enqueue_for_all(&s, &conv.peers, Some(&r.notification_id), bytes)?
                                .no_route;
                    }
                    s.client
                        .revocation_group_record(&r.device_id, &conv.group_id, missing)
                })
                .map_err(storage_error("revoke unit"))?;
            record_change(StateChange::ConversationManifestSent {
                group_id: conv.group_id,
                removal: if remove {
                    RemovalOutcome::Removed {
                        epoch: group.current_epoch(),
                    }
                } else if in_group {
                    RemovalOutcome::LeftToCommitter
                } else {
                    RemovalOutcome::NotInGroup
                },
            });
        }
    }
    Ok(())
}

/// Publish the latest local manifest (which may also include a subsequent link),
/// and only acknowledge the revocations included in this specific request.
pub(super) async fn publish(s: &Session, conn: &mut Connection) -> Result<(), CliError> {
    let pending: Vec<_> = s
        .client
        .revocations()
        .map_err(storage_error("revocations"))?
        .into_iter()
        .filter(|r| !r.relay_published)
        .collect();
    if pending.is_empty() {
        return Ok(());
    }
    let manifest = s
        .client
        .latest_manifest()
        .map_err(storage_error("manifest"))?
        .ok_or_else(|| CliError::Domain("no manifest".into()))?;
    match conn.request(Payload::ManifestPut { manifest }).await? {
        Payload::Ack => {
            s.client
                .unit_of_work(|| {
                    for r in &pending {
                        s.client.revocation_published(&r.device_id)?;
                    }
                    Ok::<_, rusqlite::Error>(())
                })
                .map_err(storage_error("revocation journal"))?;
            record_change(StateChange::RealmRevocationPublished);
            Ok(())
        }
        _ => Err(CliError::Protocol(
            "unexpected manifest publication reply".into(),
        )),
    }
}

pub(super) async fn revoke(
    config: &ProfileConfig,
    bootstrap: &str,
    device_hex: &str,
) -> Result<(), CliError> {
    let b = Bootstrap::parse(bootstrap)?;
    let device_id = hex::decode(device_hex).map_err(domain_error("device id"))?;
    let (s, _) = session(config)?;
    let (_, hash) = s
        .client
        .device_revoke(&device_id)
        .map_err(domain_error("revoke"))?;
    record_change(StateChange::DeviceRevoked {
        device_id,
        credential_hash: hash,
    });
    prepare(config)?;
    let mut conn = connect(config, &s, &b).await?;
    publish(&s, &mut conn).await?;
    // Preserve the CLI's view of separately imported, read-only history.
    for group_id in s
        .client
        .archived_groups()
        .map_err(storage_error("archived"))?
    {
        record_change(StateChange::ArchivedConversation {
            group_id: group_id.clone(),
        });
        for (kind, body, _) in s
            .client
            .archived(&group_id)
            .map_err(storage_error("archived"))?
        {
            record_change(StateChange::ArchivedEvent { kind, body });
        }
    }
    let n = publish_pending(config, &s, &mut conn).await?;
    record_change(StateChange::EnvelopesPublished {
        count: n,
        pending: false,
    });
    conn.close().await;
    Ok(())
}
