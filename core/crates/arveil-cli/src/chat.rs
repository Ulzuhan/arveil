//! Thin presentation adapter for the reusable `arveil-app` services.

use std::path::Path;

use arveil_app::{
    Application, ApplicationError, ConversationHistory, DeliveryStatus, LocalAcceptance,
    ManifestSource, MessageKind, OperationResult, RemovalOutcome, StateChange, UploadRestartReason,
};

use crate::carrier::CliError;

fn application(data_dir: &Path) -> Result<Application, CliError> {
    Application::open(data_dir).map_err(|error| CliError::FileSystem(error.to_string()))
}

pub(crate) fn render(result: OperationResult) {
    for change in result.changes {
        render_change(change);
    }
}

pub(crate) fn cli_error(error: ApplicationError) -> CliError {
    match error {
        ApplicationError::Transport {
            source, partial, ..
        }
        | ApplicationError::Storage {
            source, partial, ..
        }
        | ApplicationError::Protocol {
            source, partial, ..
        }
        | ApplicationError::Domain {
            source, partial, ..
        }
        | ApplicationError::FileSystem {
            source, partial, ..
        }
        | ApplicationError::Internal {
            source, partial, ..
        } => {
            render(partial);
            source
        }
        ApplicationError::Interrupted {
            exit_code,
            message,
            partial,
        } => {
            render(partial);
            eprintln!("{message}");
            std::process::exit(exit_code.into());
        }
    }
}

fn fan_out_note(acceptance: &LocalAcceptance) -> String {
    let LocalAcceptance::PersistedToOutbox {
        peers_without_route,
        revoked_devices,
        ..
    } = acceptance;
    let mut parts = Vec::new();
    if *peers_without_route > 0 {
        parts.push(format!("{peers_without_route} peer(s) without a route yet"));
    }
    if *revoked_devices > 0 {
        parts.push(format!("{revoked_devices} revoked device(s) skipped"));
    }
    if parts.is_empty() {
        String::new()
    } else {
        format!(", {}", parts.join(", "))
    }
}

fn render_change(change: StateChange) {
    match change {
        StateChange::IdentityCreated {
            identity_id,
            created_during_enrollment,
        } => println!(
            "identity: {}{}",
            hex::encode(identity_id),
            if created_during_enrollment {
                " (created)"
            } else {
                ""
            }
        ),
        StateChange::DevicePrepared { device_id } => {
            println!("device: {}", hex::encode(device_id))
        }
        StateChange::EnrollmentAccepted { identity_id } => println!(
            "enrolled: identity {} accepted by the realm",
            hex::encode(identity_id)
        ),
        StateChange::EnrollmentEndpointListStored { sequence } => {
            println!("endpoint list: sequence {sequence} stored")
        }
        StateChange::MailboxCreated { .. } => {}
        StateChange::KeyPackagesPublished { count } => {
            println!("key packages: {count} published")
        }
        StateChange::RouteAvailable { route } => println!("route: {route}"),
        StateChange::LinkRequestCreated { device_id, request } => {
            println!(
                "device: {} (keys generated, not yet linked)",
                hex::encode(device_id)
            );
            println!("request: {request}");
        }
        StateChange::DeviceAuthorizationSigned {
            device_id,
            manifest_sequence,
        } => println!(
            "signed: credential for device {} and manifest {manifest_sequence}",
            hex::encode(device_id)
        ),
        StateChange::ManifestPublished { sequence } => {
            println!("published: manifest {sequence}")
        }
        StateChange::CredentialPublished => {
            println!("published: credential registered by the relay")
        }
        StateChange::LinkGrantCreated { grant } => println!("grant: {grant}"),
        StateChange::DeviceLinked {
            device_id,
            identity_id,
        } => println!(
            "linked: device {} now belongs to identity {}",
            hex::encode(device_id),
            hex::encode(identity_id)
        ),
        StateChange::PairingStarted {
            session_id,
            device_id,
            code,
            expires_at,
        } => {
            println!(
                "device: {} (keys generated, not yet linked)",
                hex::encode(device_id)
            );
            println!("session: {}", hex::encode(session_id));
            println!("code: {code}");
            println!(
                "waiting: show that code on the administration device (it expires at {expires_at})"
            );
        }
        StateChange::PairingVerificationReady {
            verification_code,
            confirmation_required,
            ..
        } => {
            println!("verification code: {verification_code}");
            if confirmation_required {
                println!(
                    "confirm with `arveil device pair-confirm --data-dir <dir> <bootstrap> {verification_code}` only if the administration device shows the same number"
                );
            }
        }
        StateChange::PairingGrantSent {
            verification_code, ..
        } => println!(
            "sent: the grant is on its way; the other device must show {verification_code} before it applies it"
        ),
        StateChange::PairingCancelled { session_id } => {
            println!("pairing: session {} cancelled", hex::encode(session_id))
        }
        StateChange::PairingCancellationRejected { session_id, .. } => println!(
            "pairing: session {} is already committed and cannot be cancelled",
            hex::encode(session_id)
        ),
        StateChange::PairingCompletionChanged { .. }
        | StateChange::LinkCompletionChanged { .. } => {}
        StateChange::PairingExpired { session_id } => {
            println!("pairing: session {} expired", hex::encode(session_id))
        }
        StateChange::MessageQueued { receipt, epoch } => {
            let LocalAcceptance::PersistedToOutbox { envelopes, .. } = &receipt.local_acceptance;
            match receipt.kind {
                MessageKind::Text => println!(
                    "committed: message stored locally (epoch {epoch}), {envelopes} envelope(s) queued{}",
                    fan_out_note(&receipt.local_acceptance)
                ),
                MessageKind::File => println!(
                    "committed: file descriptor stored locally, {envelopes} envelope(s) queued{}",
                    fan_out_note(&receipt.local_acceptance)
                ),
            }
        }
        StateChange::DeliveryChanged {
            mailbox_id,
            state: DeliveryStatus::Undeliverable { reason },
            ..
        } => println!(
            "undeliverable: mailbox {} refused the envelope ({reason})",
            hex::encode(&mailbox_id[..4])
        ),
        StateChange::DeliveryChanged { .. } => {}
        StateChange::EnvelopesPublished { count, pending } => {
            if pending {
                println!("published: {count} pending envelope(s)");
            } else {
                println!("published: {count} envelope(s)");
            }
        }
        StateChange::RelayUnavailable { pending, reason } => println!(
            "queued: relay unreachable ({reason}); {pending} envelope(s) pending for the next sync"
        ),
        StateChange::ConversationCreated {
            group_id,
            peers,
            epoch,
        } => println!(
            "conversation: {} created with {peers} peer(s) (epoch {epoch})",
            hex::encode(group_id)
        ),
        StateChange::ConversationJoined { group_id, epoch } => println!(
            "joined conversation {} (epoch {epoch})",
            hex::encode(group_id)
        ),
        StateChange::RosterUpdated { peers, .. } => {
            println!("roster: {peers} peer route(s) learned inside the group")
        }
        StateChange::DeviceAdded {
            identity_id,
            device_id,
            epoch,
        } => println!(
            "added: device {} of {} (epoch {epoch})",
            hex::encode(device_id),
            hex::encode(&identity_id[..4])
        ),
        StateChange::DeviceRemoved {
            device_id,
            leaf,
            epoch,
        } => println!(
            "removed: leaf {leaf} of device {} (epoch {epoch})",
            hex::encode(device_id)
        ),
        StateChange::CommitApplied {
            committer, epoch, ..
        } => println!("commit from leaf {committer} applied (epoch {epoch})"),
        StateChange::MessageReceived { body, .. } => {
            println!("message: {}", String::from_utf8_lossy(&body))
        }
        StateChange::FileAnnounced { name, size, .. } => {
            println!("file: {name} ({size} bytes) announced; downloading after this pass")
        }
        StateChange::DuplicateDelivery { delivery_id } => {
            println!("duplicate: delivery {} ignored", hex::encode(delivery_id))
        }
        StateChange::DeliveryDeferred {
            delivery_id,
            reason,
        } => println!(
            "deferred: delivery {} could not be processed yet ({reason}); retrying next sync",
            hex::encode(delivery_id)
        ),
        StateChange::SyncCompleted {
            fetched,
            new,
            acked,
        } => {
            println!("synced: {fetched} envelope(s), {new} new, {acked} acked")
        }
        StateChange::EndpointFallback { url } => {
            println!("endpoint: {url} (earlier endpoints unreachable)")
        }
        StateChange::EndpointFailed { url, reason } => {
            println!("endpoint: {url} failed ({reason}); trying the next one")
        }
        StateChange::EndpointListStored {
            sequence,
            endpoints,
        } => println!("endpoint list: sequence {sequence} with {endpoints} endpoint(s) stored"),
        StateChange::EndpointListRejected { reason } => {
            println!("endpoint list: refused ({reason})")
        }
        StateChange::ManifestUpdated {
            identity_id,
            sequence,
            active_devices,
            revoked_devices,
            source,
            already_known,
        } => match source {
            ManifestSource::Realm => println!(
                "manifest {sequence} for {} from the realm: {revoked_devices} revoked device(s)",
                hex::encode(&identity_id[..4])
            ),
            ManifestSource::Group => println!(
                "manifest {sequence} for {}: {active_devices} active, {revoked_devices} revoked{}",
                hex::encode(&identity_id[..4]),
                if already_known {
                    " (already known)"
                } else {
                    ""
                }
            ),
        },
        StateChange::ManifestRejected {
            identity_id,
            reason,
        } => println!(
            "manifest for {} refused: {reason}",
            hex::encode(&identity_id[..4])
        ),
        StateChange::DeviceRevoked {
            device_id,
            credential_hash,
        } => println!(
            "revoked: device {} (credential {})",
            hex::encode(device_id),
            hex::encode(&credential_hash[..4])
        ),
        StateChange::RealmRevocationPublished => {
            println!("published: the realm refuses that device from now on")
        }
        StateChange::ConversationManifestSent { group_id, removal } => println!(
            "conversation {}: manifest sent{}",
            hex::encode(&group_id[..4]),
            match removal {
                RemovalOutcome::Removed { epoch } => format!(", leaf removed (epoch {epoch})"),
                RemovalOutcome::LeftToCommitter => ", removal left to the committer".into(),
                RemovalOutcome::NotInGroup => String::new(),
            }
        ),
        StateChange::KeyPackagesReplenished {
            previous,
            published,
        } => println!("key packages: {previous} left at the realm, {published} more published"),
        StateChange::ArchivedConversation { group_id } => println!(
            "conversation {} (archived only, no MLS state)",
            hex::encode(group_id)
        ),
        StateChange::ArchivedEvent { kind, body } => {
            println!("  [archived {kind}] {}", String::from_utf8_lossy(&body))
        }
        StateChange::UploadRestarted {
            name,
            reason: UploadRestartReason::FileChanged,
        } => println!("upload: {name} changed since the interrupted attempt; starting again"),
        StateChange::UploadRestarted {
            reason: UploadRestartReason::RemoteMissing { reason },
            ..
        } => println!(
            "upload: the realm no longer holds the interrupted upload ({reason}); starting again"
        ),
        StateChange::UploadResumed {
            name,
            offset,
            total,
        } => println!("upload: resuming {name} at {offset} of {total} ciphertext bytes"),
        StateChange::BlobUploaded {
            blob_id,
            ciphertext_size,
            expires_at,
        } => println!(
            "blob: {} uploaded ({ciphertext_size} bytes of ciphertext, relay keeps it until {expires_at})",
            hex::encode(blob_id)
        ),
        StateChange::FileDownloadResumed { name, offset } => {
            println!("file: resuming {name} at {offset} bytes")
        }
        StateChange::FileSaved { name, path } => {
            println!("file: {name} saved to {}", path.display())
        }
        StateChange::FileUnavailable { name, reason } => {
            println!("file unavailable: {name} ({reason})")
        }
        StateChange::MlsMessageProcessed { description, .. } => println!("{description}"),
    }
}

pub fn start(data_dir: &Path, bootstrap: &str, peer_routes: &[&str]) -> Result<(), CliError> {
    render(
        application(data_dir)?
            .create_conversation(bootstrap, peer_routes)
            .map_err(cli_error)?,
    );
    Ok(())
}

pub fn add(
    data_dir: &Path,
    bootstrap: &str,
    peer_route: &str,
    group: Option<&str>,
) -> Result<(), CliError> {
    render(
        application(data_dir)?
            .add_device(bootstrap, peer_route, group)
            .map_err(cli_error)?,
    );
    Ok(())
}

pub fn remove(
    data_dir: &Path,
    bootstrap: &str,
    device_id: &str,
    group: Option<&str>,
) -> Result<(), CliError> {
    render(
        application(data_dir)?
            .remove_device(bootstrap, device_id, group)
            .map_err(cli_error)?,
    );
    Ok(())
}

pub fn send(
    data_dir: &Path,
    bootstrap: &str,
    text: &str,
    group: Option<&str>,
) -> Result<(), CliError> {
    render(
        application(data_dir)?
            .send_message(bootstrap, text, group)
            .map_err(cli_error)?,
    );
    Ok(())
}

pub fn send_file(
    data_dir: &Path,
    bootstrap: &str,
    path: &Path,
    group: Option<&str>,
) -> Result<(), CliError> {
    render(
        application(data_dir)?
            .send_file(bootstrap, path, group)
            .map_err(cli_error)?,
    );
    Ok(())
}

pub fn sync(data_dir: &Path, bootstrap: &str) -> Result<(), CliError> {
    render(application(data_dir)?.sync(bootstrap).map_err(cli_error)?);
    Ok(())
}

pub fn revoke(data_dir: &Path, bootstrap: &str, device_id: &str) -> Result<(), CliError> {
    render(
        application(data_dir)?
            .revoke_device(bootstrap, device_id)
            .map_err(cli_error)?,
    );
    Ok(())
}

pub fn list(data_dir: &Path) -> Result<(), CliError> {
    let conversations = application(data_dir)?.conversations().map_err(cli_error)?;
    if conversations.is_empty() {
        println!("conversations: none yet");
        return Ok(());
    }
    for conversation in conversations {
        let last = conversation
            .last_event
            .map(|event| format!("{}: {}", event.kind, String::from_utf8_lossy(&event.body)))
            .unwrap_or_else(|| "no messages yet".into());
        println!(
            "{} ({}, {} peer device(s), {} event(s)) {last}",
            hex::encode(&conversation.group_id),
            if conversation.creator {
                "creator"
            } else {
                "member"
            },
            conversation.peer_devices,
            conversation.event_count,
        );
    }
    Ok(())
}

pub fn history(data_dir: &Path) -> Result<(), CliError> {
    for conversation in application(data_dir)?.history().map_err(cli_error)? {
        render_history(conversation);
    }
    Ok(())
}

fn render_history(conversation: ConversationHistory) {
    let Some(creator) = conversation.creator else {
        println!(
            "conversation {} (archived only, no MLS state)",
            hex::encode(&conversation.group_id)
        );
        for event in conversation.events {
            let kind = event.kind.strip_prefix("archived-").unwrap_or(&event.kind);
            println!(
                "  [archived {kind}] {}",
                String::from_utf8_lossy(&event.body)
            );
        }
        return;
    };

    println!(
        "conversation {} ({}), peers: {}",
        hex::encode(&conversation.group_id),
        if creator { "creator" } else { "member" },
        conversation
            .peers
            .iter()
            .map(|peer| format!(
                "{}/{}{}{}{}",
                peer.label,
                hex::encode(&peer.device_id[..4]),
                if peer.own { " (own)" } else { "" },
                if peer.verified { " (verified)" } else { "" },
                if peer.routable { "" } else { " (no route)" },
            ))
            .collect::<Vec<_>>()
            .join(", ")
    );
    for event in conversation.events {
        if let Some(kind) = event.kind.strip_prefix("archived-") {
            println!(
                "  [archived {kind}] {}",
                String::from_utf8_lossy(&event.body)
            );
            continue;
        }
        println!(
            "  [{:>8}] {}",
            event.kind,
            String::from_utf8_lossy(&event.body)
        );
        for state in event.delivery_states {
            println!(
                "             -> mailbox {}: {}",
                hex::encode(&state.mailbox_id[..4]),
                state.state
            );
        }
    }
}
