//! Opening, closing and querying one profile.
//!
//! Every call here is blocking underneath, and the bindings run it on a
//! worker, never on the interface thread. Errors keep the category the
//! application layer assigned: a caller never has to read a message to
//! learn what happened.

use arveil_app::{
    Application, ApplicationError, ApplicationOpenError, ConversationSummary, HistoryEvent,
    Operation, ProfileConfig,
};

/// A session over one profile. Opaque to Dart: the database, the MLS engine
/// and the keys stay on this side.
pub struct Profile {
    inner: Application,
}

/// Why a profile could not be opened.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProfileError {
    /// The key is not 32 bytes as 64 hexadecimal characters.
    BadKey,
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

/// Open a profile encrypted at rest. The key comes from the platform store,
/// never from this crate and never from the environment.
pub fn open_profile(dir: String, key: String) -> Result<Profile, ProfileError> {
    let config = ProfileConfig::encrypted(dir, key).map_err(profile_error)?;
    Ok(Profile {
        inner: Application::open(config).map_err(profile_error)?,
    })
}

/// Open a profile with nothing encrypting it. Only a development build has
/// any business calling this, and it has to say so.
pub fn open_unencrypted_profile(dir: String) -> Result<Profile, ProfileError> {
    Ok(Profile {
        inner: Application::open(ProfileConfig::unencrypted(dir)).map_err(profile_error)?,
    })
}

impl Profile {
    /// Stop admitting work, wait for what is running and release the
    /// profile. Idempotent, and every later call fails instead of quietly
    /// opening it again.
    pub fn close(&self) {
        self.inner.close();
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
