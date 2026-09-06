//! Application layer for Arveil conversations.
//!
//! `chat start` claims one KeyPackage per peer, creates a group whose
//! context carries the Arveil policy (creator = committer), adds every peer
//! in one commit, seals the Welcome to each peer and then sends the roster
//! (every member's route, including its own) inside the group.
//! `chat add` (creator only) adds a member later: Welcome to the newcomer,
//! commit to the existing members, updated roster to everyone.
//! `chat send` runs the send unit once (MLS encrypt + persist + event) and
//! enqueues one envelope per routable peer; peers without a route are
//! visible as pending. `chat sync` publishes what is pending, then fetches
//! the mailbox and runs the receive unit per envelope before ACKing.
//!
//! Set `ARVEIL_CRASH_AFTER_COMMIT=1` to make `chat send` exit right after
//! the send unit committed and before anything is published (I-04).

pub mod carrier;
mod onboarding;

pub use arveil_core::client::PairingCompletionPhase;
pub use onboarding::{
    DeviceLinkAuthorization, DeviceLinkRequest, Enrollment, EnrollmentFinish, Identity,
    LinkedDevice, PairingSession, PairingVerification, finish_enrollment,
};

use std::cell::RefCell;
use std::collections::HashMap;
use std::fs::{File, OpenOptions, TryLockError};
use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock, Weak, mpsc};

use arveil_core::attachments::{self, FileDescriptor};
use arveil_core::channel::codec::Payload;
use arveil_core::client::{Client, Conversation, OwnMailbox, Peer, StoredDevice, StoredRealm};
use arveil_core::delivery::Delivery;
use arveil_core::envelope::{self, EnvelopeContext, KIND_MLS};
use arveil_core::mls::Engine;
use arveil_core::storage::SharedConn;
use futures_util::FutureExt;
use futures_util::stream::{FuturesUnordered, StreamExt};
use mls_rs::client_builder::MlsConfig;
use mls_rs::group::{Group, ReceivedMessage};
use mls_rs::{MlsMessage, WireFormat};
use serde::{Deserialize, Serialize};

use crate::carrier::{Bootstrap, CliError, Connection, FailureKind};

fn storage_error<E: std::fmt::Display>(context: &str) -> impl FnOnce(E) -> CliError + '_ {
    move |error| CliError::Storage(format!("{context}: {error}"))
}

fn protocol_error<E: std::fmt::Display>(context: &str) -> impl FnOnce(E) -> CliError + '_ {
    move |error| CliError::Protocol(format!("{context}: {error}"))
}

fn domain_error<E: std::fmt::Display>(context: &str) -> impl FnOnce(E) -> CliError + '_ {
    move |error| CliError::Domain(format!("{context}: {error}"))
}

fn filesystem_error<E: std::fmt::Display>(context: &str) -> impl FnOnce(E) -> CliError + '_ {
    move |error| CliError::FileSystem(format!("{context}: {error}"))
}

/// A business operation exposed to every Arveil front end.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Operation {
    CreateIdentity,
    Enroll,
    CreateLinkRequest,
    AuthorizeLink,
    CompleteLink,
    BeginPairing,
    AwaitPairing,
    ApprovePairing,
    ConfirmPairing,
    CancelPairing,
    QueryPendingPairing,
    CreateConversation,
    AddDevice,
    RemoveDevice,
    SendMessage,
    SendFile,
    Sync,
    RevokeDevice,
    QueryConversations,
    QueryPeers,
    QueryHistoryPage,
    QueryArchived,
}

/// A command accepted by the serial executor for one client profile.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ClientCommand {
    CreateIdentity,
    Enroll {
        bootstrap: String,
        invite: String,
    },
    CreateLinkRequest,
    AuthorizeLink {
        bootstrap: String,
        request: String,
    },
    CompleteLink {
        bootstrap: String,
        grant: String,
    },
    BeginPairing {
        bootstrap: String,
    },
    AwaitPairing {
        bootstrap: String,
        session: PairingSession,
    },
    ApprovePairing {
        bootstrap: String,
        code: String,
    },
    ConfirmPairing {
        bootstrap: String,
        session_id: Vec<u8>,
        verification_code: String,
    },
    CancelPairing {
        session_id: Vec<u8>,
    },
    QueryPendingPairing,
    CreateConversation {
        bootstrap: String,
        peer_routes: Vec<String>,
    },
    AddDevice {
        bootstrap: String,
        peer_route: String,
        group: Option<String>,
    },
    RemoveDevice {
        bootstrap: String,
        device_id: String,
        group: Option<String>,
    },
    SendMessage {
        bootstrap: String,
        text: String,
        group: Option<String>,
    },
    SendFile {
        bootstrap: String,
        path: PathBuf,
        group: Option<String>,
    },
    Sync {
        bootstrap: String,
    },
    RevokeDevice {
        bootstrap: String,
        device_id: String,
    },
    QueryConversations,
    QueryPeers {
        group: Vec<u8>,
    },
    QueryHistoryPage {
        group: Vec<u8>,
        before: Option<i64>,
        limit: usize,
    },
    QueryArchived {
        group: Option<Vec<u8>>,
    },
    /// Panics on purpose, inside a transaction that has already written.
    /// The contract for a panic is only worth what its test proves.
    #[cfg(test)]
    PanicProbe,
}

impl ClientCommand {
    fn operation(&self) -> Operation {
        match self {
            Self::CreateIdentity => Operation::CreateIdentity,
            Self::Enroll { .. } => Operation::Enroll,
            Self::CreateLinkRequest => Operation::CreateLinkRequest,
            Self::AuthorizeLink { .. } => Operation::AuthorizeLink,
            Self::CompleteLink { .. } => Operation::CompleteLink,
            Self::BeginPairing { .. } => Operation::BeginPairing,
            Self::AwaitPairing { .. } => Operation::AwaitPairing,
            Self::ApprovePairing { .. } => Operation::ApprovePairing,
            Self::ConfirmPairing { .. } => Operation::ConfirmPairing,
            Self::CancelPairing { .. } => Operation::CancelPairing,
            Self::QueryPendingPairing => Operation::QueryPendingPairing,
            Self::CreateConversation { .. } => Operation::CreateConversation,
            Self::AddDevice { .. } => Operation::AddDevice,
            Self::RemoveDevice { .. } => Operation::RemoveDevice,
            Self::SendMessage { .. } => Operation::SendMessage,
            Self::SendFile { .. } => Operation::SendFile,
            Self::Sync { .. } => Operation::Sync,
            Self::RevokeDevice { .. } => Operation::RevokeDevice,
            Self::QueryConversations => Operation::QueryConversations,
            Self::QueryPeers { .. } => Operation::QueryPeers,
            Self::QueryHistoryPage { .. } => Operation::QueryHistoryPage,
            Self::QueryArchived { .. } => Operation::QueryArchived,
            #[cfg(test)]
            Self::PanicProbe => Operation::Sync,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MessageKind {
    Text,
    File,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LocalAcceptance {
    PersistedToOutbox {
        envelopes: usize,
        peers_without_route: usize,
        revoked_devices: usize,
    },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MessageReceipt {
    pub group_id: Vec<u8>,
    pub event_id: Vec<u8>,
    pub kind: MessageKind,
    pub local_acceptance: LocalAcceptance,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DeliveryStatus {
    Queued,
    Accepted { expires_at: u64 },
    Undeliverable { reason: String },
}

/// Structured changes that a GUI can apply directly to its local view.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StateChange {
    IdentityCreated {
        identity_id: Vec<u8>,
        created_during_enrollment: bool,
    },
    DevicePrepared {
        device_id: Vec<u8>,
    },
    EnrollmentAccepted {
        identity_id: Vec<u8>,
    },
    EnrollmentEndpointListStored {
        sequence: u64,
    },
    MailboxCreated {
        mailbox_id: Vec<u8>,
    },
    KeyPackagesPublished {
        count: usize,
    },
    RouteAvailable {
        route: String,
    },
    LinkRequestCreated {
        device_id: Vec<u8>,
        request: String,
    },
    DeviceAuthorizationSigned {
        device_id: Vec<u8>,
        manifest_sequence: u64,
    },
    ManifestPublished {
        sequence: u64,
    },
    CredentialPublished,
    LinkGrantCreated {
        grant: String,
    },
    DeviceLinked {
        device_id: Vec<u8>,
        identity_id: Vec<u8>,
    },
    PairingStarted {
        session_id: Vec<u8>,
        device_id: Vec<u8>,
        code: String,
        expires_at: u64,
    },
    PairingVerificationReady {
        session_id: Vec<u8>,
        verification_code: String,
        expires_at: Option<u64>,
        confirmation_required: bool,
    },
    PairingGrantSent {
        session_id: Vec<u8>,
        verification_code: String,
    },
    PairingCancelled {
        session_id: Vec<u8>,
    },
    PairingCancellationRejected {
        session_id: Vec<u8>,
        reason: PairingCancellation,
    },
    PairingCompletionChanged {
        session_id: Vec<u8>,
        phase: PairingCompletionPhase,
    },
    LinkCompletionChanged {
        phase: PairingCompletionPhase,
    },
    PairingExpired {
        session_id: Vec<u8>,
    },
    MessageQueued {
        receipt: MessageReceipt,
        epoch: u64,
    },
    DeliveryChanged {
        event_id: Option<Vec<u8>>,
        mailbox_id: Vec<u8>,
        delivery_id: Vec<u8>,
        state: DeliveryStatus,
    },
    EnvelopesPublished {
        count: usize,
        pending: bool,
    },
    RelayUnavailable {
        pending: usize,
        reason: String,
    },
    ConversationCreated {
        group_id: Vec<u8>,
        peers: usize,
        epoch: u64,
    },
    ConversationJoined {
        group_id: Vec<u8>,
        epoch: u64,
    },
    RosterUpdated {
        group_id: Vec<u8>,
        peers: usize,
    },
    DeviceAdded {
        identity_id: Vec<u8>,
        device_id: Vec<u8>,
        epoch: u64,
    },
    DeviceRemoved {
        device_id: Vec<u8>,
        leaf: u32,
        epoch: u64,
    },
    CommitApplied {
        group_id: Vec<u8>,
        committer: u32,
        epoch: u64,
    },
    MessageReceived {
        group_id: Vec<u8>,
        event_id: Vec<u8>,
        body: Vec<u8>,
    },
    FileAnnounced {
        group_id: Vec<u8>,
        event_id: Vec<u8>,
        name: String,
        size: u64,
    },
    DuplicateDelivery {
        delivery_id: Vec<u8>,
    },
    DeliveryDeferred {
        delivery_id: Vec<u8>,
        reason: String,
    },
    SyncCompleted {
        fetched: usize,
        new: usize,
        acked: usize,
    },
    EndpointFallback {
        url: String,
    },
    EndpointFailed {
        url: String,
        reason: String,
    },
    EndpointListStored {
        sequence: u64,
        endpoints: usize,
    },
    EndpointListRejected {
        reason: String,
    },
    ManifestUpdated {
        identity_id: Vec<u8>,
        sequence: u64,
        active_devices: usize,
        revoked_devices: usize,
        source: ManifestSource,
        already_known: bool,
    },
    ManifestRejected {
        identity_id: Vec<u8>,
        reason: String,
    },
    DeviceRevoked {
        device_id: Vec<u8>,
        credential_hash: Vec<u8>,
    },
    RealmRevocationPublished,
    ConversationManifestSent {
        group_id: Vec<u8>,
        removal: RemovalOutcome,
    },
    KeyPackagesReplenished {
        previous: u32,
        published: usize,
    },
    ArchivedConversation {
        group_id: Vec<u8>,
    },
    ArchivedEvent {
        kind: String,
        body: Vec<u8>,
    },
    UploadRestarted {
        name: String,
        reason: UploadRestartReason,
    },
    UploadResumed {
        name: String,
        offset: usize,
        total: usize,
    },
    BlobUploaded {
        blob_id: Vec<u8>,
        ciphertext_size: usize,
        expires_at: u64,
    },
    FileDownloadResumed {
        name: String,
        offset: usize,
    },
    FileSaved {
        name: String,
        path: PathBuf,
    },
    FileUnavailable {
        name: String,
        reason: String,
    },
    MlsMessageProcessed {
        group_id: Vec<u8>,
        description: String,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ManifestSource {
    Group,
    Realm,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RemovalOutcome {
    Removed { epoch: u64 },
    LeftToCommitter,
    NotInGroup,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum UploadRestartReason {
    FileChanged,
    RemoteMissing { reason: String },
}

/// Result of a mutating operation, including all state changes it emitted.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct OperationResult {
    pub changes: Vec<StateChange>,
    pub messages: Vec<MessageReceipt>,
}

/// Errors are classified by operation, and interruptions used by durability
/// tests remain distinguishable from ordinary failures.
#[derive(Debug, thiserror::Error)]
pub enum ApplicationError {
    #[error("transport failed during {operation:?}: {source}")]
    Transport {
        operation: Operation,
        #[source]
        source: CliError,
        partial: OperationResult,
    },
    #[error("storage failed during {operation:?}: {source}")]
    Storage {
        operation: Operation,
        #[source]
        source: CliError,
        partial: OperationResult,
    },
    #[error("protocol failed during {operation:?}: {source}")]
    Protocol {
        operation: Operation,
        #[source]
        source: CliError,
        partial: OperationResult,
    },
    #[error("domain rule failed during {operation:?}: {source}")]
    Domain {
        operation: Operation,
        #[source]
        source: CliError,
        partial: OperationResult,
    },
    #[error("filesystem failed during {operation:?}: {source}")]
    FileSystem {
        operation: Operation,
        #[source]
        source: CliError,
        partial: OperationResult,
    },
    #[error("internal failure during {operation:?}: {source}")]
    Internal {
        operation: Operation,
        #[source]
        source: CliError,
        partial: OperationResult,
    },
    #[error("{operation:?} refused: {active} operations of its kind are already in flight")]
    Busy { operation: Operation, active: usize },
    #[error(
        "{operation:?} failed and ended this session; the profile is intact, close it and open it again"
    )]
    Panicked { operation: Operation },
    #[error("{message}")]
    Interrupted {
        exit_code: u8,
        message: String,
        partial: OperationResult,
    },
}

impl ApplicationError {
    pub fn operation(&self) -> Option<Operation> {
        match self {
            Self::Transport { operation, .. }
            | Self::Storage { operation, .. }
            | Self::Protocol { operation, .. }
            | Self::Domain { operation, .. }
            | Self::FileSystem { operation, .. }
            | Self::Internal { operation, .. } => Some(*operation),
            Self::Busy { operation, .. } | Self::Panicked { operation } => Some(*operation),
            Self::Interrupted { .. } => None,
        }
    }

    pub fn exit_code(&self) -> Option<u8> {
        match self {
            Self::Interrupted { exit_code, .. } => Some(*exit_code),
            _ => None,
        }
    }

    pub fn partial_result(&self) -> &OperationResult {
        match self {
            Self::Transport { partial, .. }
            | Self::Storage { partial, .. }
            | Self::Protocol { partial, .. }
            | Self::Domain { partial, .. }
            | Self::FileSystem { partial, .. }
            | Self::Internal { partial, .. }
            | Self::Interrupted { partial, .. } => partial,
            // A refusal never started, and a panic left nothing a caller
            // should act on: what is durable is on disk.
            Self::Busy { .. } | Self::Panicked { .. } => {
                static NOTHING: OnceLock<OperationResult> = OnceLock::new();
                NOTHING.get_or_init(OperationResult::default)
            }
        }
    }
}

/// What a screen may show while an operation is still running.
///
/// This is a projection, not the internal change set: it carries the few
/// things a user interface can act on, and says nothing about the rest. The
/// durable answer is still `OperationResult`, and a caller that only
/// watches this stream has seen progress, not results.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProgressEvent {
    /// Total order across one profile. Numbers only grow; a jump means
    /// events were dropped, and a `Gap` says so explicitly.
    pub sequence: u64,
    pub operation: Operation,
    pub kind: ProgressKind,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ProgressKind {
    MessageQueued {
        group_id: Vec<u8>,
        event_id: Vec<u8>,
    },
    MessageReceived {
        group_id: Vec<u8>,
        event_id: Vec<u8>,
    },
    EnvelopesPublished {
        count: usize,
        pending: bool,
    },
    DeliveryChanged {
        delivery_id: Vec<u8>,
        state: String,
    },
    FileAnnounced {
        group_id: Vec<u8>,
        event_id: Vec<u8>,
        name: String,
        size: u64,
    },
    FileTransfer {
        name: String,
        offset: usize,
        total: Option<usize>,
    },
    FileSaved {
        name: String,
    },
    Synced {
        fetched: usize,
        new: usize,
        acked: usize,
    },
    PairingChanged {
        session_id: Vec<u8>,
        phase: String,
    },
    RelayUnavailable {
        pending: usize,
    },
    /// A step of enrollment or pairing, as it happens.
    Onboarding {
        step: String,
    },
    /// This subscriber fell behind and events were dropped. Read the state
    /// again rather than trusting what came before it.
    Gap {
        dropped: usize,
    },
}

/// How many events one subscriber may fall behind before they are dropped
/// and it is told to read the state again.
pub const WATCH_CAPACITY: usize = 256;

/// A live view of one profile's progress. Dropping it unsubscribes.
#[derive(Debug)]
pub struct Subscription {
    receiver: mpsc::Receiver<ProgressEvent>,
}

/// What waiting on a subscription found.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Waited {
    Event(ProgressEvent),
    /// Nothing arrived within the time allowed. The subscription is still
    /// live, which is how a reader stays free to stop watching.
    Idle,
    /// The profile closed and no event will ever arrive.
    Closed,
}

impl Subscription {
    /// Wait for the next event. `None` once the profile is closed.
    pub fn recv(&self) -> Option<ProgressEvent> {
        self.receiver.recv().ok()
    }

    /// Wait, but not forever. A reader that must also watch for its own
    /// cancellation needs to come up for air.
    pub fn wait(&self, timeout: std::time::Duration) -> Waited {
        match self.receiver.recv_timeout(timeout) {
            Ok(event) => Waited::Event(event),
            Err(mpsc::RecvTimeoutError::Timeout) => Waited::Idle,
            Err(mpsc::RecvTimeoutError::Disconnected) => Waited::Closed,
        }
    }

    /// Take an event if one is waiting.
    pub fn try_recv(&self) -> Option<ProgressEvent> {
        self.receiver.try_recv().ok()
    }
}

#[derive(Debug)]
struct Subscriber {
    sender: mpsc::SyncSender<ProgressEvent>,
    dropped: usize,
}

/// The profile's subscribers. Sending never blocks the executor: a
/// subscriber that cannot keep up loses events and is told how many.
#[derive(Debug, Default)]
struct Subscribers {
    inner: Mutex<Vec<Subscriber>>,
    sequence: AtomicU64,
}

impl Subscribers {
    fn subscribe(&self) -> Subscription {
        let (sender, receiver) = mpsc::sync_channel(WATCH_CAPACITY);
        self.inner
            .lock()
            .expect("subscriber registry poisoned")
            .push(Subscriber { sender, dropped: 0 });
        Subscription { receiver }
    }

    fn publish(&self, operation: Operation, change: &StateChange) {
        let Some(kind) = project(change) else {
            return;
        };
        let mut subscribers = self.inner.lock().expect("subscriber registry poisoned");
        if subscribers.is_empty() {
            return;
        }
        let sequence = self.sequence.fetch_add(1, Ordering::Relaxed);
        subscribers.retain_mut(|subscriber| {
            // A subscriber that lost events hears about the gap before it
            // hears anything newer.
            if subscriber.dropped > 0 {
                let gap = ProgressEvent {
                    sequence,
                    operation,
                    kind: ProgressKind::Gap {
                        dropped: subscriber.dropped,
                    },
                };
                match subscriber.sender.try_send(gap) {
                    Ok(()) => subscriber.dropped = 0,
                    Err(mpsc::TrySendError::Full(_)) => {
                        subscriber.dropped += 1;
                        return true;
                    }
                    Err(mpsc::TrySendError::Disconnected(_)) => return false,
                }
            }
            let event = ProgressEvent {
                sequence,
                operation,
                kind: kind.clone(),
            };
            match subscriber.sender.try_send(event) {
                Ok(()) => true,
                Err(mpsc::TrySendError::Full(_)) => {
                    subscriber.dropped += 1;
                    true
                }
                Err(mpsc::TrySendError::Disconnected(_)) => false,
            }
        });
    }
}

/// The projection itself. Everything absent from it is diagnosis, not
/// state: it stays in the durable result, where a caller reads it once the
/// operation answers.
fn project(change: &StateChange) -> Option<ProgressKind> {
    Some(match change {
        StateChange::MessageQueued { receipt, .. } => ProgressKind::MessageQueued {
            group_id: receipt.group_id.clone(),
            event_id: receipt.event_id.clone(),
        },
        StateChange::MessageReceived {
            group_id, event_id, ..
        } => ProgressKind::MessageReceived {
            group_id: group_id.clone(),
            event_id: event_id.clone(),
        },
        StateChange::EnvelopesPublished { count, pending } => ProgressKind::EnvelopesPublished {
            count: *count,
            pending: *pending,
        },
        StateChange::DeliveryChanged {
            delivery_id, state, ..
        } => ProgressKind::DeliveryChanged {
            delivery_id: delivery_id.clone(),
            state: match state {
                DeliveryStatus::Queued => "queued".into(),
                DeliveryStatus::Accepted { .. } => "accepted".into(),
                DeliveryStatus::Undeliverable { .. } => "undeliverable".into(),
            },
        },
        StateChange::FileAnnounced {
            group_id,
            event_id,
            name,
            size,
        } => ProgressKind::FileAnnounced {
            group_id: group_id.clone(),
            event_id: event_id.clone(),
            name: name.clone(),
            size: *size,
        },
        StateChange::UploadResumed {
            name,
            offset,
            total,
        } => ProgressKind::FileTransfer {
            name: name.clone(),
            offset: *offset,
            total: Some(*total),
        },
        StateChange::FileDownloadResumed { name, offset } => ProgressKind::FileTransfer {
            name: name.clone(),
            offset: *offset,
            total: None,
        },
        StateChange::FileSaved { name, .. } => ProgressKind::FileSaved { name: name.clone() },
        StateChange::SyncCompleted {
            fetched,
            new,
            acked,
        } => ProgressKind::Synced {
            fetched: *fetched,
            new: *new,
            acked: *acked,
        },
        StateChange::PairingCompletionChanged { session_id, phase } => {
            ProgressKind::PairingChanged {
                session_id: session_id.clone(),
                phase: format!("{phase:?}"),
            }
        }
        StateChange::PairingVerificationReady { session_id, .. } => ProgressKind::PairingChanged {
            session_id: session_id.clone(),
            phase: "verification-ready".into(),
        },
        StateChange::PairingGrantSent { session_id, .. } => ProgressKind::PairingChanged {
            session_id: session_id.clone(),
            phase: "grant-sent".into(),
        },
        StateChange::RelayUnavailable { pending, .. } => {
            ProgressKind::RelayUnavailable { pending: *pending }
        }
        StateChange::IdentityCreated { .. } => ProgressKind::Onboarding {
            step: "identity-created".into(),
        },
        StateChange::DevicePrepared { .. } => ProgressKind::Onboarding {
            step: "device-prepared".into(),
        },
        StateChange::EnrollmentAccepted { .. } => ProgressKind::Onboarding {
            step: "enrolled".into(),
        },
        StateChange::MailboxCreated { .. } => ProgressKind::Onboarding {
            step: "mailbox-created".into(),
        },
        StateChange::KeyPackagesPublished { .. } => ProgressKind::Onboarding {
            step: "key-packages-published".into(),
        },
        StateChange::DeviceLinked { .. } => ProgressKind::Onboarding {
            step: "device-linked".into(),
        },
        _ => return None,
    })
}

tokio::task_local! {
    static CHANGES: RefCell<Vec<StateChange>>;
    static MESSAGES: RefCell<Vec<MessageReceipt>>;
    /// The executor already knows which operation it is running, so one
    /// scope carries both. Every extra scope grows an already deep future.
    static WATCHERS: (Operation, Arc<Subscribers>);
}

fn record_change(change: StateChange) {
    // Progress is told to whoever is watching, and the durable result keeps
    // everything either way: a lost event never loses a fact.
    let _ = WATCHERS.try_with(|(operation, watchers)| watchers.publish(*operation, &change));
    CHANGES.with(|changes| changes.borrow_mut().push(change));
}

fn record_message(receipt: MessageReceipt, epoch: u64) {
    MESSAGES.with(|messages| messages.borrow_mut().push(receipt.clone()));
    record_change(StateChange::MessageQueued { receipt, epoch });
}

fn take_result() -> OperationResult {
    OperationResult {
        changes: CHANGES.with(|changes| std::mem::take(&mut *changes.borrow_mut())),
        messages: MESSAGES.with(|messages| std::mem::take(&mut *messages.borrow_mut())),
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ConversationSummary {
    pub group_id: Vec<u8>,
    pub creator: bool,
    pub peer_devices: usize,
    pub event_count: usize,
    pub last_event: Option<HistoryEvent>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PeerSummary {
    pub identity_id: Vec<u8>,
    pub device_id: Vec<u8>,
    pub label: String,
    pub own: bool,
    pub verified: bool,
    pub routable: bool,
    pub revoked: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeliveryState {
    pub mailbox_id: Vec<u8>,
    pub state: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HistoryEvent {
    /// Where this event sits in its conversation. Identifiers only grow, so
    /// a cursor stays valid however much arrives after it was taken.
    pub cursor: i64,
    pub event_id: Vec<u8>,
    pub kind: String,
    pub body: Vec<u8>,
    pub delivery_states: Vec<DeliveryState>,
}

/// One page of a conversation, newest first. `next` is the cursor for the
/// page before this one; its absence means the conversation starts here.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HistoryPage {
    pub group_id: Vec<u8>,
    pub events: Vec<HistoryEvent>,
    pub next: Option<i64>,
}

/// The largest page the application answers with, whatever is asked for. A
/// screen shows tens of rows, and a query that returns everything is how a
/// client ends up holding a whole database in memory.
pub const MAX_HISTORY_PAGE: usize = 200;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ConversationHistory {
    pub group_id: Vec<u8>,
    pub creator: Option<bool>,
    pub peers: Vec<PeerSummary>,
    pub events: Vec<HistoryEvent>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ServiceResult<T> {
    pub value: T,
    pub operation: OperationResult,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PairingCancellation {
    Cancelled,
    AlreadyCommitted,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum OnboardingOutput {
    Identity(Identity),
    Enrollment(Enrollment),
    LinkRequest(DeviceLinkRequest),
    LinkAuthorization(DeviceLinkAuthorization),
    LinkedDevice(LinkedDevice),
    PairingSession(PairingSession),
    PairingVerification(PairingVerification),
    PairingCancellation(PairingCancellation),
}

/// The typed output produced by a client command.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CommandOutput {
    Operation(OperationResult),
    Onboarding {
        value: OnboardingOutput,
        operation: OperationResult,
    },
    PendingPairing(Option<PairingVerification>),
    Conversations(Vec<ConversationSummary>),
    Peers(Vec<PeerSummary>),
    HistoryPage(HistoryPage),
    Archived(Vec<ConversationHistory>),
}

/// Everything a profile needs that used to arrive through the process
/// environment: where it lives, the key that opens it, and the transport and
/// expiry policies. A graphical client builds one explicitly and keeps its
/// key in the platform store; the command line translates its own variables
/// into one. This crate reads none of them itself.
#[derive(Clone)]
pub struct ProfileConfig {
    dir: PathBuf,
    key: Option<String>,
    tls_ca: Option<PathBuf>,
    envelope_ttl: Option<u64>,
    blob_ttl: Option<u64>,
    pairing_timeout: Option<u64>,
}

/// The key never reaches a log, an event or a panic message.
impl std::fmt::Debug for ProfileConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ProfileConfig")
            .field("dir", &self.dir)
            .field(
                "key",
                if self.key.is_some() {
                    &"<set>"
                } else {
                    &"<none>"
                },
            )
            .field("tls_ca", &self.tls_ca)
            .field("envelope_ttl", &self.envelope_ttl)
            .field("blob_ttl", &self.blob_ttl)
            .field("pairing_timeout", &self.pairing_timeout)
            .finish()
    }
}

impl ProfileConfig {
    /// A profile encrypted at rest, with 32 bytes as 64 hexadecimal
    /// characters. The shape is checked here so a caller hears about a bad
    /// key before anything is created, not from the storage layer after.
    pub fn encrypted(
        dir: impl Into<PathBuf>,
        key: impl Into<String>,
    ) -> Result<Self, ApplicationOpenError> {
        let key = key.into();
        if key.len() != 64 || !key.chars().all(|c| c.is_ascii_hexdigit()) {
            return Err(ApplicationOpenError::BadKey);
        }
        let mut config = Self::unencrypted(dir);
        config.key = Some(key);
        Ok(config)
    }

    /// A profile with nothing encrypting it at rest. Explicit on purpose: a
    /// graphical client must never arrive here by forgetting a key.
    pub fn unencrypted(dir: impl Into<PathBuf>) -> Self {
        Self {
            dir: dir.into(),
            key: None,
            tls_ca: None,
            envelope_ttl: None,
            blob_ttl: None,
            pairing_timeout: None,
        }
    }

    /// An extra PEM certificate authority for the carrier, beyond WebPKI
    /// roots, which is how a self-signed proxy is trusted in a test.
    pub fn with_tls_ca(mut self, path: impl Into<PathBuf>) -> Self {
        self.tls_ca = Some(path.into());
        self
    }

    /// Requested envelope expiry in seconds; the relay applies its own
    /// default when this is absent.
    pub fn with_envelope_ttl(mut self, seconds: u64) -> Self {
        self.envelope_ttl = Some(seconds);
        self
    }

    /// Requested blob expiry in seconds, on the same terms.
    pub fn with_blob_ttl(mut self, seconds: u64) -> Self {
        self.blob_ttl = Some(seconds);
        self
    }

    /// How long a pairing wait may block before it gives up.
    pub fn with_pairing_timeout(mut self, seconds: u64) -> Self {
        self.pairing_timeout = Some(seconds);
        self
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    pub fn is_encrypted(&self) -> bool {
        self.key.is_some()
    }

    pub(crate) fn key(&self) -> Option<&str> {
        self.key.as_deref()
    }

    pub(crate) fn tls_ca(&self) -> Option<&Path> {
        self.tls_ca.as_deref()
    }

    pub(crate) fn envelope_ttl(&self) -> Option<u64> {
        self.envelope_ttl
    }

    pub(crate) fn blob_ttl(&self) -> Option<u64> {
        self.blob_ttl
    }

    pub(crate) fn pairing_timeout(&self) -> Option<u64> {
        self.pairing_timeout
    }

    /// The registry keys on the canonical directory, so two spellings of one
    /// profile meet the same executor and the same lock.
    fn canonicalized(mut self) -> Result<Self, ApplicationOpenError> {
        self.dir = profile_path(self.dir)?;
        Ok(self)
    }
}

struct Request {
    command: ClientCommand,
    reply: mpsc::SyncSender<Result<CommandOutput, ApplicationError>>,
}

/// How much work one profile will hold at once. A sync in flight and one
/// waiting behind it is enough to keep the relay busy; more only grows a
/// queue nobody watches. Queries are cheap and answer from local state, so
/// they get room of their own and stay responsive while the rest waits.
const MAX_ACTIVE_SYNCS: usize = 2;
const MAX_ACTIVE_MUTATIONS: usize = 32;
const MAX_ACTIVE_QUERIES: usize = 128;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Admission {
    Sync,
    Mutation,
    Query,
}

impl ClientCommand {
    fn admission(&self) -> Admission {
        match self {
            Self::Sync { .. } => Admission::Sync,
            Self::QueryConversations
            | Self::QueryPeers { .. }
            | Self::QueryHistoryPage { .. }
            | Self::QueryArchived { .. }
            | Self::QueryPendingPairing => Admission::Query,
            _ => Admission::Mutation,
        }
    }
}

/// Counts what has been admitted and not yet finished, per kind.
#[derive(Debug, Default)]
struct Active {
    syncs: AtomicUsize,
    mutations: AtomicUsize,
    queries: AtomicUsize,
}

impl Active {
    fn counter(&self, admission: Admission) -> (&AtomicUsize, usize) {
        match admission {
            Admission::Sync => (&self.syncs, MAX_ACTIVE_SYNCS),
            Admission::Mutation => (&self.mutations, MAX_ACTIVE_MUTATIONS),
            Admission::Query => (&self.queries, MAX_ACTIVE_QUERIES),
        }
    }

    /// Take a slot, or report how many are already in flight. The count is
    /// only ever raised by the caller that holds the slot, so two callers
    /// cannot both squeeze past the limit.
    fn admit(&self, admission: Admission) -> Result<(), usize> {
        let (counter, limit) = self.counter(admission);
        let mut current = counter.load(Ordering::Acquire);
        loop {
            if current >= limit {
                return Err(current);
            }
            match counter.compare_exchange_weak(
                current,
                current + 1,
                Ordering::AcqRel,
                Ordering::Acquire,
            ) {
                Ok(_) => return Ok(()),
                Err(observed) => current = observed,
            }
        }
    }

    fn release(&self, admission: Admission) {
        self.counter(admission).0.fetch_sub(1, Ordering::AcqRel);
    }
}

/// One profile's state executor. Admission stops when the sender is taken,
/// and the worker holds the operating-system lock until its loop ends, so
/// the profile is never free while work of its own is still in flight.
#[derive(Debug)]
struct SerialExecutor {
    dir: PathBuf,
    sender: Mutex<Option<tokio::sync::mpsc::UnboundedSender<Request>>>,
    worker: Mutex<Option<std::thread::JoinHandle<()>>>,
    active: Arc<Active>,
    watchers: Arc<Subscribers>,
    /// Set once a command has panicked. Nothing else runs on this session
    /// afterwards: its state is only as good as what is durable on disk.
    poisoned: Arc<AtomicBool>,
}

impl SerialExecutor {
    /// Admit one command, or refuse it. The slot is released by the
    /// executor when the command finishes, so a refusal means work is
    /// genuinely in flight and not that a caller walked away.
    fn submit(&self, request: Request) -> Result<(), Refusal> {
        if self.poisoned.load(Ordering::Acquire) {
            return Err(Refusal::Panicked);
        }
        let admission = request.command.admission();
        self.active
            .admit(admission)
            .map_err(|active| Refusal::Saturated { active })?;
        let sent = match self
            .sender
            .lock()
            .expect("executor sender poisoned")
            .as_ref()
        {
            Some(sender) => sender.send(request).map_err(|_| ()),
            None => Err(()),
        };
        if sent.is_err() {
            self.active.release(admission);
            return Err(Refusal::Stopped);
        }
        Ok(())
    }

    /// Stop admission, wait for what is already running, and only then let
    /// the worker drop the lock. Idempotent: a second call finds nothing
    /// left to close.
    fn shutdown(&self) {
        self.sender.lock().expect("executor sender poisoned").take();
        let worker = self.worker.lock().expect("executor worker poisoned").take();
        if let Some(worker) = worker {
            mark_closing(&self.dir);
            let _ = worker.join();
            forget_session(&self.dir);
        }
    }
}

impl Drop for SerialExecutor {
    /// Abandoning the last handle closes the profile on the same terms as
    /// `close`, instead of releasing the lock while the worker still writes.
    fn drop(&mut self) {
        self.shutdown();
    }
}

/// Why a command was not accepted.
#[derive(Debug)]
enum Refusal {
    Stopped,
    Saturated {
        active: usize,
    },
    /// A command panicked, so this session is over. The profile is intact
    /// on disk; the way back is to close and open it again.
    Panicked,
}

#[derive(Debug)]
enum SessionSlot {
    Open(Weak<SerialExecutor>),
    Closing,
}

static SESSIONS: OnceLock<Mutex<HashMap<PathBuf, SessionSlot>>> = OnceLock::new();
static PROFILE_LOCKS: OnceLock<Mutex<HashMap<PathBuf, Weak<ProfileLock>>>> = OnceLock::new();

fn sessions() -> &'static Mutex<HashMap<PathBuf, SessionSlot>> {
    SESSIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn mark_closing(dir: &Path) {
    if let Some(slot) = sessions()
        .lock()
        .expect("session registry poisoned")
        .get_mut(dir)
    {
        *slot = SessionSlot::Closing;
    }
}

fn forget_session(dir: &Path) {
    sessions()
        .lock()
        .expect("session registry poisoned")
        .remove(dir);
}

#[derive(Debug)]
struct ProfileLock {
    _file: File,
}

/// Process-local handle to the operating-system lock for one canonical
/// profile. The CLI uses it around legacy commands that do not yet enter the
/// application executor.
#[derive(Debug)]
pub struct ProfileGuard {
    _lock: Arc<ProfileLock>,
}

#[derive(Debug, thiserror::Error)]
pub enum ApplicationOpenError {
    #[error("client profile {} is already in use by another process", path.display())]
    ProfileInUse { path: PathBuf },
    #[error("client profile {} is already open in this process", path.display())]
    AlreadyOpen { path: PathBuf },
    #[error("client profile {} is closing", path.display())]
    Closing { path: PathBuf },
    #[error("the profile key must be 32 bytes as 64 hexadecimal characters")]
    BadKey,
    #[error("cannot open client profile {}: {source}", path.display())]
    Unusable {
        path: PathBuf,
        #[source]
        source: CliError,
    },
    #[error("cannot {action} client profile {}: {source}", path.display())]
    Io {
        action: &'static str,
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
}

impl ProfileGuard {
    pub fn acquire(path: impl Into<PathBuf>) -> Result<Self, ApplicationOpenError> {
        let path = profile_path(path.into())?;
        Ok(Self {
            _lock: profile_lock(path)?,
        })
    }
}

fn profile_path(path: PathBuf) -> Result<PathBuf, ApplicationOpenError> {
    std::fs::create_dir_all(&path).map_err(|source| ApplicationOpenError::Io {
        action: "create",
        path: path.clone(),
        source,
    })?;
    path.canonicalize()
        .map_err(|source| ApplicationOpenError::Io {
            action: "canonicalize",
            path,
            source,
        })
}

fn profile_lock(path: PathBuf) -> Result<Arc<ProfileLock>, ApplicationOpenError> {
    let locks = PROFILE_LOCKS.get_or_init(|| Mutex::new(HashMap::new()));
    let mut locks = locks.lock().expect("profile lock registry poisoned");
    locks.retain(|_, lock| lock.strong_count() > 0);
    if let Some(lock) = locks.get(&path).and_then(Weak::upgrade) {
        return Ok(lock);
    }

    let lock_path = path.join(".arveil-profile.lock");
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(&lock_path)
        .map_err(|source| ApplicationOpenError::Io {
            action: "open lock for",
            path: path.clone(),
            source,
        })?;
    match file.try_lock() {
        Ok(()) => {}
        Err(TryLockError::WouldBlock) => {
            return Err(ApplicationOpenError::ProfileInUse { path });
        }
        Err(TryLockError::Error(source)) => {
            return Err(ApplicationOpenError::Io {
                action: "lock",
                path,
                source,
            });
        }
    }
    let lock = Arc::new(ProfileLock { _file: file });
    locks.insert(path, Arc::downgrade(&lock));
    Ok(lock)
}

type CommandFuture = Pin<Box<dyn Future<Output = ()> + 'static>>;

fn command_future(
    config: Arc<ProfileConfig>,
    sync_lock: Rc<tokio::sync::Mutex<()>>,
    link_completion_lock: Rc<tokio::sync::Mutex<()>>,
    active: Arc<Active>,
    watchers: Arc<Subscribers>,
    poisoned: Arc<AtomicBool>,
    request: Request,
) -> CommandFuture {
    Box::pin(async move {
        let Request { command, reply } = request;
        let admission = command.admission();
        let operation = command.operation();
        // Whatever was queued behind a panic is answered, not dropped: a
        // caller waiting on a reply hears why instead of waiting forever.
        if poisoned.load(Ordering::Acquire) {
            let _ = reply.send(Err(ApplicationError::Panicked { operation }));
            return;
        }
        let watched = WATCHERS.scope((operation, watchers), async move {
            if matches!(&command, ClientCommand::Sync { .. }) {
                // A second sync waits cooperatively here: network waits from the
                // active sync still yield to queries and non-sync commands.
                let _single_flight = sync_lock.lock().await;
                run_command(&config, command).await
            } else if matches!(
                &command,
                ClientCommand::CompleteLink { .. } | ClientCommand::ConfirmPairing { .. }
            ) {
                // Linking may wait on the relay between durable local phases.
                // Only one finalizer may cross those phases for this profile;
                // followers resume from the phase written by their predecessor.
                let _single_finalizer = link_completion_lock.lock().await;
                run_command(&config, command).await
            } else {
                run_command(&config, command).await
            }
        });
        // A panic may leave the connection or the MLS engine in a state
        // nobody described, so the session ends here and the profile is
        // read again from disk the next time it is opened. The reply is
        // sent from out here, where the panic cannot take it with it.
        let result = match std::panic::AssertUnwindSafe(watched).catch_unwind().await {
            Ok(result) => result,
            Err(_) => {
                poisoned.store(true, Ordering::Release);
                Err(ApplicationError::Panicked { operation })
            }
        };
        let _ = reply.send(result);
        // The slot is only free once the work is done, not when a caller
        // stops waiting for it.
        active.release(admission);
    })
}

async fn run_executor(
    config: Arc<ProfileConfig>,
    mut receiver: tokio::sync::mpsc::UnboundedReceiver<Request>,
    active: Arc<Active>,
    watchers: Arc<Subscribers>,
    poisoned: Arc<AtomicBool>,
) {
    let mut running = FuturesUnordered::<CommandFuture>::new();
    let sync_lock = Rc::new(tokio::sync::Mutex::new(()));
    let link_completion_lock = Rc::new(tokio::sync::Mutex::new(()));
    let mut accepting = true;
    while accepting || !running.is_empty() {
        if running.is_empty() {
            match receiver.recv().await {
                Some(request) => running.push(command_future(
                    config.clone(),
                    sync_lock.clone(),
                    link_completion_lock.clone(),
                    active.clone(),
                    watchers.clone(),
                    poisoned.clone(),
                    request,
                )),
                None => accepting = false,
            }
        } else if accepting {
            tokio::select! {
                request = receiver.recv() => match request {
                    Some(request) => running.push(command_future(
                        config.clone(),
                        sync_lock.clone(),
                        link_completion_lock.clone(),
                        active.clone(),
                        watchers.clone(),
                        poisoned.clone(),
                        request,
                    )),
                    None => accepting = false,
                },
                _ = running.next() => {}
            }
        } else {
            running.next().await;
        }
    }
}

fn executor_for(config: ProfileConfig) -> Result<Arc<SerialExecutor>, ApplicationOpenError> {
    let config = config.canonicalized()?;
    let dir = config.dir().to_path_buf();
    let mut sessions = sessions().lock().expect("session registry poisoned");
    match sessions.get(&dir) {
        Some(SessionSlot::Closing) => return Err(ApplicationOpenError::Closing { path: dir }),
        // Never upgrade the weak handle here: dropping that strong reference
        // under this lock would re-enter the registry through `Drop`.
        Some(SessionSlot::Open(executor)) if executor.strong_count() > 0 => {
            return Err(ApplicationOpenError::AlreadyOpen { path: dir });
        }
        _ => {}
    }

    let profile_lock = profile_lock(dir.clone())?;
    // Opening the database here is what makes a wrong or absent key a failure
    // of `open`, before any handle exists to hand a caller.
    open_client(&config).map_err(|source| ApplicationOpenError::Unusable {
        path: dir.clone(),
        source,
    })?;

    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|source| ApplicationOpenError::Io {
            action: "start executor for",
            path: dir.clone(),
            source,
        })?;
    let (sender, receiver) = tokio::sync::mpsc::unbounded_channel::<Request>();
    let active = Arc::new(Active::default());
    let worker_active = active.clone();
    let watchers = Arc::new(Subscribers::default());
    let worker_watchers = watchers.clone();
    let poisoned = Arc::new(AtomicBool::new(false));
    let worker_poisoned = poisoned.clone();
    let worker = std::thread::Builder::new()
        .name("arveil-client-state".into())
        .stack_size(8 * 1024 * 1024)
        .spawn(move || {
            // The lock belongs to the worker, so it outlives every command
            // this executor still has to finish.
            let _profile_lock = profile_lock;
            runtime.block_on(run_executor(
                Arc::new(config),
                receiver,
                worker_active,
                worker_watchers,
                worker_poisoned,
            ));
        })
        .map_err(|source| ApplicationOpenError::Io {
            action: "start executor for",
            path: dir.clone(),
            source,
        })?;
    let executor = Arc::new(SerialExecutor {
        dir: dir.clone(),
        sender: Mutex::new(Some(sender)),
        worker: Mutex::new(Some(worker)),
        active,
        watchers,
        poisoned,
    });
    sessions.insert(dir, SessionSlot::Open(Arc::downgrade(&executor)));
    Ok(executor)
}

/// Reusable application facade. Every handle for the same profile shares one
/// serial executor; only that executor opens and mutates the client, MLS and
/// delivery state. It owns no presentation state. The registry is process
/// local. An operating-system lock rejects a second process before it can
/// open the same profile state.
#[derive(Clone, Debug)]
pub struct Application {
    executor: Arc<SerialExecutor>,
}

impl Application {
    /// Open one session over a profile. A second independent open of the
    /// same canonical directory is refused with `AlreadyOpen`, even when it
    /// carries another key or policy; sharing is explicit, by cloning this
    /// handle.
    pub fn open(config: ProfileConfig) -> Result<Self, ApplicationOpenError> {
        Ok(Self {
            executor: executor_for(config)?,
        })
    }

    /// Watch this profile's progress while operations run. Bounded: a
    /// subscriber that falls behind loses events and is told how many, so
    /// it reads the state again instead of believing it saw everything.
    /// Dropping the subscription unsubscribes.
    pub fn watch(&self) -> Subscription {
        self.executor.watchers.subscribe()
    }

    /// Stop admitting work, wait for what is running and release the
    /// profile. Idempotent, and shared by every clone: afterwards a command
    /// fails with a typed error instead of reopening anything.
    pub fn close(&self) {
        self.executor.shutdown();
    }

    /// Submit a typed command to this profile's serial state executor.
    pub fn execute(&self, command: ClientCommand) -> Result<CommandOutput, ApplicationError> {
        let operation = command.operation();
        let (reply, result) = mpsc::sync_channel(1);
        self.executor
            .submit(Request { command, reply })
            .map_err(|refusal| match refusal {
                Refusal::Stopped => executor_stopped(operation),
                Refusal::Saturated { active } => ApplicationError::Busy { operation, active },
                Refusal::Panicked => ApplicationError::Panicked { operation },
            })?;
        result.recv().map_err(|_| executor_stopped(operation))?
    }

    pub fn create_identity(&self) -> Result<ServiceResult<Identity>, ApplicationError> {
        self.onboarding(ClientCommand::CreateIdentity, |value| match value {
            OnboardingOutput::Identity(identity) => identity,
            _ => unreachable!("identity command returned another output type"),
        })
    }

    pub fn enroll(
        &self,
        bootstrap: &str,
        invite: &str,
    ) -> Result<ServiceResult<Enrollment>, ApplicationError> {
        self.onboarding(
            ClientCommand::Enroll {
                bootstrap: bootstrap.into(),
                invite: invite.into(),
            },
            |value| match value {
                OnboardingOutput::Enrollment(enrollment) => enrollment,
                _ => unreachable!("enrollment command returned another output type"),
            },
        )
    }

    pub fn create_link_request(
        &self,
    ) -> Result<ServiceResult<DeviceLinkRequest>, ApplicationError> {
        self.onboarding(ClientCommand::CreateLinkRequest, |value| match value {
            OnboardingOutput::LinkRequest(request) => request,
            _ => unreachable!("link request command returned another output type"),
        })
    }

    pub fn authorize_link(
        &self,
        bootstrap: &str,
        request: &str,
    ) -> Result<ServiceResult<DeviceLinkAuthorization>, ApplicationError> {
        self.onboarding(
            ClientCommand::AuthorizeLink {
                bootstrap: bootstrap.into(),
                request: request.into(),
            },
            |value| match value {
                OnboardingOutput::LinkAuthorization(authorization) => authorization,
                _ => unreachable!("link authorization returned another output type"),
            },
        )
    }

    pub fn complete_link(
        &self,
        bootstrap: &str,
        grant: &str,
    ) -> Result<ServiceResult<LinkedDevice>, ApplicationError> {
        self.onboarding(
            ClientCommand::CompleteLink {
                bootstrap: bootstrap.into(),
                grant: grant.into(),
            },
            |value| match value {
                OnboardingOutput::LinkedDevice(device) => device,
                _ => unreachable!("link completion returned another output type"),
            },
        )
    }

    pub fn begin_pairing(
        &self,
        bootstrap: &str,
    ) -> Result<ServiceResult<PairingSession>, ApplicationError> {
        self.onboarding(
            ClientCommand::BeginPairing {
                bootstrap: bootstrap.into(),
            },
            |value| match value {
                OnboardingOutput::PairingSession(session) => session,
                _ => unreachable!("pairing start returned another output type"),
            },
        )
    }

    pub fn await_pairing(
        &self,
        bootstrap: &str,
        session: PairingSession,
    ) -> Result<ServiceResult<PairingVerification>, ApplicationError> {
        self.onboarding(
            ClientCommand::AwaitPairing {
                bootstrap: bootstrap.into(),
                session,
            },
            |value| match value {
                OnboardingOutput::PairingVerification(verification) => verification,
                _ => unreachable!("pairing wait returned another output type"),
            },
        )
    }

    pub fn approve_pairing(
        &self,
        bootstrap: &str,
        code: &str,
    ) -> Result<ServiceResult<PairingVerification>, ApplicationError> {
        self.onboarding(
            ClientCommand::ApprovePairing {
                bootstrap: bootstrap.into(),
                code: code.into(),
            },
            |value| match value {
                OnboardingOutput::PairingVerification(verification) => verification,
                _ => unreachable!("pairing approval returned another output type"),
            },
        )
    }

    pub fn confirm_pairing(
        &self,
        bootstrap: &str,
        session_id: &[u8],
        verification_code: &str,
    ) -> Result<ServiceResult<LinkedDevice>, ApplicationError> {
        self.onboarding(
            ClientCommand::ConfirmPairing {
                bootstrap: bootstrap.into(),
                session_id: session_id.into(),
                verification_code: verification_code.into(),
            },
            |value| match value {
                OnboardingOutput::LinkedDevice(device) => device,
                _ => unreachable!("pairing confirmation returned another output type"),
            },
        )
    }

    pub fn cancel_pairing(
        &self,
        session_id: &[u8],
    ) -> Result<ServiceResult<PairingCancellation>, ApplicationError> {
        self.onboarding(
            ClientCommand::CancelPairing {
                session_id: session_id.into(),
            },
            |value| match value {
                OnboardingOutput::PairingCancellation(outcome) => outcome,
                _ => unreachable!("pairing cancellation returned another output type"),
            },
        )
    }

    pub fn pending_pairing(&self) -> Result<Option<PairingVerification>, ApplicationError> {
        match self.execute(ClientCommand::QueryPendingPairing)? {
            CommandOutput::PendingPairing(pairing) => Ok(pairing),
            _ => unreachable!("pending pairing query returned another output type"),
        }
    }

    pub fn create_conversation(
        &self,
        bootstrap: &str,
        peer_routes: &[&str],
    ) -> Result<OperationResult, ApplicationError> {
        self.operation(ClientCommand::CreateConversation {
            bootstrap: bootstrap.into(),
            peer_routes: peer_routes.iter().map(|route| (*route).into()).collect(),
        })
    }

    pub fn add_device(
        &self,
        bootstrap: &str,
        peer_route: &str,
        group: Option<&str>,
    ) -> Result<OperationResult, ApplicationError> {
        self.operation(ClientCommand::AddDevice {
            bootstrap: bootstrap.into(),
            peer_route: peer_route.into(),
            group: group.map(Into::into),
        })
    }

    pub fn remove_device(
        &self,
        bootstrap: &str,
        device_id: &str,
        group: Option<&str>,
    ) -> Result<OperationResult, ApplicationError> {
        self.operation(ClientCommand::RemoveDevice {
            bootstrap: bootstrap.into(),
            device_id: device_id.into(),
            group: group.map(Into::into),
        })
    }

    pub fn send_message(
        &self,
        bootstrap: &str,
        text: &str,
        group: Option<&str>,
    ) -> Result<OperationResult, ApplicationError> {
        self.operation(ClientCommand::SendMessage {
            bootstrap: bootstrap.into(),
            text: text.into(),
            group: group.map(Into::into),
        })
    }

    pub fn send_file(
        &self,
        bootstrap: &str,
        path: &Path,
        group: Option<&str>,
    ) -> Result<OperationResult, ApplicationError> {
        self.operation(ClientCommand::SendFile {
            bootstrap: bootstrap.into(),
            path: path.into(),
            group: group.map(Into::into),
        })
    }

    pub fn sync(&self, bootstrap: &str) -> Result<OperationResult, ApplicationError> {
        self.operation(ClientCommand::Sync {
            bootstrap: bootstrap.into(),
        })
    }

    pub fn revoke_device(
        &self,
        bootstrap: &str,
        device_id: &str,
    ) -> Result<OperationResult, ApplicationError> {
        self.operation(ClientCommand::RevokeDevice {
            bootstrap: bootstrap.into(),
            device_id: device_id.into(),
        })
    }

    pub fn conversations(&self) -> Result<Vec<ConversationSummary>, ApplicationError> {
        match self.execute(ClientCommand::QueryConversations)? {
            CommandOutput::Conversations(conversations) => Ok(conversations),
            _ => unreachable!("conversation command returned another output type"),
        }
    }

    /// The peers of one conversation, with the labels a screen shows.
    pub fn peers(&self, group: &[u8]) -> Result<Vec<PeerSummary>, ApplicationError> {
        match self.execute(ClientCommand::QueryPeers {
            group: group.to_vec(),
        })? {
            CommandOutput::Peers(peers) => Ok(peers),
            _ => unreachable!("peer command returned another output type"),
        }
    }

    /// One page of a conversation, newest first. Pass the previous page's
    /// `next` as `before` to continue backwards.
    pub fn history_page(
        &self,
        group: &[u8],
        before: Option<i64>,
        limit: usize,
    ) -> Result<HistoryPage, ApplicationError> {
        match self.execute(ClientCommand::QueryHistoryPage {
            group: group.to_vec(),
            before,
            limit,
        })? {
            CommandOutput::HistoryPage(page) => Ok(page),
            _ => unreachable!("history command returned another output type"),
        }
    }

    /// Imported records. Without a group this is the conversations that
    /// exist only as an import; with one it is that conversation's records,
    /// which may also have a live conversation of its own.
    pub fn archived(
        &self,
        group: Option<&[u8]>,
    ) -> Result<Vec<ConversationHistory>, ApplicationError> {
        match self.execute(ClientCommand::QueryArchived {
            group: group.map(<[u8]>::to_vec),
        })? {
            CommandOutput::Archived(archived) => Ok(archived),
            _ => unreachable!("archive command returned another output type"),
        }
    }

    /// Everything, assembled from bounded pages. The command line wants the
    /// whole history; a screen should page instead of calling this.
    pub fn history(&self) -> Result<Vec<ConversationHistory>, ApplicationError> {
        let mut archived = self.archived(None)?;
        let mut live = Vec::new();
        for conversation in self.conversations()? {
            let peers = self.peers(&conversation.group_id)?;
            // An imported record of a conversation that still exists
            // belongs inside it, ahead of what arrived since.
            let mut events = self
                .archived(Some(&conversation.group_id))?
                .into_iter()
                .flat_map(|entry| entry.events)
                .collect::<Vec<_>>();
            // Imported records stay ahead of everything that follows.
            let imported = events.len();
            let mut before = None;
            loop {
                let page = self.history_page(&conversation.group_id, before, MAX_HISTORY_PAGE)?;
                let empty = page.events.is_empty();
                // Pages arrive newest first, so each one goes ahead of what
                // was read before it and behind the imported records.
                events.splice(imported..imported, page.events);
                before = page.next;
                if before.is_none() || empty {
                    break;
                }
            }
            live.push(ConversationHistory {
                group_id: conversation.group_id,
                creator: Some(conversation.creator),
                peers,
                events,
            });
        }
        // Conversations that exist only as an import keep their own entry.
        archived.extend(live);
        Ok(archived)
    }

    fn operation(&self, command: ClientCommand) -> Result<OperationResult, ApplicationError> {
        match self.execute(command)? {
            CommandOutput::Operation(result) => Ok(result),
            _ => unreachable!("mutation command returned a query output"),
        }
    }

    fn onboarding<T>(
        &self,
        command: ClientCommand,
        extract: impl FnOnce(OnboardingOutput) -> T,
    ) -> Result<ServiceResult<T>, ApplicationError> {
        match self.execute(command)? {
            CommandOutput::Onboarding { value, operation } => Ok(ServiceResult {
                value: extract(value),
                operation,
            }),
            _ => unreachable!("onboarding command returned another output category"),
        }
    }
}

async fn run_command(
    config: &ProfileConfig,
    command: ClientCommand,
) -> Result<CommandOutput, ApplicationError> {
    match command {
        ClientCommand::CreateIdentity => {
            onboarding_command(
                Operation::CreateIdentity,
                onboarding::create_identity(config),
                OnboardingOutput::Identity,
            )
            .await
        }
        ClientCommand::Enroll { bootstrap, invite } => {
            onboarding_command(
                Operation::Enroll,
                onboarding::enroll(config, &bootstrap, &invite),
                OnboardingOutput::Enrollment,
            )
            .await
        }
        ClientCommand::CreateLinkRequest => {
            onboarding_command(
                Operation::CreateLinkRequest,
                onboarding::create_link_request(config),
                OnboardingOutput::LinkRequest,
            )
            .await
        }
        ClientCommand::AuthorizeLink { bootstrap, request } => {
            onboarding_command(
                Operation::AuthorizeLink,
                onboarding::authorize_link(config, &bootstrap, &request),
                OnboardingOutput::LinkAuthorization,
            )
            .await
        }
        ClientCommand::CompleteLink { bootstrap, grant } => {
            onboarding_command(
                Operation::CompleteLink,
                onboarding::complete_link(config, &bootstrap, &grant),
                OnboardingOutput::LinkedDevice,
            )
            .await
        }
        ClientCommand::BeginPairing { bootstrap } => {
            onboarding_command(
                Operation::BeginPairing,
                onboarding::begin_pairing(config, &bootstrap),
                OnboardingOutput::PairingSession,
            )
            .await
        }
        ClientCommand::AwaitPairing { bootstrap, session } => {
            onboarding_command(
                Operation::AwaitPairing,
                onboarding::await_pairing(config, &bootstrap, session),
                OnboardingOutput::PairingVerification,
            )
            .await
        }
        ClientCommand::ApprovePairing { bootstrap, code } => {
            onboarding_command(
                Operation::ApprovePairing,
                onboarding::approve_pairing(config, &bootstrap, &code),
                OnboardingOutput::PairingVerification,
            )
            .await
        }
        ClientCommand::ConfirmPairing {
            bootstrap,
            session_id,
            verification_code,
        } => {
            onboarding_command(
                Operation::ConfirmPairing,
                onboarding::confirm_pairing(config, &bootstrap, &session_id, &verification_code),
                OnboardingOutput::LinkedDevice,
            )
            .await
        }
        ClientCommand::CancelPairing { session_id } => {
            onboarding_command(
                Operation::CancelPairing,
                onboarding::cancel_pairing(config, &session_id),
                OnboardingOutput::PairingCancellation,
            )
            .await
        }
        ClientCommand::QueryPendingPairing => onboarding::pending_pairing(config)
            .map(CommandOutput::PendingPairing)
            .map_err(|source| application_error(Operation::QueryPendingPairing, source)),
        ClientCommand::CreateConversation {
            bootstrap,
            peer_routes,
        } => {
            let routes = peer_routes.iter().map(String::as_str).collect::<Vec<_>>();
            run_operation(
                Operation::CreateConversation,
                start(config, &bootstrap, &routes),
            )
            .await
            .map(CommandOutput::Operation)
        }
        ClientCommand::AddDevice {
            bootstrap,
            peer_route,
            group,
        } => run_operation(
            Operation::AddDevice,
            add(config, &bootstrap, &peer_route, group.as_deref()),
        )
        .await
        .map(CommandOutput::Operation),
        ClientCommand::RemoveDevice {
            bootstrap,
            device_id,
            group,
        } => run_operation(
            Operation::RemoveDevice,
            remove(config, &bootstrap, &device_id, group.as_deref()),
        )
        .await
        .map(CommandOutput::Operation),
        ClientCommand::SendMessage {
            bootstrap,
            text,
            group,
        } => run_operation(
            Operation::SendMessage,
            send(config, &bootstrap, &text, group.as_deref()),
        )
        .await
        .map(CommandOutput::Operation),
        ClientCommand::SendFile {
            bootstrap,
            path,
            group,
        } => run_operation(
            Operation::SendFile,
            send_file(config, &bootstrap, &path, group.as_deref()),
        )
        .await
        .map(CommandOutput::Operation),
        ClientCommand::Sync { bootstrap } => {
            run_operation(Operation::Sync, sync(config, &bootstrap))
                .await
                .map(CommandOutput::Operation)
        }
        ClientCommand::RevokeDevice {
            bootstrap,
            device_id,
        } => run_operation(
            Operation::RevokeDevice,
            revoke(config, &bootstrap, &device_id),
        )
        .await
        .map(CommandOutput::Operation),
        ClientCommand::QueryConversations => conversation_summaries(config)
            .map(CommandOutput::Conversations)
            .map_err(|source| application_error(Operation::QueryConversations, source)),
        ClientCommand::QueryPeers { group } => conversation_peers(config, &group)
            .map(CommandOutput::Peers)
            .map_err(|source| application_error(Operation::QueryPeers, source)),
        ClientCommand::QueryHistoryPage {
            group,
            before,
            limit,
        } => history_page(config, &group, before, limit)
            .map(CommandOutput::HistoryPage)
            .map_err(|source| application_error(Operation::QueryHistoryPage, source)),
        #[cfg(test)]
        ClientCommand::PanicProbe => {
            let conn = SharedConn::open_file_keyed(&config.dir().join("client.db"), config.key())
                .expect("the probe opens the profile");
            let _: Result<(), rusqlite::Error> = conn.unit_of_work(|c| {
                c.lock().execute(
                    "INSERT INTO events (group_id, event_id, kind, body)
                     VALUES (x'70', x'71', 'message', x'72')",
                    [],
                )?;
                panic!("a command gave up half way");
            });
            unreachable!("the probe always panics")
        }
        ClientCommand::QueryArchived { group } => archived_conversations(config, group.as_deref())
            .map(CommandOutput::Archived)
            .map_err(|source| application_error(Operation::QueryArchived, source)),
    }
}

async fn onboarding_command<T>(
    operation: Operation,
    action: impl Future<Output = Result<T, CliError>>,
    output: impl FnOnce(T) -> OnboardingOutput,
) -> Result<CommandOutput, ApplicationError> {
    run_operation_with_value(operation, action)
        .await
        .map(|(value, operation)| CommandOutput::Onboarding {
            value: output(value),
            operation,
        })
}

async fn run_operation(
    operation: Operation,
    action: impl Future<Output = Result<(), CliError>>,
) -> Result<OperationResult, ApplicationError> {
    run_operation_with_value(operation, action)
        .await
        .map(|(_, result)| result)
}

async fn run_operation_with_value<T>(
    operation: Operation,
    action: impl Future<Output = Result<T, CliError>>,
) -> Result<(T, OperationResult), ApplicationError> {
    CHANGES
        .scope(RefCell::new(Vec::new()), async move {
            MESSAGES
                .scope(RefCell::new(Vec::new()), async move {
                    match action.await {
                        Ok(value) => Ok((value, take_result())),
                        Err(source) => {
                            let partial = take_result();
                            let source = match source {
                                CliError::Interrupted { exit_code, message } => {
                                    return Err(ApplicationError::Interrupted {
                                        exit_code,
                                        message,
                                        partial,
                                    });
                                }
                                source => source,
                            };
                            Err(classified_error(operation, source, partial))
                        }
                    }
                })
                .await
        })
        .await
}

fn executor_stopped(operation: Operation) -> ApplicationError {
    ApplicationError::Internal {
        operation,
        source: CliError::Internal("client state executor stopped".into()),
        partial: OperationResult::default(),
    }
}

fn application_error(operation: Operation, source: CliError) -> ApplicationError {
    classified_error(operation, source, OperationResult::default())
}

fn classified_error(
    operation: Operation,
    source: CliError,
    partial: OperationResult,
) -> ApplicationError {
    match source.kind() {
        FailureKind::Transport => ApplicationError::Transport {
            operation,
            source,
            partial,
        },
        FailureKind::Storage => ApplicationError::Storage {
            operation,
            source,
            partial,
        },
        FailureKind::Protocol => ApplicationError::Protocol {
            operation,
            source,
            partial,
        },
        FailureKind::Domain => ApplicationError::Domain {
            operation,
            source,
            partial,
        },
        FailureKind::FileSystem => ApplicationError::FileSystem {
            operation,
            source,
            partial,
        },
        FailureKind::Internal => ApplicationError::Internal {
            operation,
            source,
            partial,
        },
    }
}

fn conversation_summaries(config: &ProfileConfig) -> Result<Vec<ConversationSummary>, CliError> {
    let session = local(config)?;
    session
        .client
        .conversations()
        .map_err(storage_error("conversations"))?
        .into_iter()
        .map(|conversation| {
            // A summary needs the count and the newest row, not every body
            // in the conversation.
            let event_count = session
                .delivery
                .events_count(&conversation.group_id)
                .map_err(storage_error("events"))?;
            let last_event = session
                .delivery
                .events_page(&conversation.group_id, None, 1)
                .map_err(storage_error("events"))?
                .into_iter()
                .next()
                .map(|(cursor, event_id, kind, body)| HistoryEvent {
                    cursor,
                    event_id,
                    kind,
                    body,
                    delivery_states: Vec::new(),
                });
            Ok(ConversationSummary {
                group_id: conversation.group_id,
                creator: conversation.creator,
                peer_devices: conversation.peers.len(),
                event_count,
                last_event,
            })
        })
        .collect()
}

/// What a query needs: the local store, and the identity if this profile
/// has one yet. Reading history does not require an enrolled realm.
struct LocalRead {
    client: Client,
    delivery: Delivery,
    identity_id: Option<Vec<u8>>,
}

fn local(config: &ProfileConfig) -> Result<LocalRead, CliError> {
    let client = open_client(config)?;
    let delivery = client.delivery().map_err(storage_error("delivery"))?;
    let identity_id = client.identity_id().map_err(storage_error("identity"))?;
    Ok(LocalRead {
        client,
        delivery,
        identity_id,
    })
}

/// The peers of one conversation, with the label a screen shows.
fn conversation_peers(config: &ProfileConfig, group: &[u8]) -> Result<Vec<PeerSummary>, CliError> {
    let session = local(config)?;
    let conversation = session
        .client
        .conversations()
        .map_err(storage_error("conversations"))?
        .into_iter()
        .find(|conversation| conversation.group_id == group)
        .ok_or_else(|| CliError::Domain("no such conversation".into()))?;
    conversation
        .peers
        .iter()
        .map(|peer| {
            let contact = session
                .client
                .contact(&peer.identity)
                .map_err(storage_error("contact"))?;
            Ok(PeerSummary {
                identity_id: peer.identity.clone(),
                device_id: peer.device_id.clone(),
                label: contact.as_ref().map_or_else(
                    || hex::encode(&peer.identity[..4]),
                    |contact| contact.label(),
                ),
                own: Some(&peer.identity) == session.identity_id.as_ref(),
                verified: contact.is_some_and(|contact| contact.verified),
                routable: peer.routable(),
                revoked: peer.revoked,
            })
        })
        .collect()
}

/// One page of a conversation, newest first and never larger than
/// `MAX_HISTORY_PAGE`, whatever the caller asked for.
fn history_page(
    config: &ProfileConfig,
    group: &[u8],
    before: Option<i64>,
    limit: usize,
) -> Result<HistoryPage, CliError> {
    let session = local(config)?;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or(0);
    let limit = limit.clamp(1, MAX_HISTORY_PAGE);
    // One row beyond the page tells us whether an older one exists without
    // a second query, and without claiming there is more when there is not.
    let mut rows = session
        .delivery
        .events_page(group, before, limit + 1)
        .map_err(storage_error("events"))?;
    let next = if rows.len() > limit {
        rows.truncate(limit);
        rows.last().map(|(cursor, ..)| *cursor)
    } else {
        None
    };

    let mut events = Vec::with_capacity(rows.len());
    for (cursor, event_id, kind, body) in rows.into_iter().rev() {
        let delivery_states = if kind == "sent" {
            session
                .delivery
                .states_for_event(&event_id, now)
                .map_err(storage_error("states"))?
                .into_iter()
                .map(|(mailbox_id, state)| DeliveryState { mailbox_id, state })
                .collect()
        } else {
            Vec::new()
        };
        events.push(HistoryEvent {
            cursor,
            event_id,
            kind,
            body,
            delivery_states,
        });
    }
    Ok(HistoryPage {
        group_id: group.to_vec(),
        events,
        next,
    })
}

/// Imported conversations. They carry no MLS state and cannot grow, so
/// they are read whole rather than paged.
fn archived_conversations(
    config: &ProfileConfig,
    group: Option<&[u8]>,
) -> Result<Vec<ConversationHistory>, CliError> {
    let session = local(config)?;
    let groups = match group {
        Some(group) => vec![group.to_vec()],
        // Without a group, only the conversations that exist as an import;
        // a live one carries its records inside itself.
        None => session
            .client
            .archived_groups()
            .map_err(storage_error("archived"))?,
    };
    groups
        .into_iter()
        .map(|group_id| {
            let events = session
                .client
                .archived(&group_id)
                .map_err(storage_error("archived"))?
                .into_iter()
                .map(|(kind, body)| HistoryEvent {
                    cursor: 0,
                    event_id: Vec::new(),
                    kind: format!("archived-{kind}"),
                    body,
                    delivery_states: Vec::new(),
                })
                .collect();
            Ok(ConversationHistory {
                group_id,
                creator: None,
                peers: Vec::new(),
                events,
            })
        })
        .collect()
}

fn open_client(config: &ProfileConfig) -> Result<Client, CliError> {
    std::fs::create_dir_all(config.dir()).map_err(filesystem_error("data dir"))?;
    let conn = SharedConn::open_file_keyed(&config.dir().join("client.db"), config.key())
        .map_err(storage_error("storage"))?;
    Client::open(conn).map_err(storage_error("client"))
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Route {
    pub identity_id: Vec<u8>,
    pub device_id: Vec<u8>,
    pub credential_hash: Vec<u8>,
    pub root_public: Vec<u8>,
    pub mailbox_id: Vec<u8>,
    pub write_capability: Vec<u8>,
    pub hpke_public: Vec<u8>,
}

pub fn parse_route(value: &str) -> Result<Route, CliError> {
    let parts: Vec<&str> = value.split(':').collect();
    if parts.len() != 9 || parts[0] != "arveil-route" || parts[1] != "v1" {
        return Err(CliError::Domain("not an arveil-route:v1 string".into()));
    }
    let route = Route {
        identity_id: hex::decode(parts[2]).map_err(domain_error("identity id"))?,
        device_id: hex::decode(parts[3]).map_err(domain_error("device id"))?,
        credential_hash: hex::decode(parts[4]).map_err(domain_error("credential hash"))?,
        root_public: hex::decode(parts[5]).map_err(domain_error("root key"))?,
        mailbox_id: hex::decode(parts[6]).map_err(domain_error("mailbox id"))?,
        write_capability: hex::decode(parts[7]).map_err(domain_error("write capability"))?,
        hpke_public: hex::decode(parts[8]).map_err(domain_error("hpke key"))?,
    };
    let public: [u8; 32] = route
        .root_public
        .as_slice()
        .try_into()
        .map_err(|_| CliError::Domain("route: root key length".into()))?;
    let verifying = ed25519_dalek::VerifyingKey::from_bytes(&public)
        .map_err(domain_error("route: root key"))?;
    if arveil_core::identity::identity_id(&verifying) != route.identity_id {
        return Err(CliError::Domain(
            "route: identity id does not derive from its root key".into(),
        ));
    }
    Ok(route)
}

fn route_string(
    client: &Client,
    device: &StoredDevice,
    mailbox: &OwnMailbox,
) -> Result<String, CliError> {
    let identity_id = client
        .identity_id()
        .map_err(storage_error("identity"))?
        .ok_or_else(|| CliError::Domain("no identity".into()))?;
    let root_public = client
        .root_public()
        .map_err(storage_error("identity"))?
        .ok_or_else(|| CliError::Domain("no identity".into()))?;
    Ok(format!(
        "arveil-route:v1:{}:{}:{}:{}:{}:{}:{}",
        hex::encode(identity_id),
        hex::encode(device.keys.device_id),
        hex::encode(&device.credential_hash),
        hex::encode(root_public.as_bytes()),
        hex::encode(&mailbox.mailbox_id),
        hex::encode(&mailbox.write_capability),
        hex::encode(&device.keys.envelope_hpke.public)
    ))
}

fn enrolled(config: &ProfileConfig) -> Result<(Client, StoredDevice, StoredRealm), CliError> {
    let client = open_client(config)?;
    let device = client
        .device()
        .map_err(storage_error("device"))?
        .ok_or_else(|| CliError::Domain("no enrolled device in this data dir".into()))?;
    let realm = client
        .realm()
        .map_err(storage_error("realm"))?
        .filter(|realm| realm.enrolled)
        .ok_or_else(|| CliError::Domain("not enrolled in a realm".into()))?;
    Ok((client, device, realm))
}

fn random_delivery_id() -> Result<Vec<u8>, CliError> {
    let mut id = [0_u8; 16];
    getrandom::fill(&mut id).map_err(domain_error("random"))?;
    Ok(id.to_vec())
}

/// Application event inside MLS (PROTOCOL §2, `ApplicationEvent`).
#[derive(Debug, Serialize, Deserialize)]
struct AppEvent {
    kind: String,
    #[serde(with = "serde_bytes")]
    body: Vec<u8>,
}

fn encode_event(kind: &str, body: &[u8]) -> Result<Vec<u8>, CliError> {
    arveil_core::signed::canonical(&AppEvent {
        kind: kind.into(),
        body: body.to_vec(),
    })
    .map_err(protocol_error("event"))
}

fn decode_event(bytes: &[u8]) -> Result<AppEvent, CliError> {
    ciborium::from_reader(bytes).map_err(protocol_error("event"))
}

struct Session {
    client: Client,
    device: StoredDevice,
    realm: StoredRealm,
    delivery: Delivery,
    identity_id: Vec<u8>,
}

fn session(config: &ProfileConfig) -> Result<(Session, Engine<impl MlsConfig>), CliError> {
    let (client, device, realm) = enrolled(config)?;
    let delivery = client.delivery().map_err(storage_error("delivery"))?;
    let identity_id = client
        .identity_id()
        .map_err(storage_error("identity"))?
        .ok_or_else(|| CliError::Domain("no identity".into()))?;
    let engine = client.mls_engine(device.mls_identity());
    Ok((
        Session {
            client,
            device,
            realm,
            delivery,
            identity_id,
        },
        engine,
    ))
}

fn own_route(s: &Session) -> Result<String, CliError> {
    let m = s
        .client
        .mailbox_own()
        .map_err(storage_error("mailbox"))?
        .ok_or_else(|| CliError::Domain("no mailbox; run `mailbox create` first".into()))?;
    route_string(&s.client, &s.device, &m)
}

fn peer_from_route(r: &Route) -> Peer {
    Peer {
        identity: r.identity_id.clone(),
        device_id: r.device_id.clone(),
        credential_hash: r.credential_hash.clone(),
        root_public: r.root_public.clone(),
        mailbox: Some(r.mailbox_id.clone()),
        write_cap: Some(r.write_capability.clone()),
        hpke: Some(r.hpke_public.clone()),
        revoked: false,
    }
}

fn route_of_peer(p: &Peer) -> Option<String> {
    match (&p.mailbox, &p.write_cap, &p.hpke) {
        (Some(m), Some(w), Some(h)) => Some(format!(
            "arveil-route:v1:{}:{}:{}:{}:{}:{}:{}",
            hex::encode(&p.identity),
            hex::encode(&p.device_id),
            hex::encode(&p.credential_hash),
            hex::encode(&p.root_public),
            hex::encode(m),
            hex::encode(w),
            hex::encode(h)
        )),
        _ => None,
    }
}

/// Seal `mls_bytes` for one peer and enqueue it. Inside the unit of work.
/// A peer without a route is skipped here and visible in `history`.
fn enqueue_for(
    s: &Session,
    peer: &Peer,
    event_id: Option<&[u8]>,
    mls_bytes: &[u8],
) -> Result<Option<QueuedDelivery>, rusqlite::Error> {
    let (Some(mailbox), Some(hpke)) = (&peer.mailbox, &peer.hpke) else {
        return Ok(None);
    };
    let delivery_id = random_delivery_id().map_err(|_| rusqlite::Error::InvalidQuery)?;
    let ctx = EnvelopeContext::new(&s.realm.realm_id, mailbox, &delivery_id);
    let sealed = envelope::seal(hpke, &ctx, KIND_MLS, mls_bytes)
        .map_err(|_| rusqlite::Error::InvalidQuery)?;
    s.delivery.enqueue(
        mailbox,
        &delivery_id,
        event_id,
        &sealed.enc,
        &sealed.ciphertext,
    )?;
    Ok(Some(QueuedDelivery {
        mailbox_id: mailbox.clone(),
        delivery_id,
    }))
}

/// What one fan-out did, so the CLI can report it without guessing.
#[derive(Clone, Debug)]
struct QueuedDelivery {
    mailbox_id: Vec<u8>,
    delivery_id: Vec<u8>,
}

#[derive(Default, Clone, Debug)]
struct FanOut {
    deliveries: Vec<QueuedDelivery>,
    no_route: usize,
    revoked: usize,
}

impl FanOut {
    fn local_acceptance(&self) -> LocalAcceptance {
        LocalAcceptance::PersistedToOutbox {
            envelopes: self.deliveries.len(),
            peers_without_route: self.no_route,
            revoked_devices: self.revoked,
        }
    }

    fn record_queued_deliveries(&self, event_id: &[u8]) {
        for delivery in &self.deliveries {
            record_change(StateChange::DeliveryChanged {
                event_id: Some(event_id.to_vec()),
                mailbox_id: delivery.mailbox_id.clone(),
                delivery_id: delivery.delivery_id.clone(),
                state: DeliveryStatus::Queued,
            });
        }
    }
}

/// Fan-out: one envelope per routable, non-revoked peer device.
fn enqueue_for_all(
    s: &Session,
    peers: &[Peer],
    event_id: Option<&[u8]>,
    mls_bytes: &[u8],
) -> Result<FanOut, rusqlite::Error> {
    let mut out = FanOut::default();
    for p in peers {
        // A device known to be revoked receives nothing more.
        if p.revoked {
            out.revoked += 1;
            continue;
        }
        match enqueue_for(s, p, event_id, mls_bytes)? {
            Some(delivery) => out.deliveries.push(delivery),
            None => out.no_route += 1,
        }
    }
    Ok(out)
}

/// Write capability for a mailbox, from any conversation that knows it.
fn write_cap_for(s: &Session, mailbox: &[u8]) -> Result<Vec<u8>, CliError> {
    for c in s
        .client
        .conversations()
        .map_err(storage_error("conversations"))?
    {
        for p in c.peers {
            if p.mailbox.as_deref() == Some(mailbox)
                && let Some(cap) = p.write_cap
            {
                return Ok(cap);
            }
        }
    }
    Err(CliError::Domain(
        "no write capability for a pending envelope".into(),
    ))
}

/// Requested envelope expiry: the configured seconds from now, or 0 to
/// accept the relay's default. The relay may shorten it and reports the
/// effective value, which the outbox records.
fn requested_expiry(config: &ProfileConfig) -> u64 {
    config
        .envelope_ttl()
        .map(|ttl| {
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0)
                + ttl
        })
        .unwrap_or(0)
}

/// Publish every pending outbox row. Retransmissions reuse stored bytes.
async fn publish_pending(
    config: &ProfileConfig,
    s: &Session,
    conn: &mut Connection,
) -> Result<usize, CliError> {
    let pending = s.delivery.pending().map_err(storage_error("outbox"))?;
    let mut n = 0;
    for row in pending {
        let cap = write_cap_for(s, &row.mailbox_id)?;
        s.delivery
            .mark_attempt(row.id)
            .map_err(storage_error("outbox"))?;
        let reply = conn
            .request(Payload::EnvelopePut {
                mailbox_id: row.mailbox_id.clone(),
                write_capability: cap,
                delivery_id: row.delivery_id.clone(),
                requested_expiry: requested_expiry(config),
                hpke_enc: row.hpke_enc.clone(),
                ciphertext: row.ciphertext.clone(),
            })
            .await;
        match reply {
            Ok(Payload::EnvelopeAccepted { effective_expiry }) => {
                s.delivery
                    .mark_accepted(row.id, Some(effective_expiry as i64))
                    .map_err(storage_error("outbox"))?;
                record_change(StateChange::DeliveryChanged {
                    event_id: row.event_id.clone(),
                    mailbox_id: row.mailbox_id.clone(),
                    delivery_id: row.delivery_id.clone(),
                    state: DeliveryStatus::Accepted {
                        expires_at: effective_expiry,
                    },
                });
                n += 1;
            }
            Ok(other) => {
                return Err(CliError::Protocol(format!("unexpected reply: {other:?}")));
            }
            // A revoked device's capabilities are gone: the envelope will
            // never be accepted. Say so once and stop retrying it.
            Err(e) if matches!(e.relay_code(), Some(403 | 410)) => {
                let reason = e.to_string();
                s.delivery
                    .mark_undeliverable(row.id)
                    .map_err(storage_error("outbox"))?;
                record_change(StateChange::DeliveryChanged {
                    event_id: row.event_id.clone(),
                    mailbox_id: row.mailbox_id.clone(),
                    delivery_id: row.delivery_id.clone(),
                    state: DeliveryStatus::Undeliverable { reason },
                });
            }
            Err(e) => return Err(e),
        }
    }
    Ok(n)
}

/// Device ids currently holding a leaf in the group, from the MLS roster.
fn roster_device_ids<C: MlsConfig>(group: &Group<C>) -> Vec<Vec<u8>> {
    group
        .roster()
        .members()
        .into_iter()
        .filter_map(|m| {
            m.signing_identity
                .credential
                .as_basic()
                .map(|b| b.identifier.clone())
        })
        .collect()
}

/// The leaf this device holds, and whether it is the authorized committer:
/// the lowest leaf that is not known to be revoked (policy v2).
fn committer_leaf<C: MlsConfig>(s: &Session, group: &Group<C>) -> Option<u32> {
    let mut members: Vec<_> = group.roster().members();
    members.sort_by_key(|m| m.index);
    members
        .into_iter()
        .find(|m| {
            let device = m
                .signing_identity
                .credential
                .as_basic()
                .map(|c| c.identifier.clone())
                .unwrap_or_default();
            !s.client.device_revoked(&device).unwrap_or(false)
        })
        .map(|m| m.index)
}

fn i_am_committer<C: MlsConfig>(s: &Session, group: &Group<C>) -> bool {
    committer_leaf(s, group) == Some(group.current_member_index())
}

/// Revoked devices that still hold a leaf. While any exists, this device
/// refuses to send: the epoch still lets them read (PROTOCOL §8).
fn revoked_leaves<C: MlsConfig>(conv: &Conversation, group: &Group<C>) -> Vec<Vec<u8>> {
    let leaves = roster_device_ids(group);
    conv.peers
        .iter()
        .filter(|p| p.revoked && leaves.contains(&p.device_id))
        .map(|p| p.device_id.clone())
        .collect()
}

/// Refuse to send while a revoked device is still a member.
fn guard_revoked<C: MlsConfig>(conv: &Conversation, group: &Group<C>) -> Result<(), CliError> {
    let stuck = revoked_leaves(conv, group);
    if stuck.is_empty() {
        return Ok(());
    }
    Err(CliError::Domain(format!(
        "paused: {} revoked device(s) still in the group ({}); waiting for the committer to remove them",
        stuck.len(),
        stuck
            .iter()
            .map(|d| hex::encode(&d[..4]))
            .collect::<Vec<_>>()
            .join(", ")
    )))
}

/// Encrypt a signed manifest as a `manifest` event for the group.
fn manifest_message<C: MlsConfig>(
    group: &mut Group<C>,
    manifest: &[u8],
) -> Result<Vec<u8>, CliError> {
    group
        .encrypt_application_message(&encode_event("manifest", manifest)?, Default::default())
        .map_err(protocol_error("mls encrypt"))?
        .to_bytes()
        .map_err(protocol_error("mls encode"))
}

/// Connect through the first endpoint that completes the handshake, in
/// priority order from the stored signed list, with the bootstrap URL as
/// the last resort. A dead or hostile endpoint costs one failed attempt.
/// After connecting, the list is refreshed; a lower sequence is refused.
async fn connect(
    config: &ProfileConfig,
    s: &Session,
    b: &Bootstrap,
) -> Result<Connection, CliError> {
    let mut candidates: Vec<String> = Vec::new();
    if let Some(list) = &s.realm.endpoint_list {
        let mut eps = list.endpoints.clone();
        eps.sort_by_key(|e| e.priority);
        candidates.extend(eps.into_iter().filter(|e| e.kind != "admin").map(|e| e.url));
    }
    if !candidates.contains(&b.url) {
        candidates.push(b.url.clone());
    }
    let mut last = CliError::Transport("no endpoints".into());
    for url in &candidates {
        match Connection::open(
            url,
            &b.realm_id,
            &s.realm.noise_public,
            &s.device.keys.transport_noise,
            config.tls_ca(),
        )
        .await
        {
            Ok(mut conn) => {
                if candidates.first() != Some(url) {
                    record_change(StateChange::EndpointFallback { url: url.clone() });
                }
                if let Ok(Payload::EndpointList { signed }) =
                    conn.request(Payload::EndpointListGet).await
                {
                    match s.client.realm_accept_endpoint_list(&b.realm_id, &signed) {
                        Ok(list) => {
                            if s.realm.endpoint_list.as_ref().map(|l| l.sequence)
                                != Some(list.sequence)
                            {
                                record_change(StateChange::EndpointListStored {
                                    sequence: list.sequence,
                                    endpoints: list.endpoints.len(),
                                });
                            }
                        }
                        Err(error) => record_change(StateChange::EndpointListRejected {
                            reason: error.to_string(),
                        }),
                    }
                }
                return Ok(conn);
            }
            Err(e) => {
                record_change(StateChange::EndpointFailed {
                    url: url.clone(),
                    reason: e.to_string(),
                });
                last = e;
            }
        }
    }
    Err(last)
}

async fn claim_key_package(conn: &mut Connection, r: &Route) -> Result<MlsMessage, CliError> {
    match conn
        .request(Payload::KeyPackagesClaim {
            identity_id: r.identity_id.clone(),
            device_id: r.device_id.clone(),
        })
        .await?
    {
        Payload::KeyPackageClaimed { key_package } => {
            MlsMessage::from_bytes(&key_package).map_err(protocol_error("key package"))
        }
        other => Err(CliError::Protocol(format!("unexpected reply: {other:?}"))),
    }
}

/// The roster event: every member's route, this device's first.
fn roster_message<C: MlsConfig>(
    s: &Session,
    group: &mut Group<C>,
    peers: &[Peer],
) -> Result<Vec<u8>, CliError> {
    let mut routes = vec![own_route(s)?];
    routes.extend(peers.iter().filter_map(route_of_peer));
    group
        .encrypt_application_message(
            &encode_event("roster", routes.join("\n").as_bytes())?,
            Default::default(),
        )
        .map_err(protocol_error("mls encrypt"))?
        .to_bytes()
        .map_err(protocol_error("mls encode"))
}

/// Pick the conversation a command acts on (M4.7).
///
/// With one conversation nothing has to be said. With several, a hex prefix
/// of the group id selects one, and anything ambiguous is refused with the
/// candidates rather than guessed.
fn select_conversation(s: &Session, prefix: Option<&str>) -> Result<Conversation, CliError> {
    let all = s
        .client
        .conversations()
        .map_err(storage_error("conversations"))?;
    if all.is_empty() {
        return Err(CliError::Domain(
            "no conversation; run `chat start` or `chat sync` first".into(),
        ));
    }
    let describe = |list: &[Conversation]| {
        list.iter()
            .map(|c| hex::encode(&c.group_id[..6]))
            .collect::<Vec<_>>()
            .join(", ")
    };
    match prefix {
        None if all.len() == 1 => Ok(all.into_iter().next().expect("one conversation")),
        None => Err(CliError::Domain(format!(
            "{} conversations here; choose one with --group <prefix>: {}",
            all.len(),
            describe(&all)
        ))),
        Some(p) => {
            let p = p.trim().to_ascii_lowercase();
            let matches: Vec<Conversation> = all
                .into_iter()
                .filter(|c| hex::encode(&c.group_id).starts_with(&p))
                .collect();
            match matches.len() {
                1 => Ok(matches.into_iter().next().expect("one match")),
                0 => Err(CliError::Domain(format!("no conversation starts with {p}"))),
                _ => Err(CliError::Domain(format!(
                    "{p} matches {} conversations: {}",
                    matches.len(),
                    describe(&matches)
                ))),
            }
        }
    }
}

async fn start(
    config: &ProfileConfig,
    bootstrap: &str,
    peer_routes: &[&str],
) -> Result<(), CliError> {
    let b = Bootstrap::parse(bootstrap)?;
    let peers: Vec<Route> = peer_routes
        .iter()
        .map(|r| parse_route(r))
        .collect::<Result<_, _>>()?;
    if peers.is_empty() {
        return Err(CliError::Domain(
            "chat start needs at least one peer route".into(),
        ));
    }
    let (s, engine) = session(config)?;

    let mut conn = connect(config, &s, &b).await?;
    let mut kps = Vec::new();
    for p in &peers {
        kps.push(claim_key_package(&mut conn, p).await?);
    }

    let mut group = engine.create_group().map_err(protocol_error("mls"))?;
    let mut cb = group.commit_builder();
    for kp in kps {
        cb = cb.add_member(kp).map_err(domain_error("mls add"))?;
    }
    let commit = cb.build().map_err(domain_error("mls commit"))?;
    group
        .apply_pending_commit()
        .map_err(protocol_error("mls apply"))?;
    let conv = Conversation {
        group_id: group.group_id().to_vec(),
        creator: true,
        peers: peers.iter().map(peer_from_route).collect(),
    };
    let welcome = commit
        .welcome_messages
        .first()
        .ok_or_else(|| CliError::Protocol("no welcome produced".into()))?
        .to_bytes()
        .map_err(protocol_error("welcome"))?;
    let roster = roster_message(&s, &mut group, &conv.peers)?;

    s.client
        .unit_of_work(|| {
            group
                .write_to_storage()
                .map_err(|_| rusqlite::Error::InvalidQuery)?;
            s.client
                .conversation_save(&conv)
                .map_err(|_| rusqlite::Error::InvalidQuery)?;
            enqueue_for_all(&s, &conv.peers, None, &welcome)?;
            enqueue_for_all(&s, &conv.peers, None, &roster)?;
            Ok::<_, rusqlite::Error>(())
        })
        .map_err(storage_error("start unit"))?;
    record_change(StateChange::ConversationCreated {
        group_id: conv.group_id.clone(),
        peers: conv.peers.len(),
        epoch: group.current_epoch(),
    });
    let n = publish_pending(config, &s, &mut conn).await?;
    record_change(StateChange::EnvelopesPublished {
        count: n,
        pending: false,
    });
    conn.close().await;
    Ok(())
}

/// `arveil chat add --data-dir D <bootstrap> <peer-route>` (creator only)
async fn add(
    config: &ProfileConfig,
    bootstrap: &str,
    peer_route: &str,
    group: Option<&str>,
) -> Result<(), CliError> {
    let b = Bootstrap::parse(bootstrap)?;
    let newcomer = parse_route(peer_route)?;
    let (s, engine) = session(config)?;
    let mut conn = connect(config, &s, &b).await?;
    let kp = claim_key_package(&mut conn, &newcomer).await?;
    let conv = select_conversation(&s, group)?;
    let mut group = engine
        .load_group(&conv.group_id)
        .map_err(storage_error("mls load"))?;
    // On a device that is not the lowest active leaf, the policy
    // refuses this before anything is produced.
    let commit = group
        .commit_builder()
        .add_member(kp)
        .map_err(domain_error("mls add"))?
        .build()
        .map_err(domain_error("mls commit"))?;
    group
        .apply_pending_commit()
        .map_err(protocol_error("mls apply"))?;
    let new_peer = peer_from_route(&newcomer);
    let mut all = conv.clone();
    all.peers.push(new_peer.clone());
    let welcome = commit
        .welcome_messages
        .first()
        .ok_or_else(|| CliError::Protocol("no welcome produced".into()))?
        .to_bytes()
        .map_err(protocol_error("welcome"))?;
    let commit_bytes = commit
        .commit_message
        .to_bytes()
        .map_err(protocol_error("commit"))?;
    let roster = roster_message(&s, &mut group, &all.peers)?;

    s.client
        .unit_of_work(|| {
            group
                .write_to_storage()
                .map_err(|_| rusqlite::Error::InvalidQuery)?;
            s.client
                .conversation_save(&all)
                .map_err(|_| rusqlite::Error::InvalidQuery)?;
            enqueue_for_all(&s, &conv.peers, None, &commit_bytes)?;
            enqueue_for(&s, &new_peer, None, &welcome)?;
            enqueue_for_all(&s, &all.peers, None, &roster)?;
            Ok::<_, rusqlite::Error>(())
        })
        .map_err(storage_error("add unit"))?;
    record_change(StateChange::DeviceAdded {
        identity_id: newcomer.identity_id.clone(),
        device_id: newcomer.device_id.clone(),
        epoch: group.current_epoch(),
    });
    let n = publish_pending(config, &s, &mut conn).await?;
    record_change(StateChange::EnvelopesPublished {
        count: n,
        pending: false,
    });
    conn.close().await;
    Ok(())
}

/// `arveil chat remove --data-dir D <bootstrap> <device-id>` (committer only)
///
/// Removes a leaf whose credential this device knows to be revoked, from a
/// manifest it verified under that identity's root. A device that is not
/// revoked is never removed this way: revocation is the authority, the
/// commit only enacts it.
async fn remove(
    config: &ProfileConfig,
    bootstrap: &str,
    device_hex: &str,
    group: Option<&str>,
) -> Result<(), CliError> {
    let b = Bootstrap::parse(bootstrap)?;
    let device_id = hex::decode(device_hex).map_err(domain_error("device id"))?;
    let (s, engine) = session(config)?;
    let mut conn = connect(config, &s, &b).await?;
    let conv = select_conversation(&s, group)?;
    if !conv
        .peers
        .iter()
        .any(|p| p.device_id == device_id && p.revoked)
    {
        return Err(CliError::Domain(
            "that device is not known to be revoked here; a verified manifest must say so first"
                .into(),
        ));
    }
    let mut group = engine
        .load_group(&conv.group_id)
        .map_err(storage_error("mls load"))?;
    let index = group
        .roster()
        .members()
        .into_iter()
        .find(|m| {
            m.signing_identity
                .credential
                .as_basic()
                .map(|c| c.identifier == device_id)
                .unwrap_or(false)
        })
        .map(|m| m.index)
        .ok_or_else(|| CliError::Domain("that device holds no leaf in this conversation".into()))?;

    let commit = group
        .commit_builder()
        .remove_member(index)
        .map_err(domain_error("mls remove"))?
        .build()
        .map_err(domain_error("mls commit"))?;
    group
        .apply_pending_commit()
        .map_err(protocol_error("mls apply"))?;
    let bytes = commit
        .commit_message
        .to_bytes()
        .map_err(protocol_error("commit"))?;
    s.client
        .unit_of_work(|| {
            group
                .write_to_storage()
                .map_err(|_| rusqlite::Error::InvalidQuery)?;
            enqueue_for_all(&s, &conv.peers, None, &bytes)
        })
        .map_err(storage_error("remove unit"))?;
    record_change(StateChange::DeviceRemoved {
        device_id: device_id.clone(),
        leaf: index,
        epoch: group.current_epoch(),
    });
    let n = publish_pending(config, &s, &mut conn).await?;
    record_change(StateChange::EnvelopesPublished {
        count: n,
        pending: false,
    });
    conn.close().await;
    Ok(())
}

/// `arveil chat send --data-dir D <bootstrap> <text>`
async fn send(
    config: &ProfileConfig,
    bootstrap: &str,
    text: &str,
    group: Option<&str>,
) -> Result<(), CliError> {
    let b = Bootstrap::parse(bootstrap)?;
    let (s, engine) = session(config)?;
    let conv = select_conversation(&s, group)?;
    let mut group = engine
        .load_group(&conv.group_id)
        .map_err(storage_error("mls load"))?;
    guard_revoked(&conv, &group)?;
    let event_id = random_delivery_id()?;

    // Send unit: nothing leaves the device before this commits.
    let fan = s
        .client
        .unit_of_work(|| {
            let msg = group
                .encrypt_application_message(
                    &encode_event("text", text.as_bytes())
                        .map_err(|_| rusqlite::Error::InvalidQuery)?,
                    Default::default(),
                )
                .map_err(|_| rusqlite::Error::InvalidQuery)?;
            group
                .write_to_storage()
                .map_err(|_| rusqlite::Error::InvalidQuery)?;
            s.delivery
                .record_event(&conv.group_id, &event_id, "sent", text.as_bytes())?;
            let bytes = msg.to_bytes().map_err(|_| rusqlite::Error::InvalidQuery)?;
            enqueue_for_all(&s, &conv.peers, Some(&event_id), &bytes)
        })
        .map_err(storage_error("send unit"))?;
    record_message(
        MessageReceipt {
            group_id: conv.group_id.clone(),
            event_id: event_id.clone(),
            kind: MessageKind::Text,
            local_acceptance: fan.local_acceptance(),
        },
        group.current_epoch(),
    );
    fan.record_queued_deliveries(&event_id);

    if std::env::var_os("ARVEIL_CRASH_AFTER_COMMIT").is_some() {
        return Err(CliError::Interrupted {
            exit_code: 3,
            message: "simulated crash after commit, before publishing".into(),
        });
    }

    // Publishing is best effort: the message is already durable. A relay
    // that cannot be reached leaves it queued for the next send or sync.
    let outcome: Result<usize, CliError> = async {
        let mut conn = connect(config, &s, &b).await?;
        let n = publish_pending(config, &s, &mut conn).await?;
        conn.close().await;
        Ok(n)
    }
    .await;
    match outcome {
        Ok(n) => record_change(StateChange::EnvelopesPublished {
            count: n,
            pending: false,
        }),
        Err(e) if e.kind() == FailureKind::Transport => {
            let pending = s.delivery.pending().map_err(storage_error("outbox"))?.len();
            record_change(StateChange::RelayUnavailable {
                pending,
                reason: e.to_string(),
            });
        }
        Err(e) => return Err(e),
    }
    Ok(())
}

/// Process one decrypted MLS message inside the receive unit.
fn handle_mls<C: MlsConfig>(
    s: &Session,
    engine: &Engine<C>,
    msg: MlsMessage,
    delivery_id: &[u8],
) -> Result<StateChange, CliError> {
    match msg.wire_format() {
        WireFormat::Welcome => {
            let mut group = engine.join(&msg).map_err(protocol_error("mls join"))?;
            group
                .write_to_storage()
                .map_err(storage_error("mls persist"))?;
            s.client
                .conversation_save(&Conversation {
                    group_id: group.group_id().to_vec(),
                    creator: false,
                    peers: Vec::new(),
                })
                .map_err(storage_error("conversation"))?;
            Ok(StateChange::ConversationJoined {
                group_id: group.group_id().to_vec(),
                epoch: group.current_epoch(),
            })
        }
        // Commits travel as PublicMessage; the HPKE envelope already hides
        // them from the relay, so both wire formats are handled alike.
        WireFormat::PrivateMessage | WireFormat::PublicMessage => {
            let gid = msg
                .group_id()
                .ok_or_else(|| CliError::Protocol("message without group id".into()))?
                .to_vec();
            let mut group = engine.load_group(&gid).map_err(storage_error("mls load"))?;
            let received = group
                .process_incoming_message(msg)
                .map_err(protocol_error("mls process"))?;
            group
                .write_to_storage()
                .map_err(storage_error("mls persist"))?;
            match received {
                ReceivedMessage::ApplicationMessage(app) => {
                    let ev = decode_event(app.data())?;
                    match ev.kind.as_str() {
                        "roster" => {
                            let text = String::from_utf8_lossy(&ev.body);
                            let mut peers = Vec::new();
                            for line in text.lines() {
                                let r = parse_route(line)?;
                                // Own other devices are peers; only this
                                // device itself is left out.
                                if r.device_id != s.device.keys.device_id {
                                    peers.push(peer_from_route(&r));
                                }
                            }
                            let n = peers.len();
                            s.client
                                .conversation_save(&Conversation {
                                    group_id: gid.clone(),
                                    creator: false,
                                    peers,
                                })
                                .map_err(storage_error("conversation"))?;
                            Ok(StateChange::RosterUpdated {
                                group_id: gid,
                                peers: n,
                            })
                        }
                        "manifest" => {
                            // A manifest is accepted only under the root
                            // this device already stored for that identity,
                            // and only if it advances the known sequence.
                            let claimed =
                                arveil_core::identity::manifest_identity_unverified(&ev.body);
                            let (body, new) = match claimed {
                                Some(id) if id != s.identity_id => s
                                    .client
                                    .peer_manifest_accept(&id, &ev.body)
                                    .map_err(domain_error("manifest"))?,
                                _ => s
                                    .client
                                    .manifest_accept_own(&ev.body)
                                    .map_err(domain_error("manifest"))?,
                            };
                            Ok(StateChange::ManifestUpdated {
                                identity_id: body.identity_id,
                                sequence: body.manifest_sequence,
                                active_devices: body.active_credential_hashes.len(),
                                revoked_devices: body.revoked_credential_hashes.len(),
                                source: ManifestSource::Group,
                                already_known: !new,
                            })
                        }
                        "text" => {
                            s.delivery
                                .record_event(&gid, delivery_id, "received", &ev.body)
                                .map_err(storage_error("event"))?;
                            Ok(StateChange::MessageReceived {
                                group_id: gid,
                                event_id: delivery_id.to_vec(),
                                body: ev.body,
                            })
                        }
                        "file" => {
                            let d =
                                FileDescriptor::decode(&ev.body).map_err(protocol_error("file"))?;
                            s.delivery
                                .record_event(&gid, delivery_id, "file-pending", &ev.body)
                                .map_err(storage_error("event"))?;
                            Ok(StateChange::FileAnnounced {
                                group_id: gid,
                                event_id: delivery_id.to_vec(),
                                name: d.safe_name(),
                                size: d.size,
                            })
                        }
                        other => Ok(StateChange::MlsMessageProcessed {
                            group_id: gid,
                            description: format!("event of kind {other} ignored"),
                        }),
                    }
                }
                ReceivedMessage::Commit(c) => Ok(StateChange::CommitApplied {
                    group_id: gid,
                    committer: c.committer,
                    epoch: group.current_epoch(),
                }),
                other => Ok(StateChange::MlsMessageProcessed {
                    group_id: gid,
                    description: format!("mls message {other:?} processed"),
                }),
            }
        }
        other => Err(CliError::Protocol(format!(
            "unexpected MLS wire format {other:?}"
        ))),
    }
}

/// `arveil chat sync --data-dir D <bootstrap>`
async fn sync(config: &ProfileConfig, bootstrap: &str) -> Result<(), CliError> {
    let b = Bootstrap::parse(bootstrap)?;
    let (s, engine) = session(config)?;
    let m = s
        .client
        .mailbox_own()
        .map_err(storage_error("mailbox"))?
        .ok_or_else(|| CliError::Domain("no mailbox".into()))?;

    let mut conn = connect(config, &s, &b).await?;
    let published = publish_pending(config, &s, &mut conn).await?;
    if published > 0 {
        record_change(StateChange::EnvelopesPublished {
            count: published,
            pending: true,
        });
    }
    // Revocations first: a commit that removes a revoked leaf is only
    // acceptable once this device has verified the manifest that
    // revoked it.
    refresh_manifests(&s, &mut conn).await?;
    replenish_key_packages(&s, &mut conn).await?;
    let cursor = s
        .delivery
        .cursor(&m.mailbox_id)
        .map_err(storage_error("cursor"))? as u64;
    let (items, _fetched_next) = match conn
        .request(Payload::EnvelopeFetch {
            mailbox_id: m.mailbox_id.clone(),
            read_capability: m.read_capability.clone(),
            cursor,
            limit: 50,
        })
        .await?
    {
        Payload::Envelopes { items, next_cursor } => (items, next_cursor),
        other => return Err(CliError::Protocol(format!("unexpected reply: {other:?}"))),
    };

    // Envelopes are processed in sequence order. The first one that
    // cannot be processed stops the pass: later ones may depend on it
    // (a roster after a commit), and the cursor only advances past what
    // was processed or deduplicated, so the rest is retried next time.
    let mut new = 0;
    let mut advanced_to = cursor;
    for item in &items {
        let ctx = EnvelopeContext::new(&s.realm.realm_id, &m.mailbox_id, &item.delivery_id);
        let outcome: Result<Option<StateChange>, CliError> = s.client.unit_of_work(|| {
            if !s
                .delivery
                .record_incoming(&m.mailbox_id, &item.delivery_id, item.seq as i64)
                .map_err(storage_error("inbox"))?
            {
                return Ok(None);
            }
            let inner = envelope::open(
                &s.device.keys.envelope_hpke.private,
                &ctx,
                &envelope::Sealed {
                    enc: item.hpke_enc.clone(),
                    ciphertext: item.ciphertext.clone(),
                },
            )
            .map_err(protocol_error("open"))?;
            let msg =
                MlsMessage::from_bytes(&inner.payload).map_err(protocol_error("mls parse"))?;
            handle_mls(&s, &engine, msg, &item.delivery_id).map(Some)
        });
        match outcome {
            Ok(Some(change)) => {
                new += 1;
                record_change(change);
            }
            Ok(None) => record_change(StateChange::DuplicateDelivery {
                delivery_id: item.delivery_id.clone(),
            }),
            Err(e) => {
                record_change(StateChange::DeliveryDeferred {
                    delivery_id: item.delivery_id.clone(),
                    reason: e.to_string(),
                });
                break;
            }
        }
        advanced_to = item.seq;
    }
    let next = advanced_to;
    download_pending(&s, &mut conn, config).await?;
    let unacked = s
        .delivery
        .unacked(&m.mailbox_id)
        .map_err(storage_error("inbox"))?;
    if !unacked.is_empty() {
        match conn
            .request(Payload::EnvelopeAck {
                mailbox_id: m.mailbox_id.clone(),
                read_capability: m.read_capability.clone(),
                delivery_ids: unacked
                    .iter()
                    .cloned()
                    .map(serde_bytes::ByteBuf::from)
                    .collect(),
            })
            .await?
        {
            Payload::Ack => s
                .delivery
                .mark_acked(&m.mailbox_id, &unacked)
                .map_err(storage_error("inbox"))?,
            other => return Err(CliError::Protocol(format!("unexpected reply: {other:?}"))),
        }
    }
    s.delivery
        .set_cursor(&m.mailbox_id, next as i64)
        .map_err(storage_error("cursor"))?;
    record_change(StateChange::SyncCompleted {
        fetched: items.len(),
        new,
        acked: unacked.len(),
    });
    conn.close().await;
    Ok(())
}

/// Ask the relay for the newest manifest of every identity in this
/// device's conversations, including its own. The in-group copy catches a
/// relay that hides versions; this catches a group that has not carried the
/// manifest yet. Both are verified under the root already stored.
async fn refresh_manifests(s: &Session, conn: &mut Connection) -> Result<(), CliError> {
    let mut identities: Vec<Vec<u8>> = vec![s.identity_id.clone()];
    for c in s
        .client
        .conversations()
        .map_err(storage_error("conversations"))?
    {
        for p in c.peers {
            if !identities.contains(&p.identity) {
                identities.push(p.identity);
            }
        }
    }
    for id in identities {
        let signed = match conn
            .request(Payload::ManifestGet {
                identity_id: id.clone(),
            })
            .await?
        {
            Payload::ManifestLatest { manifest } => manifest,
            other => return Err(CliError::Protocol(format!("unexpected reply: {other:?}"))),
        };
        if signed.is_empty() {
            continue;
        }
        let accepted = if id == s.identity_id {
            s.client.manifest_accept_own(&signed)
        } else {
            s.client.peer_manifest_accept(&id, &signed)
        };
        match accepted {
            Ok((body, true)) => record_change(StateChange::ManifestUpdated {
                identity_id: id.clone(),
                sequence: body.manifest_sequence,
                active_devices: body.active_credential_hashes.len(),
                revoked_devices: body.revoked_credential_hashes.len(),
                source: ManifestSource::Realm,
                already_known: false,
            }),
            Ok((_, false)) => {}
            // A relay that serves an older or forked manifest is reported,
            // never applied (I-08).
            Err(error) => record_change(StateChange::ManifestRejected {
                identity_id: id,
                reason: error.to_string(),
            }),
        }
    }
    Ok(())
}

/// `arveil device revoke --data-dir D <bootstrap> <device-id-hex>`
///
/// Signs manifest N+1 without that device, publishes it to the realm (which
/// refuses the device's handshake and revokes its capabilities), sends it as
/// a `manifest` event into every conversation, and, where this device is the
/// committer, removes the revoked leaf in the same pass.
async fn revoke(config: &ProfileConfig, bootstrap: &str, device_hex: &str) -> Result<(), CliError> {
    let b = Bootstrap::parse(bootstrap)?;
    let device_id = hex::decode(device_hex).map_err(domain_error("device id"))?;
    let (s, engine) = session(config)?;
    let (manifest, hash) = s
        .client
        .device_revoke(&device_id)
        .map_err(domain_error("revoke"))?;
    record_change(StateChange::DeviceRevoked {
        device_id: device_id.clone(),
        credential_hash: hash.clone(),
    });

    let mut conn = connect(config, &s, &b).await?;
    match conn
        .request(Payload::ManifestPut {
            manifest: manifest.clone(),
        })
        .await?
    {
        Payload::Ack => record_change(StateChange::RealmRevocationPublished),
        other => return Err(CliError::Protocol(format!("unexpected reply: {other:?}"))),
    }

    for gid in s
        .client
        .archived_groups()
        .map_err(storage_error("archived"))?
    {
        record_change(StateChange::ArchivedConversation {
            group_id: gid.clone(),
        });
        for (kind, body) in s.client.archived(&gid).map_err(storage_error("archived"))? {
            record_change(StateChange::ArchivedEvent { kind, body });
        }
    }
    for conv in s
        .client
        .conversations()
        .map_err(storage_error("conversations"))?
    {
        let mut group = engine
            .load_group(&conv.group_id)
            .map_err(storage_error("mls load"))?;
        let in_group = roster_device_ids(&group).contains(&device_id);
        let committer = i_am_committer(&s, &group);
        let event = manifest_message(&mut group, &manifest)?;
        let removal = if in_group && committer {
            let index = group
                .roster()
                .members()
                .into_iter()
                .find(|m| {
                    m.signing_identity
                        .credential
                        .as_basic()
                        .map(|c| c.identifier == device_id)
                        .unwrap_or(false)
                })
                .map(|m| m.index)
                .ok_or_else(|| CliError::Domain("revoked device not found in the roster".into()))?;
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
                enqueue_for_all(&s, &conv.peers, None, &event)?;
                if let Some(bytes) = &removal {
                    enqueue_for_all(&s, &conv.peers, None, bytes)?;
                }
                Ok::<_, rusqlite::Error>(())
            })
            .map_err(storage_error("revoke unit"))?;
        record_change(StateChange::ConversationManifestSent {
            group_id: conv.group_id.clone(),
            removal: match (&removal, in_group) {
                (Some(_), _) => RemovalOutcome::Removed {
                    epoch: group.current_epoch(),
                },
                (None, true) => RemovalOutcome::LeftToCommitter,
                (None, false) => RemovalOutcome::NotInGroup,
            },
        });
    }
    let n = publish_pending(config, &s, &mut conn).await?;
    record_change(StateChange::EnvelopesPublished {
        count: n,
        pending: false,
    });
    conn.close().await;
    Ok(())
}

/// Top up the KeyPackages the realm holds for this device (M4.6).
///
/// Each is consumed by one person starting a conversation with this device.
/// Without this, the batch published at enrolment runs out and the next
/// person is refused, which looks like a broken realm rather than an empty
/// shelf.
async fn replenish_key_packages(s: &Session, conn: &mut Connection) -> Result<(), CliError> {
    const FLOOR: u32 = 3;
    const TARGET: u32 = 10;
    let available = match conn.request(Payload::KeyPackagesStatus).await? {
        Payload::KeyPackagesAvailable { count } => count,
        other => return Err(CliError::Protocol(format!("unexpected reply: {other:?}"))),
    };
    if available > FLOOR {
        return Ok(());
    }
    let engine = s.client.mls_engine(s.device.mls_identity());
    let mut key_packages = Vec::new();
    for _ in 0..(TARGET - available) {
        let kp = engine
            .key_package()
            .map_err(protocol_error("key package"))?;
        key_packages.push(serde_bytes::ByteBuf::from(
            kp.to_bytes().map_err(protocol_error("key package"))?,
        ));
    }
    let n = key_packages.len();
    match conn
        .request(Payload::KeyPackagesPublish { key_packages })
        .await?
    {
        Payload::Ack => record_change(StateChange::KeyPackagesReplenished {
            previous: available,
            published: n,
        }),
        other => return Err(CliError::Protocol(format!("unexpected reply: {other:?}"))),
    }
    Ok(())
}

const BLOB_CHUNK: usize = 60 * 1024;

/// Test hook: stop an upload after this many chunks, as a network would.
fn crash_after_chunks() -> Option<usize> {
    std::env::var("ARVEIL_CRASH_AFTER_CHUNKS")
        .ok()
        .and_then(|v| v.parse().ok())
}

/// Test hook: stop a download after this many chunks.
fn crash_after_download_chunks() -> Option<usize> {
    std::env::var("ARVEIL_CRASH_AFTER_DOWNLOAD_CHUNKS")
        .ok()
        .and_then(|v| v.parse().ok())
}

/// Open a new blob on the realm and report where to start writing.
async fn begin_upload(
    conn: &mut Connection,
    size: usize,
) -> Result<(Vec<u8>, Vec<u8>, usize), CliError> {
    match conn
        .request(Payload::BlobUploadBegin { size: size as u64 })
        .await?
    {
        Payload::BlobUploadStarted {
            blob_id,
            read_capability,
        } => Ok((blob_id, read_capability, 0)),
        other => Err(CliError::Protocol(format!("unexpected reply: {other:?}"))),
    }
}

fn blob_expiry(config: &ProfileConfig) -> u64 {
    config
        .blob_ttl()
        .map(|ttl| {
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0)
                + ttl
        })
        .unwrap_or(0)
}

/// `arveil chat send-file --data-dir D <bootstrap> <path>`
///
/// Encrypts the whole file with a fresh FileKey, uploads the ciphertext in
/// chunks, commits it with its hash, then sends the descriptor inside MLS
/// exactly like a text message (same send unit, same fan-out).
async fn send_file(
    config: &ProfileConfig,
    bootstrap: &str,
    path: &Path,
    group: Option<&str>,
) -> Result<(), CliError> {
    let b = Bootstrap::parse(bootstrap)?;
    let (s, engine) = session(config)?;
    select_conversation(&s, group)?;
    let plaintext = std::fs::read(path).map_err(filesystem_error("read file"))?;
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "file".into());
    let key = path.to_string_lossy().to_string();

    // An upload interrupted earlier is continued with the same key, nonce
    // and blob id, so the bytes the realm already holds stay valid; only if
    // the file itself changed does it start again (M3.3).
    let pending = s
        .client
        .upload_pending(&key)
        .map_err(storage_error("uploads"))?;
    let enc = match &pending {
        Some(u) => {
            let again = attachments::encrypt_with(&u.file_key, &u.nonce, &plaintext)
                .map_err(protocol_error("encrypt"))?;
            if again.ciphertext_hash == u.ciphertext_hash {
                Some(again)
            } else {
                record_change(StateChange::UploadRestarted {
                    name: name.clone(),
                    reason: UploadRestartReason::FileChanged,
                });
                s.client
                    .upload_clear(&key)
                    .map_err(storage_error("uploads"))?;
                None
            }
        }
        None => None,
    };
    let (enc, pending) = match enc {
        Some(e) => (e, pending),
        None => (
            attachments::encrypt(&plaintext).map_err(protocol_error("encrypt"))?,
            None,
        ),
    };

    let (blob_id, read_capability, expiry) = async {
        let mut conn = connect(config, &s, &b).await?;
        // Where to continue: what the realm says it holds, or a new blob.
        let (blob_id, read_capability, mut offset) = match &pending {
            Some(u) => {
                match conn
                    .request(Payload::BlobResume {
                        blob_id: u.blob_id.clone(),
                    })
                    .await
                {
                    Ok(Payload::BlobOffset { offset }) => {
                        record_change(StateChange::UploadResumed {
                            name: name.clone(),
                            offset: offset as usize,
                            total: enc.ciphertext.len(),
                        });
                        (
                            u.blob_id.clone(),
                            u.read_capability.clone(),
                            offset as usize,
                        )
                    }
                    Ok(other) => {
                        return Err(CliError::Protocol(format!("unexpected reply: {other:?}")));
                    }
                    // The realm dropped it (expired, swept, committed):
                    // start a fresh upload rather than guess.
                    Err(e) => {
                        record_change(StateChange::UploadRestarted {
                            name: name.clone(),
                            reason: UploadRestartReason::RemoteMissing {
                                reason: e.to_string(),
                            },
                        });
                        begin_upload(&mut conn, enc.ciphertext.len()).await?
                    }
                }
            }
            None => begin_upload(&mut conn, enc.ciphertext.len()).await?,
        };
        s.client
            .upload_save(
                &key,
                &arveil_core::client::PendingUpload {
                    blob_id: blob_id.clone(),
                    read_capability: read_capability.clone(),
                    file_key: enc.file_key.clone(),
                    nonce: enc.nonce.clone(),
                    ciphertext_hash: enc.ciphertext_hash.clone(),
                    size: enc.ciphertext.len() as u64,
                },
            )
            .map_err(storage_error("uploads"))?;

        let mut sent = 0usize;
        while offset < enc.ciphertext.len() {
            let end = (offset + BLOB_CHUNK).min(enc.ciphertext.len());
            match conn
                .request(Payload::BlobChunk {
                    blob_id: blob_id.clone(),
                    offset: offset as u64,
                    data: enc.ciphertext[offset..end].to_vec(),
                })
                .await?
            {
                Payload::Ack => {}
                other => return Err(CliError::Protocol(format!("unexpected reply: {other:?}"))),
            }
            offset = end;
            sent += 1;
            if let Some(limit) = crash_after_chunks()
                && sent >= limit
            {
                return Err(CliError::Interrupted {
                    exit_code: 4,
                    message: format!(
                        "simulated interruption after {sent} chunk(s), at offset {offset}"
                    ),
                });
            }
        }
        let expiry = match conn
            .request(Payload::BlobCommit {
                blob_id: blob_id.clone(),
                ciphertext_hash: enc.ciphertext_hash.clone(),
                requested_expiry: blob_expiry(config),
            })
            .await?
        {
            Payload::BlobCommitted { effective_expiry } => effective_expiry,
            other => return Err(CliError::Protocol(format!("unexpected reply: {other:?}"))),
        };
        conn.close().await;
        Ok((blob_id, read_capability, expiry))
    }
    .await?;
    s.client
        .upload_clear(&key)
        .map_err(storage_error("uploads"))?;
    record_change(StateChange::BlobUploaded {
        blob_id: blob_id.clone(),
        ciphertext_size: enc.ciphertext.len(),
        expires_at: expiry,
    });

    let descriptor = FileDescriptor {
        version: attachments::VERSION,
        blob_id,
        read_capability,
        file_key: enc.file_key,
        nonce: enc.nonce,
        ciphertext_hash: enc.ciphertext_hash,
        size: plaintext.len() as u64,
        name: name.clone(),
        mime: "application/octet-stream".into(),
    };
    let body = descriptor.encode().map_err(protocol_error("descriptor"))?;
    // The transfer yielded to other commands; reload the conversation and
    // MLS group before applying the descriptor to avoid committing stale state.
    let conv = select_conversation(&s, group)?;
    let mut group = engine
        .load_group(&conv.group_id)
        .map_err(storage_error("mls load"))?;
    guard_revoked(&conv, &group)?;
    let event_id = random_delivery_id()?;
    let fan = s
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
            s.delivery.record_event(
                &conv.group_id,
                &event_id,
                "sent-file",
                format!("{name} ({} bytes)", plaintext.len()).as_bytes(),
            )?;
            let bytes = msg.to_bytes().map_err(|_| rusqlite::Error::InvalidQuery)?;
            enqueue_for_all(&s, &conv.peers, Some(&event_id), &bytes)
        })
        .map_err(storage_error("send unit"))?;
    record_message(
        MessageReceipt {
            group_id: conv.group_id.clone(),
            event_id: event_id.clone(),
            kind: MessageKind::File,
            local_acceptance: fan.local_acceptance(),
        },
        group.current_epoch(),
    );
    fan.record_queued_deliveries(&event_id);
    let n = async {
        let mut conn = connect(config, &s, &b).await?;
        let n = publish_pending(config, &s, &mut conn).await?;
        conn.close().await;
        Ok::<_, CliError>(n)
    }
    .await?;
    record_change(StateChange::EnvelopesPublished {
        count: n,
        pending: false,
    });
    Ok(())
}

/// Download every announced file, verify hash and AEAD, write it under
/// `<data-dir>/downloads`, and record the outcome as an event. An expired
/// or unknown blob becomes a visible `file-unavailable` event, never a
/// silent skip.
async fn download_pending(
    s: &Session,
    conn: &mut Connection,
    config: &ProfileConfig,
) -> Result<(), CliError> {
    let pending = s
        .delivery
        .events_of_kind("file-pending")
        .map_err(storage_error("events"))?;
    if pending.is_empty() {
        return Ok(());
    }
    let dir = config.dir().join("downloads");
    std::fs::create_dir_all(&dir).map_err(filesystem_error("downloads dir"))?;
    for (event_id, _, body) in pending {
        let d = match FileDescriptor::decode(&body) {
            Ok(d) => d,
            Err(e) => {
                s.delivery
                    .update_event(
                        &event_id,
                        "file-unavailable",
                        format!("bad descriptor: {e}").as_bytes(),
                    )
                    .map_err(storage_error("event"))?;
                continue;
            }
        };
        // Ciphertext accumulates in a `.part` file, so a download that was
        // interrupted continues where it stopped instead of starting over.
        let part = dir.join(format!("{}.part", d.safe_name()));
        let mut ciphertext = std::fs::read(&part).unwrap_or_default();
        if !ciphertext.is_empty() {
            if ciphertext.len() as u64 > d.size + 16 {
                // Not ours, or corrupt: start again rather than guess.
                ciphertext.clear();
            } else {
                record_change(StateChange::FileDownloadResumed {
                    name: d.safe_name(),
                    offset: ciphertext.len(),
                });
            }
        }
        let mut failure: Option<String> = None;
        let mut chunks = 0usize;
        loop {
            match conn
                .request(Payload::BlobFetch {
                    blob_id: d.blob_id.clone(),
                    read_capability: d.read_capability.clone(),
                    offset: ciphertext.len() as u64,
                    length: BLOB_CHUNK as u32,
                })
                .await
            {
                Ok(Payload::BlobData { total_size, data }) => {
                    if data.is_empty() {
                        break;
                    }
                    ciphertext.extend_from_slice(&data);
                    std::fs::write(&part, &ciphertext).map_err(filesystem_error("partial file"))?;
                    chunks += 1;
                    if let Some(limit) = crash_after_download_chunks()
                        && chunks >= limit
                    {
                        return Err(CliError::Interrupted {
                            exit_code: 4,
                            message: format!(
                                "simulated interruption after {chunks} chunk(s), at {} bytes",
                                ciphertext.len()
                            ),
                        });
                    }
                    if ciphertext.len() as u64 >= total_size {
                        break;
                    }
                }
                Ok(other) => {
                    failure = Some(format!("unexpected reply {other:?}"));
                    break;
                }
                Err(e) if e.kind() == FailureKind::Transport => {
                    // A request timeout invalidates the carrier. Keep both
                    // the pending event and any verified partial bytes so a
                    // later sync can reconnect and resume the download.
                    return Err(e);
                }
                Err(e) => {
                    failure = Some(e.to_string());
                    break;
                }
            }
        }
        let outcome = match failure {
            Some(reason) => Err(reason),
            None => attachments::decrypt(&d, &ciphertext)
                .map_err(|e| e.to_string())
                .and_then(|plain| {
                    let target = dir.join(d.safe_name());
                    std::fs::write(&target, &plain)
                        .map(|_| target)
                        .map_err(|e| e.to_string())
                })
                .inspect(|_| {
                    // The whole file is verified and written: the partial
                    // copy has no further use.
                    let _ = std::fs::remove_file(&part);
                }),
        };
        match outcome {
            Ok(target) => {
                s.delivery
                    .update_event(
                        &event_id,
                        "received-file",
                        target.to_string_lossy().as_bytes(),
                    )
                    .map_err(storage_error("event"))?;
                record_change(StateChange::FileSaved {
                    name: d.safe_name(),
                    path: target,
                });
            }
            Err(reason) => {
                s.delivery
                    .update_event(
                        &event_id,
                        "file-unavailable",
                        format!("{} ({reason})", d.safe_name()).as_bytes(),
                    )
                    .map_err(storage_error("event"))?;
                record_change(StateChange::FileUnavailable {
                    name: d.safe_name(),
                    reason,
                });
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures_util::SinkExt;
    use std::sync::atomic::Ordering;

    fn enrolled_test_application(label: &str, url: &str) -> (PathBuf, String, Application) {
        let profile = std::env::temp_dir().join(format!(
            "arveil-{label}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        std::fs::create_dir_all(&profile).unwrap();
        let realm_id = vec![7; 32];
        let realm_noise = vec![8; 32];
        let conn = SharedConn::open_file(&profile.join("client.db")).unwrap();
        let client = Client::open(conn).unwrap();
        let root = client.identity_new().unwrap();
        client.device_new(1_800_000_000).unwrap();
        client
            .realm_save(&realm_id, &root.public(), &realm_noise, url)
            .unwrap();
        client.realm_mark_enrolled(&realm_id).unwrap();
        client
            .mailbox_save(&OwnMailbox {
                mailbox_id: vec![9; 16],
                read_capability: vec![10; 32],
                write_capability: vec![11; 32],
            })
            .unwrap();
        drop(client);
        let bootstrap = format!(
            "arveil-bootstrap:v0:{}:{}:{}:{url}",
            hex::encode(&realm_id),
            hex::encode(root.public().as_bytes()),
            hex::encode(&realm_noise)
        );
        let app = Application::open(ProfileConfig::unencrypted(&profile)).unwrap();
        (profile, bootstrap, app)
    }

    #[test]
    fn application_errors_identify_the_failed_operation() {
        let profile = std::env::temp_dir().join(format!(
            "arveil-errors-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let app = Application::open(ProfileConfig::unencrypted(&profile)).unwrap();
        let error = app
            .create_conversation("not-a-bootstrap", &["not-a-route"])
            .expect_err("invalid input must fail");
        assert_eq!(error.operation(), Some(Operation::CreateConversation));
        assert!(matches!(error, ApplicationError::Domain { .. }));
        assert_eq!(error.exit_code(), None);
        assert!(error.partial_result().changes.is_empty());
        assert!(error.partial_result().messages.is_empty());
    }

    #[tokio::test]
    async fn partial_results_keep_a_locally_accepted_message() {
        let receipt = MessageReceipt {
            group_id: vec![1],
            event_id: vec![2],
            kind: MessageKind::Text,
            local_acceptance: LocalAcceptance::PersistedToOutbox {
                envelopes: 1,
                peers_without_route: 0,
                revoked_devices: 0,
            },
        };
        let error = run_operation(Operation::SendMessage, async {
            // This is the boundary immediately after the atomic send
            // unit commits and immediately before publication.
            record_message(receipt.clone(), 7);
            Err(CliError::Transport("publication failed".into()))
        })
        .await
        .expect_err("publication must fail");
        let partial = error.partial_result();
        assert_eq!(partial.messages, vec![receipt.clone()]);
        assert_eq!(
            partial.changes,
            vec![StateChange::MessageQueued { receipt, epoch: 7 }]
        );
        assert!(matches!(error, ApplicationError::Transport { .. }));
    }

    #[test]
    fn a_second_session_over_one_profile_is_refused_and_sharing_is_explicit() {
        let profile = std::env::temp_dir().join(format!(
            "arveil-executor-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let first = Application::open(ProfileConfig::unencrypted(&profile)).unwrap();
        // Another spelling of the same directory is the same profile, and a
        // second configuration must not silently inherit the first one.
        let again = Application::open(ProfileConfig::unencrypted(profile.join("child").join("..")));
        assert!(matches!(
            again,
            Err(ApplicationOpenError::AlreadyOpen { .. })
        ));
        let shared = first.clone();
        assert!(Arc::ptr_eq(&first.executor, &shared.executor));

        // Closing releases the profile, and reopening validates again.
        first.close();
        let reopened = Application::open(ProfileConfig::unencrypted(&profile))
            .expect("a closed profile opens again");
        reopened.close();
        std::fs::remove_dir_all(profile).ok();
    }

    #[test]
    fn a_key_of_the_wrong_shape_never_reaches_storage() {
        let profile = std::env::temp_dir().join("arveil-key-shape");
        assert!(matches!(
            ProfileConfig::encrypted(&profile, "not-hexadecimal"),
            Err(ApplicationOpenError::BadKey)
        ));
        assert!(matches!(
            ProfileConfig::encrypted(&profile, "a".repeat(63)),
            Err(ApplicationOpenError::BadKey)
        ));
        assert!(!profile.exists(), "a rejected key creates nothing");
        let config = ProfileConfig::encrypted(&profile, "a".repeat(64)).expect("64 hex characters");
        assert!(config.is_encrypted());
        // The key stays out of anything that can be printed.
        let shown = format!("{config:?}");
        assert!(shown.contains("<set>") && !shown.contains(&"a".repeat(64)));
    }

    #[test]
    fn the_wrong_key_fails_when_the_profile_opens() {
        let profile = std::env::temp_dir().join(format!(
            "arveil-wrong-key-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        std::fs::remove_dir_all(&profile).ok();
        let key = "b".repeat(64);
        let created = Application::open(ProfileConfig::encrypted(&profile, &key).unwrap())
            .expect("a new encrypted profile opens");
        created.close();

        let other = Application::open(ProfileConfig::encrypted(&profile, "c".repeat(64)).unwrap());
        assert!(
            matches!(other, Err(ApplicationOpenError::Unusable { .. })),
            "the wrong key must fail at open, not at the first command"
        );
        // The profile is still free, and its own key still opens it.
        Application::open(ProfileConfig::encrypted(&profile, &key).unwrap())
            .expect("the right key still opens the profile")
            .close();
        std::fs::remove_dir_all(profile).ok();
    }

    #[test]
    fn work_after_close_fails_instead_of_reopening_the_profile() {
        let profile = std::env::temp_dir().join(format!(
            "arveil-closed-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let app = Application::open(ProfileConfig::unencrypted(&profile)).unwrap();
        let clone = app.clone();
        app.close();
        // Idempotent, and a clone is closed too.
        app.close();
        let error = clone
            .conversations()
            .expect_err("a closed session accepts no work");
        assert!(matches!(error, ApplicationError::Internal { .. }));
        std::fs::remove_dir_all(profile).ok();
    }

    #[cfg(unix)]
    #[test]
    fn nonexistent_profile_below_a_symlink_has_one_canonical_executor() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "arveil-symlink-executor-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let real_parent = root.join("real");
        let linked_parent = root.join("linked");
        std::fs::create_dir_all(&real_parent).unwrap();
        symlink(&real_parent, &linked_parent).unwrap();

        let through_link =
            Application::open(ProfileConfig::unencrypted(linked_parent.join("profile"))).unwrap();
        let through_real =
            Application::open(ProfileConfig::unencrypted(real_parent.join("profile")));
        assert!(matches!(
            through_real,
            Err(ApplicationOpenError::AlreadyOpen { .. })
        ));

        through_link.close();
        std::fs::remove_dir_all(root).ok();
    }

    /// Writes `count` events straight into a profile's event log, the way
    /// a conversation would, so paging can be exercised without a relay.
    fn record_events(profile: &Path, group: &[u8], kinds: &[(&str, &str)]) {
        let conn = SharedConn::open_file(&profile.join("client.db")).unwrap();
        let client = Client::open(conn).unwrap();
        let delivery = client.delivery().unwrap();
        for (kind, body) in kinds {
            let event_id = format!("{}-{body}", String::from_utf8_lossy(group)).into_bytes();
            delivery
                .record_event(group, &event_id, kind, body.as_bytes())
                .unwrap();
        }
    }

    #[tokio::test]
    async fn progress_reaches_a_subscriber_while_the_operation_still_runs() {
        let watchers = Arc::new(Subscribers::default());
        let subscription = watchers.subscribe();
        let seen = std::cell::RefCell::new(Vec::new());
        let result = WATCHERS
            .scope(
                (Operation::Sync, watchers.clone()),
                run_operation(Operation::Sync, async {
                    record_change(StateChange::EnvelopesPublished {
                        count: 2,
                        pending: false,
                    });
                    // Already delivered, with the operation still running.
                    seen.borrow_mut().push(subscription.try_recv());
                    record_change(StateChange::SyncCompleted {
                        fetched: 2,
                        new: 1,
                        acked: 2,
                    });
                    seen.borrow_mut().push(subscription.try_recv());
                    Ok(())
                }),
            )
            .await
            .expect("the operation succeeds");

        let seen = seen.into_inner();
        assert!(matches!(
            seen[0],
            Some(ProgressEvent {
                sequence: 0,
                operation: Operation::Sync,
                kind: ProgressKind::EnvelopesPublished {
                    count: 2,
                    pending: false
                },
            })
        ));
        assert!(matches!(
            seen[1],
            Some(ProgressEvent {
                sequence: 1,
                kind: ProgressKind::Synced {
                    fetched: 2,
                    new: 1,
                    acked: 2
                },
                ..
            })
        ));
        // Progress does not replace the durable answer.
        assert_eq!(result.changes.len(), 2);
        assert!(subscription.try_recv().is_none());
    }

    #[tokio::test]
    async fn a_subscriber_that_falls_behind_is_told_what_it_lost() {
        let watchers = Arc::new(Subscribers::default());
        let subscription = watchers.subscribe();
        let overflow = 5;
        let result = WATCHERS
            .scope(
                (Operation::Sync, watchers.clone()),
                run_operation(Operation::Sync, async {
                    for count in 0..WATCH_CAPACITY + overflow {
                        record_change(StateChange::EnvelopesPublished {
                            count,
                            pending: false,
                        });
                    }
                    Ok(())
                }),
            )
            .await
            .expect("the operation succeeds");

        // Nothing was lost from the durable result, whatever the subscriber
        // managed to keep up with.
        assert_eq!(result.changes.len(), WATCH_CAPACITY + overflow);

        let mut received = Vec::new();
        while let Some(event) = subscription.try_recv() {
            received.push(event);
        }
        assert_eq!(received.len(), WATCH_CAPACITY);
        // Draining made room, so the next publication carries the gap.
        WATCHERS
            .scope(
                (Operation::Sync, watchers.clone()),
                run_operation(Operation::Sync, async {
                    record_change(StateChange::SyncCompleted {
                        fetched: 0,
                        new: 0,
                        acked: 0,
                    });
                    Ok(())
                }),
            )
            .await
            .expect("the operation succeeds");
        let gap = subscription.try_recv().expect("a gap is reported");
        assert!(
            matches!(gap.kind, ProgressKind::Gap { dropped } if dropped == overflow),
            "expected {overflow} dropped events, got {:?}",
            gap.kind
        );
        assert!(matches!(
            subscription.try_recv().map(|event| event.kind),
            Some(ProgressKind::Synced { .. })
        ));
    }

    #[tokio::test]
    async fn dropping_a_subscription_unsubscribes() {
        let watchers = Arc::new(Subscribers::default());
        let subscription = watchers.subscribe();
        assert_eq!(watchers.inner.lock().unwrap().len(), 1);
        drop(subscription);
        WATCHERS
            .scope(
                (Operation::Sync, watchers.clone()),
                run_operation(Operation::Sync, async {
                    record_change(StateChange::SyncCompleted {
                        fetched: 0,
                        new: 0,
                        acked: 0,
                    });
                    Ok(())
                }),
            )
            .await
            .expect("the operation succeeds");
        assert!(
            watchers.inner.lock().unwrap().is_empty(),
            "a gone subscriber is forgotten at the next publication"
        );
    }

    #[test]
    fn history_pages_do_not_shift_when_events_arrive_between_them() {
        let profile = std::env::temp_dir().join(format!(
            "arveil-paging-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        std::fs::remove_dir_all(&profile).ok();
        std::fs::create_dir_all(&profile).unwrap();
        let group = b"g".to_vec();
        record_events(
            &profile,
            &group,
            &[
                ("message", "one"),
                ("message", "two"),
                ("message", "three"),
                ("message", "four"),
            ],
        );

        let app = Application::open(ProfileConfig::unencrypted(&profile)).unwrap();
        let newest = app.history_page(&group, None, 2).unwrap();
        let bodies = |page: &HistoryPage| {
            page.events
                .iter()
                .map(|event| String::from_utf8_lossy(&event.body).into_owned())
                .collect::<Vec<_>>()
        };
        assert_eq!(bodies(&newest), vec!["three", "four"]);
        let next = newest.next.expect("an older page exists");

        // Two more events land while the caller is still reading backwards.
        record_events(&profile, &group, &[("message", "five"), ("message", "six")]);

        let older = app.history_page(&group, Some(next), 2).unwrap();
        assert_eq!(
            bodies(&older),
            vec!["one", "two"],
            "a page shifted under the reader"
        );
        assert!(older.next.is_none(), "the conversation starts here");

        // The new events are where a fresh read from the top finds them.
        let fresh = app.history_page(&group, None, 2).unwrap();
        assert_eq!(bodies(&fresh), vec!["five", "six"]);

        // The cap holds whatever the caller asks for.
        let capped = app
            .history_page(&group, None, MAX_HISTORY_PAGE * 10)
            .unwrap();
        assert_eq!(capped.events.len(), 6);
        assert!(capped.next.is_none());

        app.close();
        std::fs::remove_dir_all(profile).ok();
    }

    #[test]
    fn a_panic_ends_the_session_and_leaves_the_profile_openable() {
        let profile = std::env::temp_dir().join(format!(
            "arveil-panic-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        std::fs::remove_dir_all(&profile).ok();
        std::fs::create_dir_all(&profile).unwrap();

        let app = Application::open(ProfileConfig::unencrypted(&profile)).unwrap();
        // The probe writes inside a transaction and then panics.
        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(|_| {}));
        let failed = app
            .execute(ClientCommand::PanicProbe)
            .expect_err("the probe always fails");
        std::panic::set_hook(previous);
        assert!(
            matches!(failed, ApplicationError::Panicked { .. }),
            "expected a recognizable failure, got {failed:?}"
        );

        // The session is over: nothing else runs on it, and it says so
        // rather than answering from state nobody described.
        let after = app
            .conversations()
            .expect_err("a poisoned session accepts no work");
        assert!(matches!(after, ApplicationError::Panicked { .. }));

        // Closing releases the profile, and what the panic was writing is
        // not there: the transaction rolled back on the way out.
        app.close();
        let reopened = Application::open(ProfileConfig::unencrypted(&profile))
            .expect("the profile opens again");
        assert!(reopened.conversations().unwrap().is_empty());
        let conn = SharedConn::open_file(&profile.join("client.db")).unwrap();
        assert_eq!(
            conn.count("events").unwrap(),
            0,
            "a half written row survived"
        );
        reopened.close();
        std::fs::remove_dir_all(profile).ok();
    }

    #[test]
    fn work_queued_behind_a_panic_is_answered() {
        let profile = std::env::temp_dir().join(format!(
            "arveil-panic-queue-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        std::fs::remove_dir_all(&profile).ok();
        std::fs::create_dir_all(&profile).unwrap();
        let app = Application::open(ProfileConfig::unencrypted(&profile)).unwrap();

        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(|_| {}));
        let panicking = app.clone();
        let probe = std::thread::spawn(move || panicking.execute(ClientCommand::PanicProbe));
        assert!(matches!(
            probe.join().unwrap(),
            Err(ApplicationError::Panicked { .. })
        ));
        std::panic::set_hook(previous);

        // Everything that follows is answered, not left waiting.
        for _ in 0..4 {
            assert!(matches!(
                app.conversations(),
                Err(ApplicationError::Panicked { .. })
            ));
        }
        app.close();
        std::fs::remove_dir_all(profile).ok();
    }

    #[test]
    fn a_saturated_profile_refuses_work_and_still_answers_queries() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("ws://{}", listener.local_addr().unwrap());
        let (profile, bootstrap, app) = enrolled_test_application("saturated", &url);
        let (release_tx, release_rx) = mpsc::channel::<()>();
        let relay = std::thread::spawn(move || {
            // Accept and answer nothing, so the syncs stay in flight.
            let mut held = Vec::new();
            while release_rx.try_recv().is_err() {
                listener.set_nonblocking(true).unwrap();
                if let Ok((socket, _)) = listener.accept() {
                    held.push(socket);
                }
                std::thread::sleep(std::time::Duration::from_millis(5));
            }
        });

        let syncs: Vec<_> = (0..MAX_ACTIVE_SYNCS)
            .map(|_| {
                let syncing = app.clone();
                let bootstrap = bootstrap.clone();
                std::thread::spawn(move || syncing.sync(&bootstrap))
            })
            .collect();

        // Wait for both to be admitted rather than for a clock to pass.
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while app.executor.active.syncs.load(Ordering::Acquire) < MAX_ACTIVE_SYNCS {
            assert!(std::time::Instant::now() < deadline, "syncs never started");
            std::thread::sleep(std::time::Duration::from_millis(5));
        }

        let refused = app
            .sync(&bootstrap)
            .expect_err("a third sync must not be admitted");
        assert!(
            matches!(
                refused,
                ApplicationError::Busy {
                    operation: Operation::Sync,
                    active
                } if active == MAX_ACTIVE_SYNCS
            ),
            "expected a typed refusal, got {refused:?}"
        );
        assert!(refused.partial_result().changes.is_empty());

        // A local query is not held behind the saturated kind.
        let before = std::time::Instant::now();
        assert!(app.conversations().unwrap().is_empty());
        assert!(
            before.elapsed() < std::time::Duration::from_secs(1),
            "a query waited behind saturated syncs"
        );

        release_tx.send(()).unwrap();
        relay.join().unwrap();
        for sync in syncs {
            assert!(sync.join().unwrap().is_err());
        }
        // Slots come back when the work finishes, not when a caller leaves.
        assert_eq!(app.executor.active.syncs.load(Ordering::Acquire), 0);
        app.close();
        std::fs::remove_dir_all(profile).ok();
    }

    #[test]
    fn silent_relay_does_not_block_local_history() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("ws://{}", listener.local_addr().unwrap());
        let (profile, bootstrap, app) = enrolled_test_application("silent-relay", &url);
        let syncing = app.clone();
        let (accepted_tx, accepted_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let silent_peer = std::thread::spawn(move || {
            let (socket, _) = listener.accept().unwrap();
            accepted_tx.send(()).unwrap();
            release_rx.recv().unwrap();
            drop(socket);
        });
        let sync = std::thread::spawn(move || syncing.sync(&bootstrap));
        accepted_rx.recv().unwrap();

        let before = std::time::Instant::now();
        assert!(app.history().unwrap().is_empty());
        assert!(
            before.elapsed() < std::time::Duration::from_secs(1),
            "local history waited behind a silent relay"
        );

        release_tx.send(()).unwrap();
        silent_peer.join().unwrap();
        assert!(matches!(
            sync.join().unwrap(),
            Err(ApplicationError::Transport { .. })
        ));
        drop(app);
        std::fs::remove_dir_all(profile).ok();
    }

    #[test]
    fn overlapping_sync_requests_never_run_together() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("ws://{}", listener.local_addr().unwrap());
        let (profile, bootstrap, app) = enrolled_test_application("sync-single-flight", &url);
        let (accepted_tx, accepted_rx) = mpsc::channel();
        let (inspect_tx, inspect_rx) = mpsc::channel();
        let (overlap_tx, overlap_rx) = mpsc::channel();
        let server = std::thread::spawn(move || {
            let (first, _) = listener.accept().unwrap();
            accepted_tx.send(()).unwrap();
            inspect_rx.recv().unwrap();
            listener.set_nonblocking(true).unwrap();
            let overlapping = match listener.accept() {
                Ok((second, _)) => {
                    drop(second);
                    true
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => false,
                Err(error) => panic!("second accept failed: {error}"),
            };
            overlap_tx.send(overlapping).unwrap();
            drop(first);
            if !overlapping {
                listener.set_nonblocking(false).unwrap();
                let (second, _) = listener.accept().unwrap();
                drop(second);
            }
        });

        let submit_sync = || {
            let (reply, result) = mpsc::sync_channel(1);
            app.executor
                .submit(Request {
                    command: ClientCommand::Sync {
                        bootstrap: bootstrap.clone(),
                    },
                    reply,
                })
                .expect("executor accepts work");
            result
        };
        let first = submit_sync();
        accepted_rx.recv().unwrap();
        let second = submit_sync();
        // FIFO delivery guarantees the executor has observed the second sync
        // before it services this later local query.
        assert!(app.history().unwrap().is_empty());
        inspect_tx.send(()).unwrap();
        assert!(!overlap_rx.recv().unwrap(), "two syncs opened concurrently");

        assert!(matches!(
            first.recv().unwrap(),
            Err(ApplicationError::Transport { .. })
        ));
        assert!(matches!(
            second.recv().unwrap(),
            Err(ApplicationError::Transport { .. })
        ));
        server.join().unwrap();
        drop(app);
        std::fs::remove_dir_all(profile).ok();
    }

    fn pairing_test_profile(label: &str, expires_at: u64) -> (PathBuf, Application, Vec<u8>) {
        let profile = std::env::temp_dir().join(format!(
            "arveil-{label}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let client = open_client(&ProfileConfig::unencrypted(&profile)).unwrap();
        client.device_pending_new().unwrap();
        let session_id = label.as_bytes().to_vec();
        client
            .pairing_session_start(&session_id, "test-code", expires_at)
            .unwrap();
        client
            .pairing_session_ready(
                &session_id,
                "1234-5678",
                b"credential",
                b"manifest",
                b"root",
            )
            .unwrap();
        drop(client);
        let app = Application::open(ProfileConfig::unencrypted(&profile)).unwrap();
        (profile, app, session_id)
    }

    #[test]
    fn pairing_cancellation_clears_only_the_named_session() {
        let (profile, app, session_id) = pairing_test_profile("pair-cancel", u64::MAX);
        let wrong = app.cancel_pairing(b"another-session").unwrap_err();
        assert!(matches!(wrong, ApplicationError::Domain { .. }));
        assert!(
            open_client(&ProfileConfig::unencrypted(&profile))
                .unwrap()
                .pairing_session(&session_id)
                .unwrap()
                .is_some()
        );

        let cancelled = app.cancel_pairing(&session_id).unwrap();
        assert!(cancelled.operation.changes.iter().any(|change| matches!(
            change,
            StateChange::PairingCancelled { session_id: cancelled } if cancelled == &session_id
        )));
        assert!(
            open_client(&ProfileConfig::unencrypted(&profile))
                .unwrap()
                .pairing_session(&session_id)
                .unwrap()
                .is_none()
        );
        drop(app);
        std::fs::remove_dir_all(profile).ok();
    }

    #[test]
    fn expired_pairing_is_removed_before_a_grant_can_be_applied() {
        let (profile, app, session_id) = pairing_test_profile("pair-expired", 1);
        let error = app
            .confirm_pairing("not-even-a-bootstrap", &session_id, "1234-5678")
            .unwrap_err();
        let partial = error.partial_result();
        assert!(matches!(error, ApplicationError::Domain { .. }));
        assert!(partial.changes.iter().any(|change| matches!(
            change,
            StateChange::PairingExpired { session_id: expired } if expired == &session_id
        )));
        assert!(
            open_client(&ProfileConfig::unencrypted(&profile))
                .unwrap()
                .pairing_session(&session_id)
                .unwrap()
                .is_none()
        );
        drop(app);
        std::fs::remove_dir_all(profile).ok();
    }

    #[test]
    fn incorrect_pairing_confirmation_is_rejected_for_the_exact_session() {
        let (profile, app, session_id) = pairing_test_profile("pair-wrong-code", u64::MAX);
        let wrong_session = app
            .confirm_pairing("not-even-a-bootstrap", b"another-session", "1234-5678")
            .unwrap_err();
        assert!(matches!(wrong_session, ApplicationError::Domain { .. }));

        let wrong_code = app
            .confirm_pairing("not-even-a-bootstrap", &session_id, "9999-9999")
            .unwrap_err();
        assert!(matches!(wrong_code, ApplicationError::Domain { .. }));
        assert!(
            open_client(&ProfileConfig::unencrypted(&profile))
                .unwrap()
                .pairing_session(&session_id)
                .unwrap()
                .is_some()
        );
        drop(app);
        std::fs::remove_dir_all(profile).ok();
    }

    struct PairingTestRealm {
        realm_id: Vec<u8>,
        noise: arveil_core::channel::StaticKeypair,
        signing: ed25519_dalek::SigningKey,
        url: String,
    }

    impl PairingTestRealm {
        fn new(url: String) -> Self {
            Self {
                realm_id: vec![7; 32],
                noise: arveil_core::channel::StaticKeypair::generate().unwrap(),
                signing: ed25519_dalek::SigningKey::from_bytes(&[9; 32]),
                url,
            }
        }

        fn bootstrap(&self) -> String {
            format!(
                "arveil-bootstrap:v0:{}:{}:{}:{}",
                hex::encode(&self.realm_id),
                hex::encode(self.signing.verifying_key().as_bytes()),
                hex::encode(&self.noise.public),
                self.url,
            )
        }

        fn signed_endpoints(&self) -> Vec<u8> {
            let list = arveil_core::channel::endpoints::RealmEndpointList {
                version: arveil_core::channel::endpoints::VERSION,
                realm_id: self.realm_id.clone(),
                sequence: 1,
                realm_noise_public_key: self.noise.public.clone(),
                endpoints: vec![arveil_core::channel::endpoints::Endpoint {
                    kind: "test".into(),
                    url: self.url.clone(),
                    priority: 0,
                }],
            };
            arveil_core::signed::sign_value(
                arveil_core::channel::endpoints::CONTEXT,
                &list,
                &self.signing,
            )
            .unwrap()
        }
    }

    async fn serve_completion_connection(
        socket: tokio::net::TcpStream,
        realm: arveil_core::channel::StaticKeypair,
        realm_id: Vec<u8>,
        signed_endpoints: Vec<u8>,
        mailbox_creates: Arc<AtomicUsize>,
    ) {
        use arveil_core::channel::codec::{Frame, Payload};
        use tokio_tungstenite::tungstenite::Message;

        let mut websocket = tokio_tungstenite::accept_async(socket).await.unwrap();
        let message_1 = loop {
            match websocket.next().await.unwrap().unwrap() {
                Message::Binary(bytes) => break bytes,
                _ => continue,
            }
        };
        let mut responder = arveil_core::channel::Responder::new(
            &realm,
            &arveil_core::channel::prologue(&realm_id),
        )
        .unwrap();
        responder.read_message_1(&message_1).unwrap();
        let (message_2, transport) = responder.write_message_2().unwrap();
        websocket
            .send(Message::Binary(message_2.into()))
            .await
            .unwrap();
        let mut channel = arveil_core::channel::Channel::new(transport);

        while let Some(message) = websocket.next().await {
            let Ok(Message::Binary(bytes)) = message else {
                continue;
            };
            let Some(request) = channel.open(&bytes).unwrap() else {
                continue;
            };
            let reply = match request.payload {
                Payload::EndpointListGet => Payload::EndpointList {
                    signed: signed_endpoints.clone(),
                },
                Payload::MailboxCreate => {
                    let number = mailbox_creates.fetch_add(1, Ordering::SeqCst) + 1;
                    // Keep the network step open long enough for a second
                    // confirmation to reach the executor and wait behind it.
                    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                    Payload::MailboxCreated {
                        mailbox_id: vec![number as u8; 16],
                        read_capability: vec![number as u8 + 10; 32],
                        write_capability: vec![number as u8 + 20; 32],
                    }
                }
                Payload::KeyPackagesStatus => Payload::KeyPackagesAvailable { count: 0 },
                Payload::KeyPackagesPublish { .. } => Payload::Ack,
                other => panic!("unexpected completion request: {other:?}"),
            };
            let response = Frame {
                id: request.id,
                payload: reply,
            };
            for bytes in channel.seal(&response).unwrap() {
                if websocket.send(Message::Binary(bytes.into())).await.is_err() {
                    return;
                }
            }
        }
    }

    fn start_completion_relay(
        listener: std::net::TcpListener,
        realm: &PairingTestRealm,
        drop_first: usize,
    ) -> (
        Arc<AtomicUsize>,
        tokio::sync::oneshot::Sender<()>,
        std::thread::JoinHandle<()>,
    ) {
        listener.set_nonblocking(true).unwrap();
        let realm_noise = realm.noise.clone();
        let realm_id = realm.realm_id.clone();
        let signed_endpoints = realm.signed_endpoints();
        let mailbox_creates = Arc::new(AtomicUsize::new(0));
        let server_count = mailbox_creates.clone();
        let (shutdown_tx, mut shutdown_rx) = tokio::sync::oneshot::channel();
        let server = std::thread::spawn(move || {
            tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap()
                .block_on(async move {
                    let listener = tokio::net::TcpListener::from_std(listener).unwrap();
                    let mut connections = Vec::new();
                    let mut accepted = 0usize;
                    loop {
                        tokio::select! {
                            _ = &mut shutdown_rx => break,
                            incoming = listener.accept() => {
                                let (socket, _) = incoming.unwrap();
                                accepted += 1;
                                if accepted <= drop_first {
                                    drop(socket);
                                    continue;
                                }
                                connections.push(tokio::spawn(serve_completion_connection(
                                    socket,
                                    realm_noise.clone(),
                                    realm_id.clone(),
                                    signed_endpoints.clone(),
                                    server_count.clone(),
                                )));
                            }
                        }
                    }
                    for connection in connections {
                        connection.await.unwrap();
                    }
                });
        });
        (mailbox_creates, shutdown_tx, server)
    }

    #[derive(Serialize)]
    struct TestLinkGrant {
        #[serde(with = "serde_bytes")]
        credential: Vec<u8>,
        #[serde(with = "serde_bytes")]
        manifest: Vec<u8>,
        #[serde(with = "serde_bytes")]
        root_public: Vec<u8>,
    }

    fn valid_pairing_test_profile(
        label: &str,
        realm: &PairingTestRealm,
    ) -> (PathBuf, Application, Vec<u8>, String, String, String) {
        let profile = std::env::temp_dir().join(format!(
            "arveil-{label}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let new_client = open_client(&ProfileConfig::unencrypted(&profile)).unwrap();
        let new_device = new_client.device_pending_new().unwrap();

        let admin = Client::open(SharedConn::open_in_memory().unwrap()).unwrap();
        let root = admin.identity_new().unwrap();
        let test_now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs();
        admin.device_new(test_now).unwrap();
        let (credential, manifest) = admin
            .device_authorize(&new_device.keys.public(), test_now)
            .unwrap();
        let bootstrap = realm.bootstrap();
        let session_id = format!("{label}-session").into_bytes();
        let code = arveil_core::pairing::PairingCode {
            realm_id: realm.realm_id.clone(),
            pair_id: session_id.clone(),
            capability: vec![8; 32],
            static_public: new_device.keys.transport_noise.public,
        }
        .to_string_code();
        new_client
            .pairing_session_start(&session_id, &code, u64::MAX)
            .unwrap();
        new_client
            .pairing_session_ready(
                &session_id,
                "1234-5678",
                &credential,
                &manifest,
                root.public().as_bytes(),
            )
            .unwrap();
        drop(new_client);
        let encoded_grant = arveil_core::signed::canonical(&TestLinkGrant {
            credential,
            manifest,
            root_public: root.public().as_bytes().to_vec(),
        })
        .unwrap();
        (
            profile.clone(),
            Application::open(ProfileConfig::unencrypted(&profile)).unwrap(),
            session_id,
            bootstrap,
            "1234-5678".into(),
            format!("arveil-link-grant:v0:{}", hex::encode(encoded_grant)),
        )
    }

    #[test]
    fn pairing_confirmation_resumes_after_network_failure_without_reapplying_the_grant() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("ws://{}", listener.local_addr().unwrap());
        let realm = PairingTestRealm::new(url);
        let (mailbox_creates, shutdown, server) = start_completion_relay(listener, &realm, 1);
        let (profile, app, session_id, bootstrap, sas, _) =
            valid_pairing_test_profile("pair-resume", &realm);

        let first = app
            .confirm_pairing(&bootstrap, &session_id, &sas)
            .unwrap_err();
        assert!(
            matches!(first, ApplicationError::Transport { .. }),
            "unexpected first result: {first:?}"
        );
        let client = open_client(&ProfileConfig::unencrypted(&profile)).unwrap();
        let identity_id = client.identity_id().unwrap().unwrap();
        assert_eq!(
            client.pairing_completion_phase(&session_id).unwrap(),
            Some(PairingCompletionPhase::RealmSaved)
        );
        drop(client);

        let second = app.confirm_pairing(&bootstrap, &session_id, &sas).unwrap();
        assert!(
            second
                .operation
                .changes
                .iter()
                .all(|change| !matches!(change, StateChange::DeviceLinked { .. }))
        );
        assert_eq!(
            open_client(&ProfileConfig::unencrypted(&profile))
                .unwrap()
                .identity_id()
                .unwrap(),
            Some(identity_id)
        );
        let client = open_client(&ProfileConfig::unencrypted(&profile)).unwrap();
        assert_eq!(
            client.pairing_completion_phase(&session_id).unwrap(),
            Some(PairingCompletionPhase::Complete)
        );
        assert_eq!(
            client.mailbox_own().unwrap().unwrap().mailbox_id,
            second.value.mailbox_id
        );
        assert_eq!(mailbox_creates.load(Ordering::SeqCst), 1);
        assert!(!second.value.route.is_empty());
        shutdown.send(()).unwrap();
        server.join().unwrap();
        drop(app);
        std::fs::remove_dir_all(profile).ok();
    }

    #[test]
    fn overlapping_pairing_confirmations_share_one_mailbox_and_route() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("ws://{}", listener.local_addr().unwrap());
        let realm = PairingTestRealm::new(url);
        let (mailbox_creates, shutdown, server) = start_completion_relay(listener, &realm, 0);
        let (profile, app, session_id, bootstrap, sas, _) =
            valid_pairing_test_profile("pair-single-finalizer", &realm);
        let barrier = Arc::new(std::sync::Barrier::new(3));
        let confirm = |application: Application, barrier: Arc<std::sync::Barrier>| {
            let bootstrap = bootstrap.clone();
            let session_id = session_id.clone();
            let sas = sas.clone();
            std::thread::spawn(move || {
                barrier.wait();
                application.confirm_pairing(&bootstrap, &session_id, &sas)
            })
        };
        let first = confirm(app.clone(), barrier.clone());
        let second = confirm(app.clone(), barrier.clone());
        barrier.wait();

        let first = first.join().unwrap().unwrap().value;
        let second = second.join().unwrap().unwrap().value;
        assert_eq!(first.mailbox_id, second.mailbox_id);
        assert_eq!(first.route, second.route);
        assert_eq!(first.endpoint_sequence, second.endpoint_sequence);
        assert_eq!(mailbox_creates.load(Ordering::SeqCst), 1);
        let client = open_client(&ProfileConfig::unencrypted(&profile)).unwrap();
        assert_eq!(
            client.pairing_completion_phase(&session_id).unwrap(),
            Some(PairingCompletionPhase::Complete)
        );
        assert_eq!(
            client.mailbox_own().unwrap().unwrap().mailbox_id,
            first.mailbox_id
        );

        shutdown.send(()).unwrap();
        server.join().unwrap();
        drop(app);
        std::fs::remove_dir_all(profile).ok();
    }

    #[test]
    fn direct_grant_completion_resumes_after_network_failure() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("ws://{}", listener.local_addr().unwrap());
        let realm = PairingTestRealm::new(url);
        let (mailbox_creates, shutdown, server) = start_completion_relay(listener, &realm, 1);
        let (profile, app, _, bootstrap, _, grant) =
            valid_pairing_test_profile("grant-resume", &realm);

        let first = app.complete_link(&bootstrap, &grant).unwrap_err();
        assert!(matches!(first, ApplicationError::Transport { .. }));
        assert_eq!(
            open_client(&ProfileConfig::unencrypted(&profile))
                .unwrap()
                .link_completion_phase()
                .unwrap(),
            Some(PairingCompletionPhase::RealmSaved)
        );

        let completed = app.complete_link(&bootstrap, &grant).unwrap().value;
        let client = open_client(&ProfileConfig::unencrypted(&profile)).unwrap();
        assert_eq!(
            client.link_completion_phase().unwrap(),
            Some(PairingCompletionPhase::Complete)
        );
        assert_eq!(
            client.mailbox_own().unwrap().unwrap().mailbox_id,
            completed.mailbox_id
        );
        assert_eq!(mailbox_creates.load(Ordering::SeqCst), 1);
        assert!(!completed.route.is_empty());

        shutdown.send(()).unwrap();
        server.join().unwrap();
        drop(app);
        std::fs::remove_dir_all(profile).ok();
    }

    #[test]
    fn cancellation_loses_atomically_once_valid_pairing_confirmation_commits() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("ws://{}", listener.local_addr().unwrap());
        let realm = PairingTestRealm::new(url);
        let (profile, app, session_id, bootstrap, sas, _) =
            valid_pairing_test_profile("pair-cancel-race", &realm);
        let (accepted_tx, accepted_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let server = std::thread::spawn(move || {
            let (socket, _) = listener.accept().unwrap();
            accepted_tx.send(()).unwrap();
            release_rx.recv().unwrap();
            drop(socket);
        });
        let confirming = app.clone();
        let confirm_session = session_id.clone();
        let confirmation = std::thread::spawn(move || {
            confirming.confirm_pairing(&bootstrap, &confirm_session, &sas)
        });
        accepted_rx.recv().unwrap();

        let cancellation = app.cancel_pairing(&session_id).unwrap();
        assert_eq!(cancellation.value, PairingCancellation::AlreadyCommitted);
        assert!(cancellation.operation.changes.iter().any(|change| matches!(
            change,
            StateChange::PairingCancellationRejected { session_id: rejected, reason: PairingCancellation::AlreadyCommitted }
                if rejected == &session_id
        )));
        assert!(
            open_client(&ProfileConfig::unencrypted(&profile))
                .unwrap()
                .pairing_session(&session_id)
                .unwrap()
                .is_some()
        );

        release_tx.send(()).unwrap();
        assert!(matches!(
            confirmation.join().unwrap(),
            Err(ApplicationError::Transport { .. })
        ));
        server.join().unwrap();
        drop(app);
        std::fs::remove_dir_all(profile).ok();
    }

    #[test]
    fn connection_end_remains_a_transport_error_without_text_classification() {
        let error = application_error(
            Operation::Sync,
            CliError::Transport("connection ended".into()),
        );
        assert!(matches!(error, ApplicationError::Transport { .. }));
    }
}
