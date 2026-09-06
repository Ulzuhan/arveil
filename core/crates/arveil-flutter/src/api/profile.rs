//! Opening, closing and querying one profile.
//!
//! Every call here is blocking underneath, and the bindings run it on a
//! worker, never on the interface thread. Errors keep the category the
//! application layer assigned: a caller never has to read a message to
//! learn what happened.

use arveil_app::{
    Application, ApplicationError, ApplicationOpenError, ConversationSummary, HistoryEvent,
    Operation, ProfileConfig, ProgressEvent, ProgressKind, Waited,
};
use flutter_rust_bridge::frb;

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering as AtomicOrdering};

use crate::frb_generated::StreamSink;

/// A session over one profile. Opaque to Dart: the database, the MLS engine
/// and the keys stay on this side.
pub struct Profile {
    inner: Application,
    /// Set while a stream is wanted. Cleared by `stop_watching`, which is
    /// how a screen unsubscribes without closing the profile.
    watching: Arc<AtomicBool>,
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
pub struct HistoryEventView {
    /// Position in the conversation. Pass the oldest one back as `before`
    /// to read the page before this one.
    pub cursor: i64,
    pub event_id: String,
    pub kind: String,
    pub body: Vec<u8>,
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
    let config = ProfileConfig::encrypted(dir, key).map_err(profile_error)?;
    Ok(Profile {
        inner: Application::open(config).map_err(profile_error)?,
        watching: Arc::new(AtomicBool::new(false)),
    })
}

/// Open a profile with nothing encrypting it. Only a development build has
/// any business calling this, and it has to say so.
pub fn open_unencrypted_profile(dir: String) -> Result<Profile, ProfileError> {
    Ok(Profile {
        inner: Application::open(ProfileConfig::unencrypted(dir)).map_err(profile_error)?,
        watching: Arc::new(AtomicBool::new(false)),
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

    /// Watch progress while operations run. The stream ends when the
    /// profile closes or when `stop_watching` is called; a listener should
    /// stop before cancelling, since the stream is closed from this side.
    pub fn watch(&self, sink: StreamSink<ProgressView>) {
        let subscription = self.inner.watch();
        self.watching.store(true, AtomicOrdering::Release);
        while self.watching.load(AtomicOrdering::Acquire) {
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
    pub fn stop_watching(&self) {
        self.watching.store(false, AtomicOrdering::Release);
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
    HistoryEventView {
        cursor: event.cursor,
        event_id: hex(&event.event_id),
        kind: event.kind,
        body: event.body,
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

fn view(summary: ConversationSummary) -> ConversationView {
    ConversationView {
        group_id: hex(&summary.group_id),
        creator: summary.creator,
        peer_devices: summary.peer_devices as u32,
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
        Operation::CreateConversation => "create-conversation",
        Operation::AddDevice => "add-device",
        Operation::RemoveDevice => "remove-device",
        Operation::SendMessage => "send-message",
        Operation::SendFile => "send-file",
        Operation::Sync => "sync",
        Operation::RevokeDevice => "revoke-device",
        Operation::QueryConversations => "query-conversations",
        Operation::QueryPeers => "query-peers",
        Operation::QueryHistoryPage => "query-history-page",
        Operation::QueryArchived => "query-archived",
    }
}
