//! Opening, closing and querying one profile.
//!
//! Every call here is blocking underneath, and the bindings run it on a
//! worker, never on the interface thread. Errors keep the category the
//! application layer assigned: a caller never has to read a message to
//! learn what happened.

use arveil_app::{
    Application, ApplicationError, ApplicationOpenError, ConversationSummary, EnrollmentPhase,
    HistoryEvent, Operation, ProfileConfig, ProgressEvent, ProgressKind, Waited,
};
use flutter_rust_bridge::frb;

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering as AtomicOrdering};

use crate::frb_generated::StreamSink;

/// A session over one profile. Opaque to Dart: the database, the MLS engine
/// and the keys stay on this side.
pub struct Profile {
    inner: Application,
    /// Each watcher owns a generation. Replacing/stopping it invalidates the
    /// previous loop even when a screen immediately starts another watcher.
    watching: Arc<AtomicU64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SetupStage {
    New,
    IdentityReady,
    Redeeming,
    Redeemed,
    Publishing,
    Ready,
    LinkedDevice,
    Recovering,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SetupView {
    pub stage: SetupStage,
    pub identity_id: Option<String>,
    pub bootstrap: Option<String>,
    pub administrator: bool,
    pub recovery_warning: bool,
    pub pairing: Option<PairingView>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairingView {
    pub session_id: Vec<u8>,
    pub code: String,
    pub expires_at: u64,
    pub verification_code: Option<String>,
    pub committing: bool,
    pub expired: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KeyPackageLevelView {
    Unknown,
    Empty,
    Low,
    Ready,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct KeyPackageSupplyView {
    pub available: Option<u32>,
    pub checked_at: Option<u64>,
    pub level: KeyPackageLevelView,
    pub publication_pending: bool,
    pub target: u32,
}

pub struct KitView {
    pub encrypted: Vec<u8>,
    pub secret: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RoutePreviewView {
    pub identity_id: String,
    pub device_id: String,
    pub safety_number: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContactDeviceView {
    pub device_id: String,
    pub revoked: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContactView {
    pub identity_id: String,
    pub name: Option<String>,
    pub label: String,
    pub verified: bool,
    pub safety_number: String,
    pub devices: Vec<ContactDeviceView>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SavedRecipientView {
    pub identity_id: String,
    pub device_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PeerView {
    pub identity_id: String,
    pub device_id: String,
    pub label: String,
    pub own: bool,
    pub verified: bool,
    pub revoked: bool,
}

/// A committed mutation may carry a later failure. Retry publication with sync,
/// never by creating a second message or conversation.
pub struct ChatMutationView {
    pub group_id: String,
    pub event_id: Option<String>,
    pub warning: Option<CommandError>,
}

pub struct SyncView {
    pub processed_envelopes: u32,
}

/// Why a profile could not be opened.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProfileError {
    /// The key is not 32 bytes as 64 hexadecimal characters.
    BadKey,
    /// The system would not produce randomness. Nothing weaker is used in
    /// its place.
    NoRandomness,
    /// This process already has a session over that profile. Sharing is a
    /// decision of the caller, not an accident of opening twice.
    AlreadyOpen { path: String },
    /// The profile is being closed; opening it again has to wait.
    Closing { path: String },
    /// Another process holds the profile.
    InUse { path: String },
    /// The profile exists but did not open: a wrong key looks like this.
    Unusable { path: String, reason: String },
    /// The directory itself could not be prepared.
    Io { path: String, reason: String },
}

/// Why a command failed, in the category the application layer assigned.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CommandError {
    /// The profile already has as much work of this kind as it will hold.
    /// Nothing was started, so a caller may retry once something finishes.
    Busy {
        operation: String,
        active: u32,
    },
    /// A command failed in a way nobody described and ended this session.
    /// The profile itself is intact: close it and open it again.
    Panicked {
        operation: String,
    },
    Transport {
        operation: String,
        reason: String,
    },
    Storage {
        operation: String,
        reason: String,
    },
    Protocol {
        operation: String,
        reason: String,
    },
    Domain {
        operation: String,
        reason: String,
    },
    FileSystem {
        operation: String,
        reason: String,
    },
    Internal {
        operation: String,
        reason: String,
    },
    Interrupted {
        reason: String,
    },
}

/// Progress while an operation runs. A screen may show it; it does not
/// replace the answer the operation returns, and a `gap` means events were
/// missed and the screen should read the state again.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProgressView {
    pub sequence: u64,
    pub operation: String,
    pub kind: ProgressKindView,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProgressKindView {
    MessageQueued {
        group_id: String,
        event_id: String,
    },
    MessageReceived {
        group_id: String,
        event_id: String,
    },
    EnvelopesPublished {
        count: u32,
        pending: bool,
    },
    DeliveryChanged {
        delivery_id: String,
        state: String,
    },
    FileAnnounced {
        group_id: String,
        event_id: String,
        name: String,
        size: u64,
    },
    FileTransfer {
        name: String,
        offset: u64,
        total: Option<u64>,
    },
    FileSaved {
        name: String,
    },
    Synced {
        fetched: u32,
        new: u32,
        acked: u32,
    },
    PairingChanged {
        session_id: String,
        phase: String,
    },
    RelayUnavailable {
        pending: u32,
    },
    Onboarding {
        step: String,
    },
    Gap {
        dropped: u32,
    },
}

/// One event of a conversation, as a screen shows it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AttachmentStateView {
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

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AttachmentView {
    pub name: String,
    pub size: u64,
    pub outgoing: bool,
    pub state: AttachmentStateView,
    pub transferred: u64,
    pub total: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HistoryEventView {
    /// Position in the conversation. Pass the oldest one back as `before`
    /// to read the page before this one.
    pub cursor: i64,
    pub event_id: String,
    pub kind: String,
    pub body: Vec<u8>,
    pub attachment: Option<AttachmentView>,
    /// Delivery state per mailbox, for events this device sent.
    pub delivery: Vec<String>,
}

/// One page, oldest first within the page.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HistoryPageView {
    pub events: Vec<HistoryEventView>,
    /// Cursor for the page before this one; absent at the beginning of the
    /// conversation.
    pub next: Option<i64>,
}

/// One row of the conversation list.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConversationView {
    pub group_id: String,
    pub creator: bool,
    pub peer_devices: u32,
    pub peers: Vec<PeerView>,
    pub event_count: u32,
}

/// Whether a profile already lives in this directory. The difference
/// between "no key yet" and "the key is gone" depends on it, and only the
/// second one is a problem.
pub fn has_profile(dir: String) -> bool {
    std::path::Path::new(&dir).join("client.db").exists()
}

/// A fresh 32-byte key as 64 hexadecimal characters, from the operating
/// system's generator. Generated here rather than in Dart so the entropy
/// comes from the same source the rest of the client already trusts, and so
/// a failure is a failure rather than a weaker key.
pub fn generate_profile_key() -> Result<String, ProfileError> {
    let mut key = [0u8; 32];
    getrandom::fill(&mut key).map_err(|_| ProfileError::NoRandomness)?;
    Ok(hex(&key))
}

/// Open a profile encrypted at rest. The key comes from the platform store,
/// never from this crate and never from the environment.
pub fn open_profile(dir: String, key: String) -> Result<Profile, ProfileError> {
    let config = ProfileConfig::encrypted(dir, key)
        .map_err(profile_error)?
        .with_manual_attachments();
    Ok(Profile {
        inner: Application::open(config).map_err(profile_error)?,
        watching: Arc::new(AtomicU64::new(0)),
    })
}

/// Open a profile with nothing encrypting it. Only a development build has
/// any business calling this, and it has to say so.
pub fn open_unencrypted_profile(dir: String) -> Result<Profile, ProfileError> {
    Ok(Profile {
        inner: Application::open(ProfileConfig::unencrypted(dir).with_manual_attachments())
            .map_err(profile_error)?,
        watching: Arc::new(AtomicU64::new(0)),
    })
}

impl Profile {
    /// Stop admitting work, wait for what is running and release the
    /// profile. Idempotent, and every later call fails instead of quietly
    /// opening it again.
    pub fn close(&self) {
        self.inner.close();
    }

    /// Create this profile's identity. The first step of enrollment, and
    /// the one that makes a profile more than a directory.
    pub fn create_identity(&self) -> Result<(), CommandError> {
        self.inner.create_identity().map_err(command_error)?;
        Ok(())
    }

    /// Read durable setup state after opening, completing or retrying an
    /// enrollment. Progress events are hints; this is the source of truth.
    pub fn setup(&self) -> Result<SetupView, CommandError> {
        let status = self.inner.onboarding_status().map_err(command_error)?;
        let stage = match status.phase {
            _ if status.recovering => SetupStage::Recovering,
            _ if status.ready => SetupStage::Ready,
            Some(EnrollmentPhase::Redeeming) => SetupStage::Redeeming,
            Some(EnrollmentPhase::Redeemed) => SetupStage::Redeemed,
            Some(EnrollmentPhase::Endpoints) => SetupStage::Publishing,
            Some(EnrollmentPhase::Complete) => SetupStage::Ready,
            None if status.linked_device => SetupStage::LinkedDevice,
            None if status.identity_id.is_some() => SetupStage::IdentityReady,
            None => SetupStage::New,
        };
        Ok(SetupView {
            stage,
            identity_id: status.identity_id.map(|id| hex(&id)),
            bootstrap: status.bootstrap,
            administrator: status.administrator,
            recovery_warning: status.recovery_warning,
            pairing: status.pairing.map(|p| PairingView {
                session_id: p.session.session_id,
                code: p.session.code,
                expires_at: p.session.expires_at,
                verification_code: p.verification_code,
                committing: p.committing,
                expired: p.expired,
            }),
        })
    }

    /// Creates an identity if needed, then resumes the existing enrollment.
    /// The invitation is hashed by Rust and is never persisted by Flutter.
    pub fn enroll(&self, bootstrap: String, invite: String) -> Result<(), CommandError> {
        self.inner
            .enroll(bootstrap.trim(), invite.trim())
            .map_err(command_error)?;
        Ok(())
    }

    pub fn begin_pairing(&self, bootstrap: String) -> Result<(), CommandError> {
        self.inner
            .begin_pairing(bootstrap.trim())
            .map_err(command_error)?;
        Ok(())
    }

    pub fn await_pairing(
        &self,
        bootstrap: String,
        session: PairingView,
    ) -> Result<(), CommandError> {
        self.inner
            .await_pairing(
                bootstrap.trim(),
                arveil_app::PairingSession {
                    session_id: session.session_id,
                    code: session.code,
                    expires_at: session.expires_at,
                },
            )
            .map_err(command_error)?;
        Ok(())
    }

    pub fn approve_pairing(&self, bootstrap: String, code: String) -> Result<String, CommandError> {
        Ok(self
            .inner
            .approve_pairing(bootstrap.trim(), code.trim())
            .map_err(command_error)?
            .value
            .verification_code)
    }

    pub fn confirm_pairing(
        &self,
        bootstrap: String,
        session_id: Vec<u8>,
        verification_code: String,
    ) -> Result<(), CommandError> {
        self.inner
            .confirm_pairing(bootstrap.trim(), &session_id, &verification_code)
            .map_err(command_error)?;
        Ok(())
    }

    /// False means finalization already committed: resume it, never claim it was undone.
    pub fn cancel_pairing(&self, session_id: Vec<u8>) -> Result<bool, CommandError> {
        Ok(self
            .inner
            .cancel_pairing(&session_id)
            .map_err(command_error)?
            .value
            == arveil_app::PairingCancellation::Cancelled)
    }

    /// Local snapshot only: its timestamp identifies an earlier relay report.
    pub fn key_package_supply(&self) -> Result<KeyPackageSupplyView, CommandError> {
        self.inner
            .key_package_supply()
            .map(key_package_view)
            .map_err(command_error)
    }

    pub fn check_key_packages(&self) -> Result<KeyPackageSupplyView, CommandError> {
        self.inner
            .check_key_packages()
            .map(key_package_view)
            .map_err(command_error)
    }

    pub fn replenish_key_packages(&self) -> Result<KeyPackageSupplyView, CommandError> {
        self.inner
            .replenish_key_packages()
            .map(key_package_view)
            .map_err(command_error)
    }

    pub fn export_kit(&self) -> Result<KitView, CommandError> {
        let kit = self.inner.export_kit().map_err(command_error)?;
        Ok(KitView {
            encrypted: kit.encrypted,
            secret: kit.secret,
        })
    }

    pub fn restore_kit(
        &self,
        bootstrap: String,
        encrypted: Vec<u8>,
        secret: String,
    ) -> Result<(), CommandError> {
        self.inner
            .restore_kit(arveil_app::RecoveryRequest {
                bootstrap,
                encrypted,
                secret,
            })
            .map_err(command_error)?;
        Ok(())
    }

    pub fn resume_recovery(&self) -> Result<(), CommandError> {
        self.inner.resume_recovery().map_err(command_error)?;
        Ok(())
    }

    pub fn contacts(&self) -> Result<Vec<ContactView>, CommandError> {
        Ok(self
            .inner
            .contacts()
            .map_err(command_error)?
            .into_iter()
            .map(contact_view)
            .collect())
    }

    pub fn save_contact(
        &self,
        route: String,
        name: String,
        safety_number: Option<String>,
    ) -> Result<ContactView, CommandError> {
        self.inner
            .save_contact(route, name, safety_number)
            .map(contact_view)
            .map_err(command_error)
    }

    pub fn rename_contact(
        &self,
        identity_id: String,
        name: String,
    ) -> Result<ContactView, CommandError> {
        self.inner
            .rename_contact(decode_hex(&identity_id)?, name)
            .map(contact_view)
            .map_err(command_error)
    }

    pub fn verify_contact(
        &self,
        identity_id: String,
        safety_number: String,
    ) -> Result<ContactView, CommandError> {
        self.inner
            .verify_contact(decode_hex(&identity_id)?, safety_number)
            .map(contact_view)
            .map_err(command_error)
    }

    pub fn create_contact_conversation(
        &self,
        bootstrap: String,
        recipients: Vec<SavedRecipientView>,
    ) -> Result<ChatMutationView, CommandError> {
        let recipients = recipients
            .into_iter()
            .map(|r| {
                Ok(arveil_app::SavedRecipient {
                    identity_id: decode_hex(&r.identity_id)?,
                    device_id: decode_hex(&r.device_id)?,
                })
            })
            .collect::<Result<_, CommandError>>()?;
        chat_mutation(
            self.inner
                .create_contact_conversation(&bootstrap, recipients),
        )
    }

    pub fn own_route(&self) -> Result<String, CommandError> {
        self.inner.own_route().map_err(command_error)
    }

    pub fn preview_routes(
        &self,
        routes: Vec<String>,
    ) -> Result<Vec<RoutePreviewView>, CommandError> {
        Ok(self
            .inner
            .preview_routes(routes)
            .map_err(command_error)?
            .into_iter()
            .map(|r| RoutePreviewView {
                identity_id: hex(&r.identity_id),
                device_id: hex(&r.device_id),
                safety_number: r.safety_number,
            })
            .collect())
    }

    pub fn create_conversation(
        &self,
        bootstrap: String,
        routes: Vec<String>,
        safety_numbers: Vec<String>,
    ) -> Result<ChatMutationView, CommandError> {
        if routes.len() != safety_numbers.len() {
            return Err(CommandError::Domain {
                operation: "create-conversation".into(),
                reason: "compare every route first".into(),
            });
        }
        chat_mutation(
            self.inner.create_verified_conversation(
                &bootstrap,
                routes
                    .into_iter()
                    .zip(safety_numbers)
                    .map(|(route, safety_number)| arveil_app::ConfirmedRoute {
                        route,
                        safety_number,
                    })
                    .collect(),
            ),
        )
    }

    pub fn queue_attachment(
        &self,
        group_id: String,
        name: String,
        bytes: Vec<u8>,
    ) -> Result<String, CommandError> {
        self.inner
            .queue_attachment(decode_hex(&group_id)?, name, bytes)
            .map(|id| hex(&id))
            .map_err(command_error)
    }

    pub fn resume_attachment(
        &self,
        bootstrap: String,
        group_id: String,
        event_id: String,
    ) -> Result<(), CommandError> {
        self.inner
            .resume_attachment(bootstrap, decode_hex(&group_id)?, decode_hex(&event_id)?)
            .map(|_| ())
            .map_err(command_error)
    }

    pub fn cancel_attachment(
        &self,
        group_id: String,
        event_id: String,
    ) -> Result<(), CommandError> {
        self.inner
            .cancel_attachment(decode_hex(&group_id)?, decode_hex(&event_id)?)
            .map(|_| ())
            .map_err(command_error)
    }

    pub fn export_attachment(
        &self,
        group_id: String,
        event_id: String,
    ) -> Result<Vec<u8>, CommandError> {
        self.inner
            .export_attachment(decode_hex(&group_id)?, decode_hex(&event_id)?)
            .map_err(command_error)
    }

    pub fn queue_message(
        &self,
        group_id: String,
        text: String,
    ) -> Result<ChatMutationView, CommandError> {
        chat_mutation(self.inner.queue_message(&text, &group_id))
    }

    pub fn sync(&self, bootstrap: String) -> Result<SyncView, CommandError> {
        let result = self.inner.sync(&bootstrap).map_err(command_error)?;
        Ok(SyncView {
            processed_envelopes: result
                .changes
                .iter()
                .filter_map(|change| match change {
                    arveil_app::StateChange::SyncCompleted { new, .. } => Some(*new as u32),
                    _ => None,
                })
                .sum(),
        })
    }

    /// Reserve a watcher synchronously before its asynchronous worker starts.
    /// Stopping during dispatch therefore cannot accidentally revive a stream.
    #[frb(sync)]
    pub fn start_watching(&self) -> u64 {
        self.watching
            .fetch_add(1, AtomicOrdering::AcqRel)
            .wrapping_add(1)
    }

    /// Watch progress while operations run. The stream ends when the
    /// profile closes or when `stop_watching` is called; a listener should
    /// stop before cancelling, since the stream is closed from this side.
    pub fn watch(&self, generation: u64, sink: StreamSink<ProgressView>) {
        let subscription = self.inner.watch();
        while self.watching.load(AtomicOrdering::Acquire) == generation {
            match subscription.wait(std::time::Duration::from_millis(100)) {
                Waited::Event(event) => {
                    if sink.add(progress_view(event)).is_err() {
                        break;
                    }
                }
                // Idle only means nothing happened; it is the chance to
                // notice that nobody is watching any more.
                Waited::Idle => continue,
                Waited::Closed => break,
            }
        }
    }

    /// Stop the stream this profile is feeding, without closing anything
    /// else. Dropping the subscription on the Rust side is what actually
    /// unsubscribes.
    #[frb(sync)]
    pub fn stop_watching(&self, generation: u64) {
        // An older screen finishing its exit animation cannot stop its successor.
        let _ = self.watching.compare_exchange(
            generation,
            generation.wrapping_add(1),
            AtomicOrdering::AcqRel,
            AtomicOrdering::Acquire,
        );
    }

    /// One page of a conversation, newest page first: pass the previous
    /// page's `next` as `before` to walk backwards. The application caps
    /// the size whatever is asked for.
    pub fn history_page(
        &self,
        group_id: String,
        before: Option<i64>,
        limit: u32,
    ) -> Result<HistoryPageView, CommandError> {
        let group = decode_hex(&group_id)?;
        let page = self
            .inner
            .history_page(&group, before, limit as usize)
            .map_err(command_error)?;
        Ok(HistoryPageView {
            events: page.events.into_iter().map(event_view).collect(),
            next: page.next,
        })
    }

    /// The conversation list, as a query that answers from local state.
    pub fn conversations(&self) -> Result<Vec<ConversationView>, CommandError> {
        Ok(self
            .inner
            .conversations()
            .map_err(command_error)?
            .into_iter()
            .map(view)
            .collect())
    }
}

fn chat_mutation(
    result: Result<arveil_app::OperationResult, ApplicationError>,
) -> Result<ChatMutationView, CommandError> {
    let (operation, failure) = match result {
        Ok(value) => (value, None),
        Err(error) => (error.partial_result().clone(), Some(error)),
    };
    let accepted = operation
        .messages
        .first()
        .map(|m| (hex(&m.group_id), Some(hex(&m.event_id))))
        .or_else(|| {
            operation.changes.iter().find_map(|change| match change {
                arveil_app::StateChange::ConversationCreated { group_id, .. } => {
                    Some((hex(group_id), None))
                }
                _ => None,
            })
        });
    if let Some((group_id, event_id)) = accepted {
        return Ok(ChatMutationView {
            group_id,
            event_id,
            warning: failure.map(command_error),
        });
    }
    Err(failure
        .map(command_error)
        .unwrap_or_else(|| CommandError::Internal {
            operation: "chat-mutation".into(),
            reason: "no durable result returned".into(),
        }))
}

fn progress_view(event: ProgressEvent) -> ProgressView {
    let kind = match event.kind {
        ProgressKind::MessageQueued { group_id, event_id } => ProgressKindView::MessageQueued {
            group_id: hex(&group_id),
            event_id: hex(&event_id),
        },
        ProgressKind::MessageReceived { group_id, event_id } => ProgressKindView::MessageReceived {
            group_id: hex(&group_id),
            event_id: hex(&event_id),
        },
        ProgressKind::EnvelopesPublished { count, pending } => {
            ProgressKindView::EnvelopesPublished {
                count: count as u32,
                pending,
            }
        }
        ProgressKind::DeliveryChanged { delivery_id, state } => ProgressKindView::DeliveryChanged {
            delivery_id: hex(&delivery_id),
            state,
        },
        ProgressKind::FileAnnounced {
            group_id,
            event_id,
            name,
            size,
        } => ProgressKindView::FileAnnounced {
            group_id: hex(&group_id),
            event_id: hex(&event_id),
            name,
            size,
        },
        ProgressKind::FileTransfer {
            name,
            offset,
            total,
        } => ProgressKindView::FileTransfer {
            name,
            offset: offset as u64,
            total: total.map(|total| total as u64),
        },
        ProgressKind::FileSaved { name } => ProgressKindView::FileSaved { name },
        ProgressKind::Synced {
            fetched,
            new,
            acked,
        } => ProgressKindView::Synced {
            fetched: fetched as u32,
            new: new as u32,
            acked: acked as u32,
        },
        ProgressKind::PairingChanged { session_id, phase } => ProgressKindView::PairingChanged {
            session_id: hex(&session_id),
            phase,
        },
        ProgressKind::RelayUnavailable { pending } => ProgressKindView::RelayUnavailable {
            pending: pending as u32,
        },
        ProgressKind::Onboarding { step } => ProgressKindView::Onboarding { step },
        ProgressKind::Gap { dropped } => ProgressKindView::Gap {
            dropped: dropped as u32,
        },
    };
    ProgressView {
        sequence: event.sequence,
        operation: operation_name(event.operation).to_string(),
        kind,
    }
}

fn event_view(event: HistoryEvent) -> HistoryEventView {
    // File descriptors contain capabilities and keys; legacy file events may
    // contain host paths. Only text-message bodies cross this UI boundary.
    let body = if matches!(event.kind.as_str(), "sent" | "received") {
        event.body
    } else {
        Vec::new()
    };
    HistoryEventView {
        cursor: event.cursor,
        event_id: hex(&event.event_id),
        kind: event.kind,
        body,
        attachment: event.attachment.map(|a| AttachmentView {
            name: a.name,
            size: a.size,
            outgoing: a.outgoing,
            transferred: a.transferred,
            total: a.total,
            state: match a.state {
                arveil_app::AttachmentState::Pending => AttachmentStateView::Pending,
                arveil_app::AttachmentState::Transferring => AttachmentStateView::Transferring,
                arveil_app::AttachmentState::Ready => AttachmentStateView::Ready,
                arveil_app::AttachmentState::Sent => AttachmentStateView::Sent,
                arveil_app::AttachmentState::Cancelled => AttachmentStateView::Cancelled,
                arveil_app::AttachmentState::Unavailable => AttachmentStateView::Unavailable,
                arveil_app::AttachmentState::Expired => AttachmentStateView::Expired,
                arveil_app::AttachmentState::Invalid => AttachmentStateView::Invalid,
                arveil_app::AttachmentState::Legacy => AttachmentStateView::Legacy,
            },
        }),
        delivery: event
            .delivery_states
            .into_iter()
            .map(|state| state.state)
            .collect(),
    }
}

/// A group identifier arrives as the same hexadecimal the list handed out.
fn decode_hex(value: &str) -> Result<Vec<u8>, CommandError> {
    if !value.len().is_multiple_of(2) || !value.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err(CommandError::Domain {
            operation: "query-history-page".into(),
            reason: "the conversation identifier is not hexadecimal".into(),
        });
    }
    (0..value.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&value[i..i + 2], 16))
        .collect::<Result<Vec<u8>, _>>()
        .map_err(|_| CommandError::Domain {
            operation: "query-history-page".into(),
            reason: "the conversation identifier is not hexadecimal".into(),
        })
}

fn key_package_view(value: arveil_app::KeyPackageSupply) -> KeyPackageSupplyView {
    use arveil_app::KeyPackageLevel;
    KeyPackageSupplyView {
        available: value.available,
        checked_at: value.checked_at,
        publication_pending: value.publication_pending,
        target: value.target,
        level: match value.level {
            KeyPackageLevel::Unknown => KeyPackageLevelView::Unknown,
            KeyPackageLevel::Empty => KeyPackageLevelView::Empty,
            KeyPackageLevel::Low => KeyPackageLevelView::Low,
            KeyPackageLevel::Ready => KeyPackageLevelView::Ready,
        },
    }
}

fn contact_view(contact: arveil_app::ContactSummary) -> ContactView {
    ContactView {
        identity_id: hex(&contact.identity_id),
        name: contact.name,
        label: contact.label,
        verified: contact.verified,
        safety_number: contact.safety_number,
        devices: contact
            .devices
            .into_iter()
            .map(|d| ContactDeviceView {
                device_id: hex(&d.device_id),
                revoked: d.revoked,
            })
            .collect(),
    }
}

fn view(summary: ConversationSummary) -> ConversationView {
    ConversationView {
        group_id: hex(&summary.group_id),
        creator: summary.creator,
        peer_devices: summary.peer_devices as u32,
        peers: summary
            .peers
            .into_iter()
            .map(|p| PeerView {
                identity_id: hex(&p.identity_id),
                device_id: hex(&p.device_id),
                label: p.label,
                own: p.own,
                verified: p.verified,
                revoked: p.revoked,
            })
            .collect(),
        event_count: summary.event_count as u32,
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn profile_error(error: ApplicationOpenError) -> ProfileError {
    match error {
        ApplicationOpenError::BadKey => ProfileError::BadKey,
        ApplicationOpenError::AlreadyOpen { ref path } => {
            ProfileError::AlreadyOpen { path: shown(path) }
        }
        ApplicationOpenError::Closing { ref path } => ProfileError::Closing { path: shown(path) },
        ApplicationOpenError::ProfileInUse { ref path } => {
            ProfileError::InUse { path: shown(path) }
        }
        ApplicationOpenError::Unusable {
            ref path,
            ref source,
        } => ProfileError::Unusable {
            path: shown(path),
            reason: source.to_string(),
        },
        ApplicationOpenError::Io {
            ref path,
            ref source,
            ..
        } => ProfileError::Io {
            path: shown(path),
            reason: source.to_string(),
        },
    }
}

fn shown(path: &std::path::Path) -> String {
    path.display().to_string()
}

fn command_error(error: ApplicationError) -> CommandError {
    let operation = error
        .operation()
        .map(operation_name)
        .unwrap_or("unknown")
        .to_string();
    let reason = error.to_string();
    match error {
        ApplicationError::Busy { active, .. } => CommandError::Busy {
            operation,
            active: active as u32,
        },
        ApplicationError::Panicked { .. } => CommandError::Panicked { operation },
        ApplicationError::Transport { .. } => CommandError::Transport { operation, reason },
        ApplicationError::Storage { .. } => CommandError::Storage { operation, reason },
        ApplicationError::Protocol { .. } => CommandError::Protocol { operation, reason },
        ApplicationError::Domain { .. } => CommandError::Domain { operation, reason },
        ApplicationError::FileSystem { .. } => CommandError::FileSystem { operation, reason },
        ApplicationError::Internal { .. } => CommandError::Internal { operation, reason },
        ApplicationError::Interrupted { .. } => CommandError::Interrupted { reason },
    }
}

/// A stable name per operation. The interface may key on it; it is not the
/// display text, which stays free to change.
fn operation_name(operation: Operation) -> &'static str {
    match operation {
        Operation::CreateIdentity => "create-identity",
        Operation::Enroll => "enroll",
        Operation::CreateLinkRequest => "create-link-request",
        Operation::AuthorizeLink => "authorize-link",
        Operation::CompleteLink => "complete-link",
        Operation::BeginPairing => "begin-pairing",
        Operation::AwaitPairing => "await-pairing",
        Operation::ApprovePairing => "approve-pairing",
        Operation::ConfirmPairing => "confirm-pairing",
        Operation::CancelPairing => "cancel-pairing",
        Operation::QueryPendingPairing => "query-pending-pairing",
        Operation::QueryOnboarding => "query-onboarding",
        Operation::QueryKeyPackageSupply => "query-key-package-supply",
        Operation::CheckKeyPackages => "check-key-packages",
        Operation::ReplenishKeyPackages => "replenish-key-packages",
        Operation::ExportKit => "export-kit",
        Operation::RestoreKit => "restore-kit",
        Operation::ResumeRecovery => "resume-recovery",
        Operation::QueryContacts => "query-contacts",
        Operation::SaveContact => "save-contact",
        Operation::RenameContact => "rename-contact",
        Operation::VerifyContact => "verify-contact",
        Operation::CreateContactConversation => "create-contact-conversation",
        Operation::QueryOwnRoute => "query-own-route",
        Operation::PreviewRoutes => "preview-routes",
        Operation::CreateVerifiedConversation => "create-verified-conversation",
        Operation::QueueMessage => "queue-message",
        Operation::CreateConversation => "create-conversation",
        Operation::AddDevice => "add-device",
        Operation::RemoveDevice => "remove-device",
        Operation::SendMessage => "send-message",
        Operation::SendFile => "send-file",
        Operation::QueueAttachment => "queue-attachment",
        Operation::ResumeAttachment => "resume-attachment",
        Operation::CancelAttachment => "cancel-attachment",
        Operation::ExportAttachment => "export-attachment",
        Operation::Sync => "sync",
        Operation::RevokeDevice => "revoke-device",
        Operation::QueryConversations => "query-conversations",
        Operation::QueryPeers => "query-peers",
        Operation::QueryHistoryPage => "query-history-page",
        Operation::QueryArchived => "query-archived",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use arveil_app::{OperationResult, StateChange};

    #[test]
    fn file_event_bodies_never_expose_descriptors_or_host_paths_to_dart() {
        for kind in [
            "file-pending",
            "sent-file",
            "received-file",
            "file-unavailable",
        ] {
            let view = event_view(HistoryEvent {
                cursor: 1,
                event_id: vec![1; 16],
                kind: kind.into(),
                body: b"private descriptor or local path".to_vec(),
                delivery_states: vec![],
                attachment: None,
            });
            assert!(view.body.is_empty());
        }
        let view = event_view(HistoryEvent {
            cursor: 1,
            event_id: vec![1; 16],
            kind: "received".into(),
            body: b"message".to_vec(),
            delivery_states: vec![],
            attachment: None,
        });
        assert_eq!(view.body, b"message");
    }

    #[test]
    fn a_post_commit_failure_returns_the_saved_group_instead_of_inviting_a_duplicate() {
        let result = chat_mutation(Err(ApplicationError::Domain {
            operation: Operation::CreateVerifiedConversation,
            source: arveil_app::carrier::CliError::Domain("after commit".into()),
            partial: OperationResult {
                changes: vec![StateChange::ConversationCreated {
                    group_id: vec![1, 2],
                    peers: 1,
                    epoch: 1,
                }],
                messages: vec![],
            },
        }))
        .unwrap();
        assert_eq!(result.group_id, "0102");
        assert!(result.event_id.is_none());
        assert!(matches!(result.warning, Some(CommandError::Domain { .. })));
        assert!(chat_mutation(Ok(OperationResult::default())).is_err());
    }
}
