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
    /// Unix seconds when the user last confirmed saving an identity kit on
    /// this administration device; absent if never.
    pub kit_saved_at: Option<i64>,
    /// Devices changed after the saved kit was made; a new kit should
    /// replace it.
    pub kit_stale: bool,
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

pub struct ArchiveView {
    pub encrypted: Vec<u8>,
    pub secret: String,
    pub records: u32,
    pub files: u32,
    pub unavailable_files: u32,
}
pub struct ArchiveReceiptView {
    pub imported: u32,
    pub duplicates: u32,
}
pub struct ArchiveEntryView {
    pub group_id: String,
    pub event_id: String,
    pub kind: String,
    pub text: String,
    pub created_at: i64,
    pub file_name: Option<String>,
    pub file_size: Option<u64>,
    /// The author the archive names, as a local name or short identifier:
    /// the exporting device's claim, not proof. Absent for own records and
    /// for records without an author.
    pub sender_label: Option<String>,
    /// Written by this identity, by the archive's account.
    pub own: bool,
}
pub struct ArchivePageView {
    pub entries: Vec<ArchiveEntryView>,
    pub next: Option<i64>,
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
pub struct DeviceInventoryView {
    pub administrator: bool,
    pub manifest_sequence: u64,
    pub unknown_active: u32,
    pub unknown_revoked: u32,
    pub devices: Vec<ManagedDeviceView>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ManagedDeviceView {
    pub device_id: String,
    pub current: bool,
    pub revoked: bool,
    pub revocation: Option<RevocationProgressView>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RevocationProgressView {
    pub relay_published: bool,
    pub groups_waiting: u32,
    pub notifications_pending: u32,
    pub notifications_unconfirmed: u32,
    pub without_route: u32,
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
    /// Whether this profile gave the identity a local name; otherwise
    /// `label` is its short identifier.
    pub named: bool,
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
    /// A newer version of the app wrote this profile. It was left as it
    /// was; updating the app opens it.
    TooNew {
        path: String,
        found: u32,
        supported: u32,
    },
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
    /// The relay refused because one of its limits was reached. Nothing was
    /// started; a retry before the limit clears is refused again.
    Quota {
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
    /// Unix seconds when this device recorded the event: arrival for what
    /// it received, creation for what it sent. Not when the sender wrote it.
    pub created_at: i64,
    /// Hexadecimal identity that wrote the event, when known.
    pub sender_identity: Option<String>,
    /// Local contact name or short identifier of that identity. Absent for
    /// this profile's own events and for senders nobody can name.
    pub sender_label: Option<String>,
    /// Written by this identity, from this device or another of its own.
    pub own: bool,
    /// For a device-change notice, what changed; its author is the sender.
    pub notice: Option<NoticeView>,
}

/// A contact's devices changed. Counts only: no device is named.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NoticeView {
    pub added: u32,
    pub removed: u32,
}

/// One page, oldest first within the page.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HistoryPageView {
    pub events: Vec<HistoryEventView>,
    /// Cursor for the page before this one; absent at the beginning of the
    /// conversation.
    pub next: Option<i64>,
}

/// One row of the conversation list. The application orders rows by
/// `last_activity`, most recent first.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConversationView {
    pub group_id: String,
    pub creator: bool,
    pub peer_devices: u32,
    pub peers: Vec<PeerView>,
    pub event_count: u32,
    pub last_event: Option<LastEventView>,
    /// Messages after this device's read marker that someone else wrote.
    pub unread: u32,
    /// Unix seconds of the newest event, or of when this device started
    /// keeping the conversation.
    pub last_activity: i64,
}

/// What a conversation row says about its newest event.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LastEventView {
    /// Position of the event in its conversation, as history reports it.
    pub cursor: i64,
    pub kind: String,
    /// The start of a text message on one line, at most `PREVIEW_CHARS`
    /// characters; empty for every other kind.
    pub preview: String,
    pub attachment_name: Option<String>,
    pub sender_label: Option<String>,
    pub own: bool,
    pub created_at: i64,
    /// Delivery state per mailbox, for events this device sent.
    pub delivery: Vec<String>,
    pub notice: Option<NoticeView>,
}

/// How far a conversation has been read on this device.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ReadMarkerView {
    pub cursor: i64,
    pub unread: u32,
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
            kit_saved_at: status.kit_saved_at.map(|at| at as i64),
            kit_stale: status.kit_stale,
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

    pub fn export_archive(&self) -> Result<ArchiveView, CommandError> {
        let a = self.inner.export_archive().map_err(command_error)?;
        Ok(ArchiveView {
            encrypted: a.encrypted,
            secret: a.secret,
            records: a.records,
            files: a.files,
            unavailable_files: a.unavailable_files,
        })
    }
    pub fn import_archive(
        &self,
        encrypted: Vec<u8>,
        secret: String,
    ) -> Result<ArchiveReceiptView, CommandError> {
        let r = self
            .inner
            .import_archive(arveil_app::ArchiveImport { encrypted, secret })
            .map_err(command_error)?;
        Ok(ArchiveReceiptView {
            imported: r.imported,
            duplicates: r.duplicates,
        })
    }
    pub fn archive_page(
        &self,
        before: Option<i64>,
        limit: u32,
    ) -> Result<ArchivePageView, CommandError> {
        let page = self
            .inner
            .archive_page(before, limit)
            .map_err(command_error)?;
        Ok(ArchivePageView {
            entries: page
                .entries
                .into_iter()
                .map(|e| ArchiveEntryView {
                    group_id: hex(&e.group_id),
                    event_id: hex(&e.event_id),
                    kind: e.kind,
                    text: e.text,
                    created_at: e.created_at,
                    file_name: e.file_name,
                    file_size: e.file_size,
                    sender_label: e.sender_label,
                    own: e.own,
                })
                .collect(),
            next: page.next,
        })
    }
    pub fn archive_file(
        &self,
        group_id: String,
        event_id: String,
    ) -> Result<Vec<u8>, CommandError> {
        self.inner
            .archive_file(decode_hex(&group_id)?, decode_hex(&event_id)?)
            .map_err(command_error)
    }

    pub fn export_kit(&self) -> Result<KitView, CommandError> {
        let kit = self.inner.export_kit().map_err(command_error)?;
        Ok(KitView {
            encrypted: kit.encrypted,
            secret: kit.secret,
        })
    }

    /// The user saved the last exported kit and confirmed its key is kept
    /// apart. Read `setup` again for the new kit state.
    pub fn confirm_kit_saved(&self) -> Result<(), CommandError> {
        self.inner
            .confirm_kit_saved()
            .map(|_| ())
            .map_err(command_error)
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

    pub fn devices(&self) -> Result<DeviceInventoryView, CommandError> {
        let value = self.inner.devices().map_err(command_error)?;
        Ok(DeviceInventoryView {
            administrator: value.administrator,
            manifest_sequence: value.manifest_sequence,
            unknown_active: value.unknown_active,
            unknown_revoked: value.unknown_revoked,
            devices: value
                .devices
                .into_iter()
                .map(|d| ManagedDeviceView {
                    device_id: hex(&d.device_id),
                    current: d.current,
                    revoked: d.revoked,
                    revocation: d.revocation.map(|r| RevocationProgressView {
                        relay_published: r.relay_published,
                        groups_waiting: r.groups_waiting,
                        notifications_pending: r.notifications_pending,
                        notifications_unconfirmed: r.notifications_unconfirmed,
                        without_route: r.without_route,
                    }),
                })
                .collect(),
        })
    }

    /// A later network failure can follow a durable local revocation. Always
    /// query devices again, and resume with sync rather than creating new state.
    pub fn revoke_device(&self, bootstrap: String, device_id: String) -> Result<(), CommandError> {
        self.inner
            .revoke_device(&bootstrap, &device_id)
            .map_err(command_error)?;
        Ok(())
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
        self.watch_with(generation, move |view| sink.add(view).is_ok());
    }

    /// The loop behind `watch`, on a thread of its own that holds the
    /// subscription and never this profile. On Android, Back from the first
    /// screen destroys the engine while the process lives on, and nothing
    /// stops the watcher; releasing the last handle then still closes the
    /// profile, which ends the loop, so the next open in that process does
    /// not find it already open.
    fn watch_with(
        &self,
        generation: u64,
        mut deliver: impl FnMut(ProgressView) -> bool + Send + 'static,
    ) {
        let subscription = self.inner.watch();
        let watching = Arc::clone(&self.watching);
        // Without a thread there is nobody to feed: dropping `deliver`
        // closes the stream.
        let _ = std::thread::Builder::new()
            .name("arveil-watch".into())
            .spawn(move || {
                while watching.load(AtomicOrdering::Acquire) == generation {
                    match subscription.wait(std::time::Duration::from_millis(100)) {
                        Waited::Event(event) => {
                            if !deliver(progress_view(event)) {
                                break;
                            }
                        }
                        // Idle only means nothing happened; it is the chance
                        // to notice that nobody is watching any more.
                        Waited::Idle => continue,
                        Waited::Closed => break,
                    }
                }
            });
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

    /// Text messages of one conversation containing `text`, newest first,
    /// ignoring case and accents. Each call reads a bounded number of
    /// events; pass `next` as `before` to keep searching further back.
    pub fn search_history(
        &self,
        group_id: String,
        text: String,
        before: Option<i64>,
        limit: u32,
    ) -> Result<HistoryPageView, CommandError> {
        let group = decode_hex(&group_id)?;
        let page = self
            .inner
            .search_history(&group, &text, before, limit as usize)
            .map_err(command_error)?;
        Ok(HistoryPageView {
            events: page.events.into_iter().map(event_view).collect(),
            next: page.next,
        })
    }

    /// Mark a conversation read up to `cursor`, the newest event a screen
    /// showed. Marking twice, late or past the end is harmless.
    pub fn mark_read(&self, group_id: String, cursor: i64) -> Result<ReadMarkerView, CommandError> {
        let group = decode_hex(&group_id)?;
        let marker = self
            .inner
            .mark_read(&group, cursor)
            .map_err(command_error)?;
        Ok(ReadMarkerView {
            cursor: marker.cursor,
            unread: marker.unread,
        })
    }

    /// The conversation list, as a query that answers from local state,
    /// most recently active first.
    pub fn conversations(&self) -> Result<Vec<ConversationView>, CommandError> {
        let mut rows: Vec<ConversationView> = self
            .inner
            .conversations()
            .map_err(command_error)?
            .into_iter()
            .map(view)
            .collect();
        by_activity(&mut rows);
        Ok(rows)
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
        created_at: event.created_at,
        sender_identity: event.sender_identity.as_deref().map(hex),
        sender_label: event.sender_label,
        own: event.own,
        notice: event.notice.map(notice_view),
    }
}

fn notice_view(change: arveil_app::DeviceChange) -> NoticeView {
    NoticeView {
        added: change.added,
        removed: change.removed,
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
                named: p.named,
                own: p.own,
                verified: p.verified,
                revoked: p.revoked,
            })
            .collect(),
        event_count: summary.event_count as u32,
        last_event: summary.last_event.map(last_event_view),
        unread: summary.unread,
        last_activity: summary.last_activity,
    }
}

/// Most recent activity first. Event identifiers grow across
/// conversations, so they order what happened within the same second; a
/// full tie keeps the order conversations were started (the sort is stable).
fn by_activity(rows: &mut [ConversationView]) {
    rows.sort_by(|a, b| {
        let cursor = |row: &ConversationView| row.last_event.as_ref().map(|e| e.cursor);
        b.last_activity
            .cmp(&a.last_activity)
            .then_with(|| cursor(b).cmp(&cursor(a)))
    });
}

/// The most characters of a message a conversation row shows.
const PREVIEW_CHARS: usize = 120;

fn last_event_view(event: HistoryEvent) -> LastEventView {
    // The same boundary as history: only text bodies cross it, and here
    // only their beginning, on one line.
    let preview = if matches!(event.kind.as_str(), "sent" | "received") {
        let text = String::from_utf8_lossy(&event.body);
        let line = text.split_whitespace().collect::<Vec<_>>().join(" ");
        match line.char_indices().nth(PREVIEW_CHARS) {
            Some((end, _)) => format!("{}…", &line[..end]),
            None => line,
        }
    } else {
        String::new()
    };
    LastEventView {
        cursor: event.cursor,
        kind: event.kind,
        preview,
        attachment_name: event.attachment.map(|a| a.name),
        sender_label: event.sender_label,
        own: event.own,
        created_at: event.created_at,
        delivery: event
            .delivery_states
            .into_iter()
            .map(|state| state.state)
            .collect(),
        notice: event.notice.map(notice_view),
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
        ApplicationOpenError::ProfileTooNew {
            ref path,
            found,
            supported,
        } => ProfileError::TooNew {
            path: shown(path),
            found,
            supported,
        },
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
        ApplicationError::Quota { .. } => CommandError::Quota { operation, reason },
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
        Operation::ExportArchive => "export-archive",
        Operation::ImportArchive => "import-archive",
        Operation::QueryArchivePage => "query-archive-page",
        Operation::ExportArchiveFile => "export-archive-file",
        Operation::ExportKit => "export-kit",
        Operation::ConfirmKitSaved => "confirm-kit-saved",
        Operation::RestoreKit => "restore-kit",
        Operation::ResumeRecovery => "resume-recovery",
        Operation::QueryContacts => "query-contacts",
        Operation::QueryDevices => "query-devices",
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
        Operation::SearchHistory => "search-history",
        Operation::MarkRead => "mark-read",
        Operation::QueryArchived => "query-archived",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use arveil_app::{OperationResult, StateChange};

    fn event(kind: &str, body: &[u8]) -> HistoryEvent {
        HistoryEvent {
            cursor: 1,
            event_id: vec![1; 16],
            kind: kind.into(),
            body: body.to_vec(),
            delivery_states: vec![],
            attachment: None,
            created_at: 1_790_000_000,
            sender_identity: None,
            sender_label: Some("Lucía".into()),
            own: false,
            notice: None,
        }
    }

    #[test]
    fn rows_follow_activity_and_keep_start_order_on_a_full_tie() {
        let row = |id: &str, activity: i64, cursor: Option<i64>| ConversationView {
            group_id: id.into(),
            creator: true,
            peer_devices: 1,
            peers: vec![],
            event_count: u32::from(cursor.is_some()),
            last_event: cursor.map(|cursor| LastEventView {
                cursor,
                ..last_event_view(event("received", b"x"))
            }),
            unread: 0,
            last_activity: activity,
        };
        // Started in this order: a, b, c, d, e.
        let mut rows = vec![
            row("a", 100, Some(1)),
            row("b", 200, Some(2)),
            row("c", 200, Some(5)),
            row("d", 50, None),
            row("e", 50, None),
        ];
        by_activity(&mut rows);
        let order: Vec<_> = rows.iter().map(|r| r.group_id.as_str()).collect();
        // Same second: the later event first. No events and the same
        // second: the order they were started.
        assert_eq!(order, ["c", "b", "a", "d", "e"]);
    }

    #[test]
    fn a_row_preview_is_one_short_line_of_text_and_nothing_else() {
        let short = last_event_view(event("received", b"hola\n  familia"));
        assert_eq!(short.preview, "hola familia");
        assert_eq!(short.sender_label.as_deref(), Some("Lucía"));

        // Cut by characters, not bytes: multibyte text never splits.
        let long = "ñ".repeat(PREVIEW_CHARS + 5);
        let cut = last_event_view(event("sent", long.as_bytes()));
        assert_eq!(cut.preview.chars().count(), PREVIEW_CHARS + 1);
        assert!(cut.preview.ends_with('…'));

        for kind in ["file-pending", "file-outgoing", "sent-file"] {
            let file = last_event_view(event(kind, b"private descriptor or local path"));
            assert!(file.preview.is_empty(), "{kind} leaked its body");
        }
    }

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
                created_at: 1_790_000_000,
                sender_identity: None,
                sender_label: None,
                own: false,
                notice: None,
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
            created_at: 1_790_000_000,
            sender_identity: Some(vec![0xab, 0xcd]),
            sender_label: Some("Lucía".into()),
            own: false,
            notice: None,
        });
        assert_eq!(view.body, b"message");
        assert_eq!(view.created_at, 1_790_000_000);
        assert_eq!(view.sender_identity.as_deref(), Some("abcd"));
        assert_eq!(view.sender_label.as_deref(), Some("Lucía"));
        assert!(!view.own);
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

    #[test]
    fn a_relay_limit_reaches_the_interface_as_quota_with_its_operation() {
        let error = command_error(ApplicationError::Quota {
            operation: Operation::BeginPairing,
            source: arveil_app::carrier::CliError::Relay {
                code: 429,
                message: "too many pairings from this address; wait and try again".into(),
            },
            partial: OperationResult::default(),
        });
        let CommandError::Quota { operation, .. } = error else {
            panic!("expected a quota error, got {error:?}");
        };
        assert_eq!(operation, "begin-pairing");
    }

    fn scratch(name: &str) -> String {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir()
            .join(format!(
                "arveil-flutter-{name}-{}-{nanos}",
                std::process::id()
            ))
            .to_string_lossy()
            .into_owned()
    }

    /// Waits for the watcher to drop its sender, which is how it ends.
    fn ended(rx: &std::sync::mpsc::Receiver<()>) -> bool {
        matches!(
            rx.recv_timeout(std::time::Duration::from_secs(10)),
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected)
        )
    }

    #[test]
    fn a_watcher_nobody_stopped_does_not_keep_the_profile_open() {
        let dir = scratch("watch-left");
        let profile = open_unencrypted_profile(dir.clone()).unwrap();
        let (feeding, fed) = std::sync::mpsc::channel::<()>();
        let generation = profile.start_watching();
        profile.watch_with(generation, move |_| feeding.send(()).is_ok());
        // What Android does when Back leaves the app: the engine goes away
        // and only the handle is released, with nobody stopping the stream.
        drop(profile);
        assert!(ended(&fed), "closing the profile ends the watcher");
        let again = open_unencrypted_profile(dir.clone())
            .expect("the same process opens the profile again");
        again.close();
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn stopping_a_watcher_ends_it_while_the_profile_stays_open() {
        let dir = scratch("watch-stop");
        let profile = open_unencrypted_profile(dir.clone()).unwrap();
        let (feeding, fed) = std::sync::mpsc::channel::<()>();
        let generation = profile.start_watching();
        profile.watch_with(generation, move |_| feeding.send(()).is_ok());
        profile.stop_watching(generation);
        assert!(ended(&fed));
        assert!(profile.setup().is_ok(), "the profile is still open");
        profile.close();
        std::fs::remove_dir_all(&dir).ok();
    }
}
