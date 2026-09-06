//! Client-side persistence of identity, device and realm (Phase 0).
//!
//! Secrets are stored in plain SQLite for now; SQLCipher and the OS key
//! store arrive in Phase 2 (ADR-006). The tables are the local half of
//! `docs/DOMAIN_MODEL.md` §1.

use ed25519_dalek::VerifyingKey;
use rusqlite::{OptionalExtension, params};

use crate::channel::StaticKeypair;
use crate::channel::endpoints::{self, RealmEndpointList};
use crate::identity::{
    self, DeviceKeys, DevicePublicKeys, ManifestState, RootKey, USE_ENVELOPE, USE_MLS_LEAF,
    USE_TRANSPORT, Validity,
};
use crate::mls::MlsIdentity;
use crate::storage::SharedConn;

pub const CLIENT_SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS identity (
    id          INTEGER PRIMARY KEY CHECK (id = 1),
    root_seed   BLOB,
    root_public BLOB NOT NULL,
    identity_id BLOB NOT NULL
);
CREATE TABLE IF NOT EXISTS device (
    device_id          BLOB PRIMARY KEY,
    noise_private      BLOB NOT NULL,
    noise_public       BLOB NOT NULL,
    hpke_private       BLOB NOT NULL,
    hpke_public        BLOB NOT NULL,
    mls_signing_secret BLOB NOT NULL,
    mls_signing_public BLOB NOT NULL,
    credential         BLOB NOT NULL,
    credential_hash    BLOB NOT NULL
);
CREATE TABLE IF NOT EXISTS manifest (
    identity_id BLOB NOT NULL,
    sequence    INTEGER NOT NULL,
    signed      BLOB NOT NULL,
    hash        BLOB NOT NULL,
    PRIMARY KEY (identity_id, sequence)
);
-- How far this device got in joining a realm. Kept so a retry after a lost
-- answer, or a restart between steps, continues the same enrollment instead
-- of starting another one. The invite is stored as a hash: what has to be
-- recognised is the operation, and a token written into a local table is a
-- token that can leak out of one.
CREATE TABLE IF NOT EXISTS enrollment (
    id              INTEGER PRIMARY KEY CHECK (id = 1),
    realm_id        BLOB NOT NULL,
    invite_hash     BLOB NOT NULL,
    credential_hash BLOB NOT NULL,
    phase           TEXT NOT NULL,
    updated_at      INTEGER NOT NULL
);
-- The request this device makes for its mailbox, written before it is sent.
-- A retry sends the same key and the same capabilities, so the relay can
-- answer with the mailbox it already made instead of making another: a
-- route carries the write capability inside it, and a second mailbox is a
-- route that stops working.
CREATE TABLE IF NOT EXISTS mailbox_request (
    id               INTEGER PRIMARY KEY CHECK (id = 1),
    request_key      BLOB NOT NULL,
    read_capability  BLOB NOT NULL,
    write_capability BLOB NOT NULL,
    created_at       INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE TABLE IF NOT EXISTS mailbox_own (
    mailbox_id       BLOB PRIMARY KEY,
    read_capability  BLOB NOT NULL,
    write_capability BLOB NOT NULL,
    created_at       INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE TABLE IF NOT EXISTS conversations (
    group_id   BLOB PRIMARY KEY,
    creator    INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE TABLE IF NOT EXISTS peers (
    group_id        BLOB NOT NULL REFERENCES conversations(group_id),
    device_id       BLOB NOT NULL,
    peer_identity   BLOB NOT NULL,
    credential_hash BLOB NOT NULL,
    root_public     BLOB NOT NULL,
    mailbox         BLOB,
    write_cap       BLOB,
    hpke            BLOB,
    revoked         INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (group_id, device_id)
);
CREATE TABLE IF NOT EXISTS identity_devices (
    device_id       BLOB PRIMARY KEY,
    credential_hash BLOB NOT NULL,
    revoked         INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS outgoing_files (
    path            TEXT PRIMARY KEY,
    blob_id         BLOB NOT NULL,
    read_capability BLOB NOT NULL,
    file_key        BLOB NOT NULL,
    nonce           BLOB NOT NULL,
    ciphertext_hash BLOB NOT NULL,
    size            INTEGER NOT NULL,
    created_at      INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE TABLE IF NOT EXISTS contacts (
    identity_id BLOB PRIMARY KEY,
    root_public BLOB NOT NULL,
    name        TEXT,
    verified    INTEGER NOT NULL DEFAULT 0,
    verified_at INTEGER,
    first_seen  INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE TABLE IF NOT EXISTS pairing_pending (
    id          INTEGER PRIMARY KEY CHECK (id = 1),
    sas         TEXT NOT NULL,
    credential  BLOB NOT NULL,
    manifest    BLOB NOT NULL,
    root_public BLOB NOT NULL
);
CREATE TABLE IF NOT EXISTS pairing_sessions (
    session_id  BLOB PRIMARY KEY,
    code        TEXT NOT NULL,
    expires_at  INTEGER NOT NULL,
    sas         TEXT,
    credential  BLOB,
    manifest    BLOB,
    root_public BLOB
);
CREATE TABLE IF NOT EXISTS pairing_completion (
    session_id BLOB PRIMARY KEY REFERENCES pairing_sessions(session_id),
    phase      INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS link_completion (
    id          INTEGER PRIMARY KEY CHECK (id = 1),
    credential  BLOB NOT NULL,
    manifest    BLOB NOT NULL,
    root_public BLOB NOT NULL,
    phase       INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS archived_events (
    group_id   BLOB NOT NULL,
    event_id   BLOB NOT NULL,
    kind       TEXT NOT NULL,
    body       BLOB NOT NULL,
    created_at INTEGER NOT NULL,
    file_name  TEXT,
    PRIMARY KEY (group_id, event_id)
);
CREATE TABLE IF NOT EXISTS peer_manifests (
    identity_id BLOB PRIMARY KEY,
    sequence    INTEGER NOT NULL,
    hash        BLOB NOT NULL
);
CREATE TABLE IF NOT EXISTS realm (
    realm_id          BLOB PRIMARY KEY,
    signing_public    BLOB NOT NULL,
    noise_public      BLOB NOT NULL,
    bootstrap_url     TEXT NOT NULL,
    endpoint_list     BLOB,
    endpoint_sequence INTEGER,
    enrolled          INTEGER NOT NULL DEFAULT 0
);
";

#[derive(Debug, thiserror::Error)]
pub enum ClientError {
    #[error("sqlite: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error(transparent)]
    Identity(#[from] identity::IdentityError),
    #[error(transparent)]
    EndpointList(#[from] endpoints::EndpointListError),
    #[error("client: identity already exists")]
    IdentityExists,
    #[error("client: no identity; run `identity new` first")]
    NoIdentity,
    #[error("client: no device enrolled")]
    NoDevice,
    #[error("client: mls error: {0}")]
    Mls(String),
    #[error("client: this device holds no root key; run this on the administration device")]
    NoRoot,
    #[error("client: link grant does not name this device's keys")]
    GrantMismatch,
    #[error("client: link grant manifest does not list the credential as active")]
    GrantManifest,
    #[error("client: invalid persisted link completion phase {0}")]
    InvalidCompletionPhase(i64),
    #[error("client: device already linked or enrolled")]
    DeviceExists,
    #[error("client: unknown device {0} for this identity")]
    UnknownDevice(String),
    #[error("client: refusing to revoke the device in use; do it from another device")]
    RevokeSelf,
    #[error("client: manifest for an identity with no known root key")]
    UnknownIdentity,
    #[error(
        "client: identity {identity} is a verified contact whose root key does not match this route; refusing to accept it"
    )]
    ContactRootMismatch { identity: String },
    #[error("client: no contact {0} to verify; you have to meet them in a conversation first")]
    NoSuchContact(String),
}

fn hex_of(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// Default credential validity for Phase 0: one year.
pub const DEFAULT_VALIDITY_SECS: u64 = 365 * 24 * 3600;

pub struct Client {
    conn: SharedConn,
}

type DeviceRow = (
    Vec<u8>,
    Vec<u8>,
    Vec<u8>,
    Vec<u8>,
    Vec<u8>,
    Vec<u8>,
    Vec<u8>,
    Vec<u8>,
    Vec<u8>,
);
type RealmRow = (Vec<u8>, Vec<u8>, Vec<u8>, String, Option<Vec<u8>>, i64);

/// A stored device with its private material.
pub struct StoredDevice {
    pub keys: DeviceKeys,
    pub mls_signing_secret: Vec<u8>,
    pub credential: Vec<u8>,
    pub credential_hash: Vec<u8>,
}

impl StoredDevice {
    pub fn mls_identity(&self) -> MlsIdentity {
        MlsIdentity::from_parts(
            &self.keys.device_id,
            &self.mls_signing_secret,
            &self.keys.mls_signing_public_key,
        )
    }
}

/// An upload the realm has partly received.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PendingUpload {
    pub blob_id: Vec<u8>,
    pub read_capability: Vec<u8>,
    pub file_key: Vec<u8>,
    pub nonce: Vec<u8>,
    pub ciphertext_hash: Vec<u8>,
    /// Size of the ciphertext, which is what the realm counts.
    pub size: u64,
}

/// An identity this device has met, and whether the user verified it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Contact {
    pub identity_id: Vec<u8>,
    pub root_public: Vec<u8>,
    pub verified: bool,
    /// A local label. It never travels, never authenticates anything and
    /// never takes part in a check: the safety number does that (M4.8).
    pub name: Option<String>,
}

impl Contact {
    /// What to show: the name if there is one, else a short identity.
    pub fn label(&self) -> String {
        match &self.name {
            Some(n) => n.clone(),
            None => hex_of(&self.identity_id[..4.min(self.identity_id.len())]),
        }
    }
}

/// Safety number over two root keys (M3.2): eight groups of five digits,
/// order independent, so both sides read the same thing.
pub fn safety_number(a_root: &[u8], b_root: &[u8]) -> String {
    let (first, second) = if a_root <= b_root {
        (a_root, b_root)
    } else {
        (b_root, a_root)
    };
    use sha2::{Digest, Sha256};
    let mut h = Sha256::new();
    h.update(b"arveil/safety-number/v1");
    h.update(first);
    h.update(second);
    let d = h.finalize();
    d.chunks(4)
        .map(|c| {
            let n = u32::from_be_bytes([c[0], c[1], c[2], c[3]]) % 100_000;
            format!("{n:05}")
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn normalize_number(s: &str) -> String {
    s.chars().filter(|c| c.is_ascii_digit()).collect()
}

/// A grant received over a pairing channel, waiting for the user to compare
/// the number both devices show.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PendingPairing {
    pub sas: String,
    pub credential: Vec<u8>,
    pub manifest: Vec<u8>,
    pub root_public: Vec<u8>,
}

/// One application-level pairing session. The rendezvous capability remains
/// embedded in `code`; a grant is absent until the Noise exchange completes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PairingSessionState {
    pub session_id: Vec<u8>,
    pub code: String,
    pub expires_at: u64,
    pub sas: Option<String>,
    pub credential: Option<Vec<u8>>,
    pub manifest: Option<Vec<u8>>,
    pub root_public: Option<Vec<u8>>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
#[repr(i64)]
pub enum PairingCompletionPhase {
    Committing = 1,
    LocalApplied = 2,
    RealmSaved = 3,
    EndpointStored = 4,
    RealmEnrolled = 5,
    MailboxStored = 6,
    KeyPackagesPublished = 7,
    Complete = 8,
}

impl PairingCompletionPhase {
    fn from_db(value: i64) -> Option<Self> {
        match value {
            1 => Some(Self::Committing),
            2 => Some(Self::LocalApplied),
            3 => Some(Self::RealmSaved),
            4 => Some(Self::EndpointStored),
            5 => Some(Self::RealmEnrolled),
            6 => Some(Self::MailboxStored),
            7 => Some(Self::KeyPackagesPublished),
            8 => Some(Self::Complete),
            _ => None,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PairingCancellationStatus {
    Cancelled,
    AlreadyCommitted,
    Missing,
}

/// One device of this identity, as its own client knows it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OwnDevice {
    pub device_id: Vec<u8>,
    pub credential_hash: Vec<u8>,
    pub revoked: bool,
}

/// A mailbox this device owns on the realm.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OwnMailbox {
    pub mailbox_id: Vec<u8>,
    pub read_capability: Vec<u8>,
    pub write_capability: Vec<u8>,
}

/// A hash used to recognise an operation without keeping its secret: an
/// invite token is compared this way rather than written down.
pub fn operation_digest(bytes: &[u8]) -> Vec<u8> {
    use sha2::{Digest, Sha256};
    Sha256::digest(bytes).to_vec()
}

/// How far an enrollment has reached. The order matters: a resume skips
/// what is already durable and repeats nothing.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum EnrollmentPhase {
    /// The credential exists; the invite is not redeemed yet, or its answer
    /// never arrived.
    Redeeming,
    /// The realm accepted this device.
    Redeemed,
    /// The signed endpoint list is stored.
    Endpoints,
    /// Mailbox, route and key packages are done.
    Complete,
}

impl EnrollmentPhase {
    fn stored(self) -> &'static str {
        match self {
            Self::Redeeming => "redeeming",
            Self::Redeemed => "redeemed",
            Self::Endpoints => "endpoints",
            Self::Complete => "complete",
        }
    }

    /// A phase this client does not know, from a newer one, is treated as
    /// the earliest: every step after it is written to be safe to repeat.
    fn from_stored(value: &str) -> Self {
        match value {
            "redeemed" => Self::Redeemed,
            "endpoints" => Self::Endpoints,
            "complete" => Self::Complete,
            _ => Self::Redeeming,
        }
    }
}

/// One enrollment in progress, or the one that finished.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EnrollmentProgress {
    pub realm_id: Vec<u8>,
    /// A hash of the invite token, never the token.
    pub invite_hash: Vec<u8>,
    pub credential_hash: Vec<u8>,
    pub phase: EnrollmentPhase,
}

/// What this device asks the realm for when it creates its mailbox. The
/// capabilities are the client's own: the relay stores only their hashes,
/// which is why it can answer a repeat exactly instead of minting again.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MailboxRequest {
    pub request_key: Vec<u8>,
    pub read_capability: Vec<u8>,
    pub write_capability: Vec<u8>,
}

/// A peer device in a conversation and, once learned, how to reach it.
/// One row per device: a person with two devices is two peers, and one's
/// own other devices are peers too (Phase 2, M2.2).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Peer {
    pub identity: Vec<u8>,
    pub device_id: Vec<u8>,
    pub credential_hash: Vec<u8>,
    pub root_public: Vec<u8>,
    pub mailbox: Option<Vec<u8>>,
    pub write_cap: Option<Vec<u8>>,
    pub hpke: Option<Vec<u8>>,
    /// Known revoked by its identity's manifest: receives nothing more.
    pub revoked: bool,
}

impl Peer {
    pub fn routable(&self) -> bool {
        self.mailbox.is_some() && self.write_cap.is_some() && self.hpke.is_some()
    }
}

/// A conversation (one MLS group) and its peers.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Conversation {
    pub group_id: Vec<u8>,
    /// True if this device created the group and is its committer.
    pub creator: bool,
    pub peers: Vec<Peer>,
}

/// A stored realm.
#[derive(Clone, Debug)]
pub struct StoredRealm {
    pub realm_id: Vec<u8>,
    pub signing_public: VerifyingKey,
    pub noise_public: Vec<u8>,
    pub bootstrap_url: String,
    pub endpoint_list: Option<RealmEndpointList>,
    pub enrolled: bool,
}

impl Client {
    pub fn open(conn: SharedConn) -> Result<Self, ClientError> {
        conn.lock().execute_batch(CLIENT_SCHEMA)?;
        Ok(Self { conn })
    }

    /// Open the delivery repository attached to this client's private store.
    pub fn delivery(&self) -> Result<crate::delivery::Delivery, rusqlite::Error> {
        crate::delivery::Delivery::open(self.conn.clone())
    }

    /// Open an MLS engine attached to this client's private store.
    pub fn mls_engine(
        &self,
        identity: MlsIdentity,
    ) -> crate::mls::Engine<impl mls_rs::client_builder::MlsConfig + use<>> {
        crate::mls::open(self.conn.clone(), identity)
    }

    /// Commit one short state transition atomically across client, MLS and
    /// delivery repositories. The backing connection is intentionally not
    /// exposed to callers.
    pub fn unit_of_work<T, E>(&self, f: impl FnOnce() -> Result<T, E>) -> Result<T, E>
    where
        E: From<rusqlite::Error>,
    {
        self.conn.unit_of_work(|_| f())
    }

    /// Create the root key; refuses to overwrite an existing identity.
    pub fn identity_new(&self) -> Result<RootKey, ClientError> {
        if self.root()?.is_some() {
            return Err(ClientError::IdentityExists);
        }
        let root = RootKey::generate()?;
        self.conn.lock().execute(
            "INSERT INTO identity (id, root_seed, root_public, identity_id) VALUES (1, ?1, ?2, ?3)",
            params![
                root.signing.to_bytes().to_vec(),
                root.public().as_bytes().to_vec(),
                root.identity_id()
            ],
        )?;
        Ok(root)
    }

    /// The identity this device belongs to, with or without the root key.
    pub fn identity_id(&self) -> Result<Option<Vec<u8>>, ClientError> {
        Ok(self
            .conn
            .lock()
            .query_row("SELECT identity_id FROM identity WHERE id = 1", [], |r| {
                r.get(0)
            })
            .optional()?)
    }

    pub fn root_public(&self) -> Result<Option<VerifyingKey>, ClientError> {
        let pk: Option<Vec<u8>> = self
            .conn
            .lock()
            .query_row("SELECT root_public FROM identity WHERE id = 1", [], |r| {
                r.get(0)
            })
            .optional()?;
        Ok(pk.map(|p| {
            let p: [u8; 32] = p.as_slice().try_into().expect("32-byte key");
            VerifyingKey::from_bytes(&p).expect("stored key valid")
        }))
    }

    pub fn root(&self) -> Result<Option<RootKey>, ClientError> {
        let seed: Option<Option<Vec<u8>>> = self
            .conn
            .lock()
            .query_row("SELECT root_seed FROM identity WHERE id = 1", [], |r| {
                r.get(0)
            })
            .optional()?;
        Ok(seed.flatten().map(|s| {
            let seed: [u8; 32] = s.as_slice().try_into().expect("32-byte seed");
            RootKey::from_seed(&seed)
        }))
    }

    /// Generate this device's keys (its MLS signing identity uses the device
    /// id as BasicCredential identity), issue its credential and the first
    /// manifest under the local root, and persist everything in one unit of
    /// work. Returns the device and the signed manifest bytes.
    pub fn device_new(&self, now: u64) -> Result<(StoredDevice, Vec<u8>), ClientError> {
        let root = self.root()?.ok_or(ClientError::NoIdentity)?;
        let mut device_id = [0u8; 16];
        getrandom::fill(&mut device_id).map_err(|_| identity::IdentityError::Random)?;
        let mls =
            MlsIdentity::generate_for(&device_id).map_err(|e| ClientError::Mls(e.to_string()))?;
        let mls_signing_public = mls.signing_identity.signature_key.to_vec();
        let mls_signing_secret = mls.secret.as_bytes().to_vec();
        let mut keys = DeviceKeys::generate(mls_signing_public.clone())?;
        keys.device_id = device_id;
        let public: DevicePublicKeys = keys.public();
        let credential = identity::issue_credential(
            &root,
            &public,
            Validity {
                not_before: now.saturating_sub(300),
                not_after: now + DEFAULT_VALIDITY_SECS,
            },
            USE_MLS_LEAF | USE_TRANSPORT | USE_ENVELOPE,
        )?;
        let credential_hash = identity::credential_hash(&credential);
        let previous = self.manifest_state()?;
        // On a first enrolment there is no chain. After a kit recovery there
        // is: this device is the only active one and every credential the
        // chain listed is now lost, so it is revoked in the same manifest.
        let old = self.latest_manifest_body()?;
        let revoked: Vec<Vec<u8>> = old
            .as_ref()
            .map(|b| {
                b.active_credential_hashes
                    .iter()
                    .chain(b.revoked_credential_hashes.iter())
                    .map(|h| h.to_vec())
                    .collect()
            })
            .unwrap_or_default();
        let manifest = identity::issue_manifest(
            &root,
            previous.as_ref(),
            std::slice::from_ref(&credential_hash),
            &revoked,
        )?;
        let (body, state) =
            identity::accept_manifest(&manifest, &root.public(), previous.as_ref())?;

        self.conn.unit_of_work(|c| {
            let conn = c.lock();
            conn.execute(
                "INSERT INTO device (device_id, noise_private, noise_public, hpke_private, hpke_public,
                 mls_signing_secret, mls_signing_public, credential, credential_hash)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                params![
                    keys.device_id.to_vec(),
                    keys.transport_noise.private,
                    keys.transport_noise.public,
                    keys.envelope_hpke.private,
                    keys.envelope_hpke.public,
                    mls_signing_secret,
                    mls_signing_public,
                    credential,
                    credential_hash,
                ],
            )?;
            conn.execute(
                "INSERT INTO manifest (identity_id, sequence, signed, hash) VALUES (?1, ?2, ?3, ?4)",
                params![body.identity_id, state.sequence as i64, manifest, state.hash],
            )?;
            conn.execute(
                "INSERT INTO identity_devices (device_id, credential_hash) VALUES (?1, ?2)",
                params![keys.device_id.to_vec(), credential_hash],
            )?;
            Ok::<_, rusqlite::Error>(())
        })?;

        Ok((
            StoredDevice {
                keys,
                mls_signing_secret,
                credential,
                credential_hash,
            },
            manifest,
        ))
    }

    pub fn device(&self) -> Result<Option<StoredDevice>, ClientError> {
        let row: Option<DeviceRow> =
            self.conn
                .lock()
                .query_row(
                    "SELECT device_id, noise_private, noise_public, hpke_private, hpke_public,
                     mls_signing_secret, mls_signing_public, credential, credential_hash FROM device LIMIT 1",
                    [],
                    |r| {
                        Ok((
                            r.get(0)?,
                            r.get(1)?,
                            r.get(2)?,
                            r.get(3)?,
                            r.get(4)?,
                            r.get(5)?,
                            r.get(6)?,
                            r.get(7)?,
                            r.get(8)?,
                        ))
                    },
                )
                .optional()?;
        Ok(row.map(
            |(id, np, npub, hp, hpub, ms, mp, cred, hash)| StoredDevice {
                keys: DeviceKeys {
                    device_id: id.as_slice().try_into().expect("16-byte device id"),
                    transport_noise: StaticKeypair {
                        private: np,
                        public: npub,
                    },
                    envelope_hpke: StaticKeypair {
                        private: hp,
                        public: hpub,
                    },
                    mls_signing_public_key: mp,
                },
                mls_signing_secret: ms,
                credential: cred,
                credential_hash: hash,
            },
        ))
    }

    /// Phase 2 (M2.1): keys for a device that will be linked by the
    /// administration device. No root, no credential yet; the row holds an
    /// empty credential until [`Client::device_link_complete`].
    pub fn device_pending_new(&self) -> Result<StoredDevice, ClientError> {
        if self.device()?.is_some() {
            return Err(ClientError::DeviceExists);
        }
        let mut device_id = [0u8; 16];
        getrandom::fill(&mut device_id).map_err(|_| identity::IdentityError::Random)?;
        let mls =
            MlsIdentity::generate_for(&device_id).map_err(|e| ClientError::Mls(e.to_string()))?;
        let mls_signing_public = mls.signing_identity.signature_key.to_vec();
        let mls_signing_secret = mls.secret.as_bytes().to_vec();
        let mut keys = DeviceKeys::generate(mls_signing_public.clone())?;
        keys.device_id = device_id;
        self.conn.lock().execute(
            "INSERT INTO device (device_id, noise_private, noise_public, hpke_private, hpke_public,
             mls_signing_secret, mls_signing_public, credential, credential_hash)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, X'', X'')",
            params![
                keys.device_id.to_vec(),
                keys.transport_noise.private,
                keys.transport_noise.public,
                keys.envelope_hpke.private,
                keys.envelope_hpke.public,
                mls_signing_secret,
                mls_signing_public,
            ],
        )?;
        Ok(StoredDevice {
            keys,
            mls_signing_secret,
            credential: Vec::new(),
            credential_hash: Vec::new(),
        })
    }

    /// Body of the newest manifest this client stored.
    pub fn latest_manifest_body(&self) -> Result<Option<identity::DeviceManifest>, ClientError> {
        let Some(signed) = self.latest_manifest()? else {
            return Ok(None);
        };
        let root = self.root_public()?.ok_or(ClientError::NoIdentity)?;
        let (body, _) = identity::accept_manifest(&signed, &root, None)?;
        Ok(Some(body))
    }

    /// Administration device: sign a credential for `public` and the next
    /// manifest that lists it active alongside the current devices. Both are
    /// stored and returned; the root never leaves this device.
    pub fn device_authorize(
        &self,
        public: &DevicePublicKeys,
        now: u64,
    ) -> Result<(Vec<u8>, Vec<u8>), ClientError> {
        let root = self.root()?.ok_or(ClientError::NoRoot)?;
        let credential = identity::issue_credential(
            &root,
            public,
            Validity {
                not_before: now.saturating_sub(300),
                not_after: now + DEFAULT_VALIDITY_SECS,
            },
            USE_MLS_LEAF | USE_TRANSPORT | USE_ENVELOPE,
        )?;
        let hash = identity::credential_hash(&credential);
        let previous = self.manifest_state()?;
        let body = self.latest_manifest_body()?;
        let mut active: Vec<Vec<u8>> = body
            .as_ref()
            .map(|b| {
                b.active_credential_hashes
                    .iter()
                    .map(|h| h.to_vec())
                    .collect()
            })
            .unwrap_or_default();
        let revoked: Vec<Vec<u8>> = body
            .as_ref()
            .map(|b| {
                b.revoked_credential_hashes
                    .iter()
                    .map(|h| h.to_vec())
                    .collect()
            })
            .unwrap_or_default();
        active.push(hash.clone());
        let manifest = identity::issue_manifest(&root, previous.as_ref(), &active, &revoked)?;
        let (mbody, state) =
            identity::accept_manifest(&manifest, &root.public(), previous.as_ref())?;
        self.conn.unit_of_work(|c| {
            let conn = c.lock();
            conn.execute(
                "INSERT INTO manifest (identity_id, sequence, signed, hash) VALUES (?1, ?2, ?3, ?4)",
                params![
                    mbody.identity_id,
                    state.sequence as i64,
                    manifest,
                    state.hash
                ],
            )?;
            conn.execute(
                "INSERT OR REPLACE INTO identity_devices (device_id, credential_hash, revoked) VALUES (?1, ?2, 0)",
                params![public.device_id, hash],
            )?;
            Ok::<_, rusqlite::Error>(())
        })?;
        Ok((credential, manifest))
    }

    /// Own devices as this client knows them.
    pub fn own_devices(&self) -> Result<Vec<OwnDevice>, ClientError> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT device_id, credential_hash, revoked FROM identity_devices ORDER BY rowid",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok(OwnDevice {
                device_id: r.get(0)?,
                credential_hash: r.get(1)?,
                revoked: r.get::<_, i64>(2)? != 0,
            })
        })?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    /// Install a recovered identity on a clean client from an identity kit
    /// (M2.5): the root key and the newest manifest it signed. No device
    /// keys and no MLS state travel this way. Returns the identity id.
    pub fn identity_restore(
        &self,
        root_seed: &[u8],
        latest_manifest: &[u8],
    ) -> Result<Vec<u8>, ClientError> {
        if self.identity_id()?.is_some() {
            return Err(ClientError::IdentityExists);
        }
        let seed: [u8; 32] = root_seed
            .try_into()
            .map_err(|_| identity::IdentityError::Random)?;
        let root = RootKey::from_seed(&seed);
        let (body, state) = identity::accept_manifest(latest_manifest, &root.public(), None)?;
        let identity_id = root.identity_id();
        if body.identity_id != identity_id {
            return Err(ClientError::UnknownIdentity);
        }
        self.conn.unit_of_work(|c| {
            let conn = c.lock();
            conn.execute(
                "INSERT INTO identity (id, root_seed, root_public, identity_id) VALUES (1, ?1, ?2, ?3)",
                params![
                    root.signing.to_bytes().to_vec(),
                    root.public().as_bytes().to_vec(),
                    identity_id
                ],
            )?;
            conn.execute(
                "INSERT INTO manifest (identity_id, sequence, signed, hash) VALUES (?1, ?2, ?3, ?4)",
                params![
                    body.identity_id,
                    state.sequence as i64,
                    latest_manifest,
                    state.hash
                ],
            )?;
            Ok::<_, rusqlite::Error>(())
        })?;
        Ok(identity_id)
    }

    /// Import archived records. They land in their own table: history, never
    /// events (I-07). Returns (imported, already present).
    #[cfg(feature = "recovery")]
    pub fn archive_import(
        &self,
        records: &[crate::recovery::ArchiveRecord],
    ) -> Result<(usize, usize), ClientError> {
        let conn = self.conn.lock();
        let mut new = 0;
        let mut dup = 0;
        for r in records {
            let n = conn.execute(
                "INSERT OR IGNORE INTO archived_events (group_id, event_id, kind, body, created_at, file_name)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                params![r.group_id, r.event_id, r.kind, r.body, r.created_at, r.file_name],
            )?;
            if n == 1 {
                new += 1;
            } else {
                dup += 1;
            }
        }
        Ok((new, dup))
    }

    /// Archived records of one conversation, oldest first.
    pub fn archived(&self, group_id: &[u8]) -> Result<Vec<(String, Vec<u8>)>, ClientError> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT kind, body FROM archived_events WHERE group_id = ?1 ORDER BY created_at, event_id",
        )?;
        let rows = stmt.query_map(params![group_id], |r| Ok((r.get(0)?, r.get(1)?)))?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    /// Conversations that exist only in the archive.
    pub fn archived_groups(&self) -> Result<Vec<Vec<u8>>, ClientError> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT DISTINCT group_id FROM archived_events
             WHERE group_id NOT IN (SELECT group_id FROM conversations) ORDER BY group_id",
        )?;
        let rows = stmt.query_map([], |r| r.get(0))?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    /// Remember an upload in flight so an interrupted one can continue with
    /// the same key, nonce and blob id (M3.3).
    pub fn upload_save(&self, path: &str, u: &PendingUpload) -> Result<(), ClientError> {
        self.conn.lock().execute(
            "INSERT OR REPLACE INTO outgoing_files
             (path, blob_id, read_capability, file_key, nonce, ciphertext_hash, size)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![
                path,
                u.blob_id,
                u.read_capability,
                u.file_key,
                u.nonce,
                u.ciphertext_hash,
                u.size as i64
            ],
        )?;
        Ok(())
    }

    pub fn upload_pending(&self, path: &str) -> Result<Option<PendingUpload>, ClientError> {
        Ok(self
            .conn
            .lock()
            .query_row(
                "SELECT blob_id, read_capability, file_key, nonce, ciphertext_hash, size
                 FROM outgoing_files WHERE path = ?1",
                params![path],
                |r| {
                    Ok(PendingUpload {
                        blob_id: r.get(0)?,
                        read_capability: r.get(1)?,
                        file_key: r.get(2)?,
                        nonce: r.get(3)?,
                        ciphertext_hash: r.get(4)?,
                        size: r.get::<_, i64>(5)? as u64,
                    })
                },
            )
            .optional()?)
    }

    pub fn upload_clear(&self, path: &str) -> Result<(), ClientError> {
        self.conn
            .lock()
            .execute("DELETE FROM outgoing_files WHERE path = ?1", params![path])?;
        Ok(())
    }

    /// Remember an identity seen in a conversation, with the root key its
    /// route carries. A root that contradicts a verified contact is refused.
    pub fn contact_seen(&self, identity: &[u8], root_public: &[u8]) -> Result<(), ClientError> {
        let conn = self.conn.lock();
        let known: Option<(Vec<u8>, i64)> = conn
            .query_row(
                "SELECT root_public, verified FROM contacts WHERE identity_id = ?1",
                params![identity],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        match known {
            Some((root, verified)) if root != root_public => {
                if verified != 0 {
                    return Err(ClientError::ContactRootMismatch {
                        identity: hex_of(identity),
                    });
                }
                conn.execute(
                    "UPDATE contacts SET root_public = ?2 WHERE identity_id = ?1",
                    params![identity, root_public],
                )?;
            }
            Some(_) => {}
            None => {
                conn.execute(
                    "INSERT INTO contacts (identity_id, root_public) VALUES (?1, ?2)",
                    params![identity, root_public],
                )?;
            }
        }
        Ok(())
    }

    pub fn contacts(&self) -> Result<Vec<Contact>, ClientError> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT identity_id, root_public, verified, name FROM contacts ORDER BY first_seen, identity_id",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok(Contact {
                identity_id: r.get(0)?,
                root_public: r.get(1)?,
                verified: r.get::<_, i64>(2)? != 0,
                name: r.get(3)?,
            })
        })?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    pub fn contact(&self, identity: &[u8]) -> Result<Option<Contact>, ClientError> {
        Ok(self
            .contacts()?
            .into_iter()
            .find(|c| c.identity_id == identity))
    }

    /// The number both sides read to each other. Depends on the two root
    /// keys only, so it survives device changes and changes if either
    /// identity is substituted.
    pub fn safety_number_with(&self, identity: &[u8]) -> Result<String, ClientError> {
        let own = self.root_public()?.ok_or(ClientError::NoIdentity)?;
        let c = self
            .contact(identity)?
            .ok_or_else(|| ClientError::NoSuchContact(hex_of(identity)))?;
        Ok(safety_number(own.as_bytes(), &c.root_public))
    }

    /// Give a contact a local name, or remove it with an empty string.
    pub fn contact_rename(&self, identity: &[u8], name: &str) -> Result<(), ClientError> {
        if self.contact(identity)?.is_none() {
            return Err(ClientError::NoSuchContact(hex_of(identity)));
        }
        let value = if name.trim().is_empty() {
            None
        } else {
            Some(name.trim().to_string())
        };
        self.conn.lock().execute(
            "UPDATE contacts SET name = ?2 WHERE identity_id = ?1",
            params![identity, value],
        )?;
        Ok(())
    }

    /// Pin a contact after the two of you read the same number aloud.
    pub fn contact_verify(
        &self,
        identity: &[u8],
        number: &str,
        now: i64,
    ) -> Result<bool, ClientError> {
        let expected = self.safety_number_with(identity)?;
        if normalize_number(number) != normalize_number(&expected) {
            return Ok(false);
        }
        self.conn.lock().execute(
            "UPDATE contacts SET verified = 1, verified_at = ?2 WHERE identity_id = ?1",
            params![identity, now],
        )?;
        Ok(true)
    }

    /// Store a grant received over a pairing channel, together with the
    /// number the user has to compare. Nothing is applied until they do.
    pub fn pairing_pending_save(
        &self,
        sas: &str,
        credential: &[u8],
        manifest: &[u8],
        root_public: &[u8],
    ) -> Result<(), ClientError> {
        self.conn.lock().execute(
            "INSERT OR REPLACE INTO pairing_pending (id, sas, credential, manifest, root_public)
             VALUES (1, ?1, ?2, ?3, ?4)",
            params![sas, credential, manifest, root_public],
        )?;
        Ok(())
    }

    /// The pending grant: (sas, credential, manifest, root public key).
    pub fn pairing_pending(&self) -> Result<Option<PendingPairing>, ClientError> {
        Ok(self
            .conn
            .lock()
            .query_row(
                "SELECT sas, credential, manifest, root_public FROM pairing_pending WHERE id = 1",
                [],
                |r| {
                    Ok(PendingPairing {
                        sas: r.get(0)?,
                        credential: r.get(1)?,
                        manifest: r.get(2)?,
                        root_public: r.get(3)?,
                    })
                },
            )
            .optional()?)
    }

    pub fn pairing_pending_clear(&self) -> Result<(), ClientError> {
        self.conn
            .lock()
            .execute("DELETE FROM pairing_pending WHERE id = 1", [])?;
        Ok(())
    }

    /// Persist the rendezvous returned by the realm before waiting for its
    /// peer. Keeping the id separately makes later confirmation and
    /// cancellation unambiguous.
    pub fn pairing_session_start(
        &self,
        session_id: &[u8],
        code: &str,
        expires_at: u64,
    ) -> Result<(), ClientError> {
        self.conn.lock().execute(
            "INSERT OR REPLACE INTO pairing_sessions
             (session_id, code, expires_at, sas, credential, manifest, root_public)
             VALUES (?1, ?2, ?3, NULL, NULL, NULL, NULL)",
            params![session_id, code, expires_at as i64],
        )?;
        Ok(())
    }

    /// Attach the authenticated grant to the exact rendezvous that produced
    /// it. Returns false if that session was cancelled or never existed.
    pub fn pairing_session_ready(
        &self,
        session_id: &[u8],
        sas: &str,
        credential: &[u8],
        manifest: &[u8],
        root_public: &[u8],
    ) -> Result<bool, ClientError> {
        Ok(self.conn.lock().execute(
            "UPDATE pairing_sessions
             SET sas = ?2, credential = ?3, manifest = ?4, root_public = ?5
             WHERE session_id = ?1",
            params![session_id, sas, credential, manifest, root_public],
        )? == 1)
    }

    pub fn pairing_session(
        &self,
        session_id: &[u8],
    ) -> Result<Option<PairingSessionState>, ClientError> {
        Ok(self
            .conn
            .lock()
            .query_row(
                "SELECT session_id, code, expires_at, sas, credential, manifest, root_public
                 FROM pairing_sessions WHERE session_id = ?1",
                params![session_id],
                |row| {
                    Ok(PairingSessionState {
                        session_id: row.get(0)?,
                        code: row.get(1)?,
                        expires_at: row.get::<_, i64>(2)? as u64,
                        sas: row.get(3)?,
                        credential: row.get(4)?,
                        manifest: row.get(5)?,
                        root_public: row.get(6)?,
                    })
                },
            )
            .optional()?)
    }

    /// The CLI compatibility adapter uses this only to resolve its legacy
    /// confirmation syntax. Reusable callers should retain the session id
    /// returned by `begin_pairing` instead.
    pub fn latest_pairing_session(&self) -> Result<Option<PairingSessionState>, ClientError> {
        Ok(self
            .conn
            .lock()
            .query_row(
                "SELECT session_id, code, expires_at, sas, credential, manifest, root_public
                 FROM pairing_sessions ORDER BY rowid DESC LIMIT 1",
                [],
                |row| {
                    Ok(PairingSessionState {
                        session_id: row.get(0)?,
                        code: row.get(1)?,
                        expires_at: row.get::<_, i64>(2)? as u64,
                        sas: row.get(3)?,
                        credential: row.get(4)?,
                        manifest: row.get(5)?,
                        root_public: row.get(6)?,
                    })
                },
            )
            .optional()?)
    }

    pub fn pairing_session_clear(&self, session_id: &[u8]) -> Result<bool, ClientError> {
        self.conn.unit_of_work(|shared| {
            let conn = shared.lock();
            conn.execute(
                "DELETE FROM pairing_completion WHERE session_id = ?1",
                params![session_id],
            )?;
            Ok(conn.execute(
                "DELETE FROM pairing_sessions WHERE session_id = ?1",
                params![session_id],
            )? == 1)
        })
    }

    /// Atomically cross the point after which cancellation cannot promise
    /// that no credentials were applied. Repeated calls return the durable
    /// phase so finalization can resume.
    pub fn pairing_completion_begin(
        &self,
        session_id: &[u8],
    ) -> Result<Option<PairingCompletionPhase>, ClientError> {
        self.conn.unit_of_work(|shared| {
            let conn = shared.lock();
            let ready: i64 = conn.query_row(
                "SELECT COUNT(*) FROM pairing_sessions
                 WHERE session_id = ?1 AND sas IS NOT NULL
                   AND credential IS NOT NULL AND manifest IS NOT NULL AND root_public IS NOT NULL",
                params![session_id],
                |row| row.get(0),
            )?;
            if ready != 1 {
                return Ok(None);
            }
            conn.execute(
                "INSERT OR IGNORE INTO pairing_completion (session_id, phase) VALUES (?1, ?2)",
                params![session_id, PairingCompletionPhase::Committing as i64],
            )?;
            let phase = conn.query_row(
                "SELECT phase FROM pairing_completion WHERE session_id = ?1",
                params![session_id],
                |row| row.get::<_, i64>(0),
            )?;
            Ok(PairingCompletionPhase::from_db(phase))
        })
    }

    pub fn pairing_completion_phase(
        &self,
        session_id: &[u8],
    ) -> Result<Option<PairingCompletionPhase>, ClientError> {
        let phase = self
            .conn
            .lock()
            .query_row(
                "SELECT phase FROM pairing_completion WHERE session_id = ?1",
                params![session_id],
                |row| row.get::<_, i64>(0),
            )
            .optional()?;
        Ok(phase.and_then(PairingCompletionPhase::from_db))
    }

    /// Advance only forwards; stale retries cannot regress a completed step.
    pub fn pairing_completion_advance(
        &self,
        session_id: &[u8],
        phase: PairingCompletionPhase,
    ) -> Result<bool, ClientError> {
        Ok(self.conn.lock().execute(
            "UPDATE pairing_completion SET phase = MAX(phase, ?2) WHERE session_id = ?1",
            params![session_id, phase as i64],
        )? == 1)
    }

    /// Start or resume completion of a link grant received outside the
    /// interactive pairing flow. Only the byte-for-byte same grant may
    /// resume a row that already crossed the local commit boundary.
    pub fn link_completion_begin(
        &self,
        credential: &[u8],
        manifest: &[u8],
        root_public: &[u8],
    ) -> Result<PairingCompletionPhase, ClientError> {
        self.conn.unit_of_work(|shared| {
            let conn = shared.lock();
            let stored = conn
                .query_row(
                    "SELECT credential, manifest, root_public, phase
                     FROM link_completion WHERE id = 1",
                    [],
                    |row| {
                        Ok((
                            row.get::<_, Vec<u8>>(0)?,
                            row.get::<_, Vec<u8>>(1)?,
                            row.get::<_, Vec<u8>>(2)?,
                            row.get::<_, i64>(3)?,
                        ))
                    },
                )
                .optional()?;
            if let Some((saved_credential, saved_manifest, saved_root, phase)) = stored {
                if saved_credential != credential
                    || saved_manifest != manifest
                    || saved_root != root_public
                {
                    return Err(ClientError::GrantMismatch);
                }
                return PairingCompletionPhase::from_db(phase)
                    .ok_or(ClientError::InvalidCompletionPhase(phase));
            }
            conn.execute(
                "INSERT INTO link_completion
                 (id, credential, manifest, root_public, phase)
                 VALUES (1, ?1, ?2, ?3, ?4)",
                params![
                    credential,
                    manifest,
                    root_public,
                    PairingCompletionPhase::Committing as i64
                ],
            )?;
            Ok(PairingCompletionPhase::Committing)
        })
    }

    pub fn link_completion_phase(&self) -> Result<Option<PairingCompletionPhase>, ClientError> {
        let phase = self
            .conn
            .lock()
            .query_row(
                "SELECT phase FROM link_completion WHERE id = 1",
                [],
                |row| row.get::<_, i64>(0),
            )
            .optional()?;
        phase
            .map(|value| {
                PairingCompletionPhase::from_db(value)
                    .ok_or(ClientError::InvalidCompletionPhase(value))
            })
            .transpose()
    }

    pub fn link_completion_advance(
        &self,
        phase: PairingCompletionPhase,
    ) -> Result<bool, ClientError> {
        Ok(self.conn.lock().execute(
            "UPDATE link_completion SET phase = MAX(phase, ?1) WHERE id = 1",
            params![phase as i64],
        )? == 1)
    }

    /// Forget a direct grant that failed before it changed local identity
    /// state. Once any durable step advanced, this deliberately does nothing.
    pub fn link_completion_abort_if_unapplied(&self) -> Result<bool, ClientError> {
        Ok(self.conn.lock().execute(
            "DELETE FROM link_completion WHERE id = 1 AND phase = ?1",
            params![PairingCompletionPhase::Committing as i64],
        )? == 1)
    }

    /// Cancellation and the Ready -> Committing transition use the same
    /// connection lock, so exactly one outcome wins within the supported
    /// single-process profile model.
    pub fn pairing_session_cancel(
        &self,
        session_id: &[u8],
    ) -> Result<PairingCancellationStatus, ClientError> {
        self.conn.unit_of_work(|shared| {
            let conn = shared.lock();
            let committed: i64 = conn.query_row(
                "SELECT COUNT(*) FROM pairing_completion WHERE session_id = ?1",
                params![session_id],
                |row| row.get(0),
            )?;
            if committed != 0 {
                return Ok(PairingCancellationStatus::AlreadyCommitted);
            }
            let deleted = conn.execute(
                "DELETE FROM pairing_sessions WHERE session_id = ?1",
                params![session_id],
            )?;
            Ok(if deleted == 1 {
                PairingCancellationStatus::Cancelled
            } else {
                PairingCancellationStatus::Missing
            })
        })
    }

    /// Is this device id known to be revoked, as a peer or as one of our
    /// own devices? The same question the group policy asks.
    pub fn device_revoked(&self, device_id: &[u8]) -> Result<bool, ClientError> {
        let conn = self.conn.lock();
        let peer: i64 = conn.query_row(
            "SELECT COUNT(*) FROM peers WHERE device_id = ?1 AND revoked = 1",
            params![device_id],
            |r| r.get(0),
        )?;
        let own: i64 = conn.query_row(
            "SELECT COUNT(*) FROM identity_devices WHERE device_id = ?1 AND revoked = 1",
            params![device_id],
            |r| r.get(0),
        )?;
        Ok(peer + own > 0)
    }

    /// Mark every peer row carrying one of these credential hashes as
    /// revoked, in every conversation. Returns the rows changed.
    pub fn peers_mark_revoked(&self, hashes: &[Vec<u8>]) -> Result<usize, ClientError> {
        let conn = self.conn.lock();
        let mut n = 0;
        for h in hashes {
            n += conn.execute(
                "UPDATE peers SET revoked = 1 WHERE credential_hash = ?1 AND revoked = 0",
                params![h],
            )?;
            conn.execute(
                "UPDATE identity_devices SET revoked = 1 WHERE credential_hash = ?1",
                params![h],
            )?;
        }
        Ok(n)
    }

    /// Administration device (M2.3): sign manifest N+1 that revokes one of
    /// this identity's devices. Returns the signed manifest and the revoked
    /// credential hash. Refuses to revoke the device in use.
    pub fn device_revoke(&self, device_id: &[u8]) -> Result<(Vec<u8>, Vec<u8>), ClientError> {
        let root = self.root()?.ok_or(ClientError::NoRoot)?;
        let me = self.device()?.ok_or(ClientError::NoDevice)?;
        if me.keys.device_id.as_slice() == device_id {
            return Err(ClientError::RevokeSelf);
        }
        let hash = self
            .own_devices()?
            .into_iter()
            .find(|d| d.device_id == device_id)
            .map(|d| d.credential_hash)
            .ok_or_else(|| ClientError::UnknownDevice(hex_of(device_id)))?;
        let previous = self.manifest_state()?;
        let body = self
            .latest_manifest_body()?
            .ok_or(ClientError::NoIdentity)?;
        let active: Vec<Vec<u8>> = body
            .active_credential_hashes
            .iter()
            .map(|h| h.to_vec())
            .filter(|h| h != &hash)
            .collect();
        let mut revoked: Vec<Vec<u8>> = body
            .revoked_credential_hashes
            .iter()
            .map(|h| h.to_vec())
            .collect();
        if !revoked.contains(&hash) {
            revoked.push(hash.clone());
        }
        let manifest = identity::issue_manifest(&root, previous.as_ref(), &active, &revoked)?;
        let (mbody, state) =
            identity::accept_manifest(&manifest, &root.public(), previous.as_ref())?;
        self.conn.unit_of_work(|c| {
            c.lock().execute(
                "INSERT INTO manifest (identity_id, sequence, signed, hash) VALUES (?1, ?2, ?3, ?4)",
                params![
                    mbody.identity_id,
                    state.sequence as i64,
                    manifest,
                    state.hash
                ],
            )?;
            Ok::<_, rusqlite::Error>(())
        })?;
        self.peers_mark_revoked(std::slice::from_ref(&hash))?;
        Ok((manifest, hash))
    }

    /// A manifest of this device's own identity, from another own device or
    /// from the realm. Accepted under the stored root key and the newest
    /// known sequence; a fork or rollback is an error. Returns the body and
    /// whether it was new.
    pub fn manifest_accept_own(
        &self,
        signed: &[u8],
    ) -> Result<(identity::DeviceManifest, bool), ClientError> {
        let root = self.root_public()?.ok_or(ClientError::NoIdentity)?;
        let known = self.manifest_state()?;
        let (body, state) = identity::accept_manifest(signed, &root, known.as_ref())?;
        let new = known.as_ref().map(|k| k.sequence) != Some(state.sequence);
        if new {
            self.conn.lock().execute(
                "INSERT INTO manifest (identity_id, sequence, signed, hash) VALUES (?1, ?2, ?3, ?4)",
                params![body.identity_id, state.sequence as i64, signed, state.hash],
            )?;
        }
        let revoked: Vec<Vec<u8>> = body
            .revoked_credential_hashes
            .iter()
            .map(|h| h.to_vec())
            .collect();
        self.peers_mark_revoked(&revoked)?;
        Ok((body, new))
    }

    pub fn peer_manifest_state(
        &self,
        identity: &[u8],
    ) -> Result<Option<ManifestState>, ClientError> {
        let row: Option<(i64, Vec<u8>)> = self
            .conn
            .lock()
            .query_row(
                "SELECT sequence, hash FROM peer_manifests WHERE identity_id = ?1",
                params![identity],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        Ok(row.map(|(sequence, hash)| ManifestState {
            sequence: sequence as u64,
            hash,
        }))
    }

    /// A manifest of a peer identity. Verified under the root key learned
    /// from that peer's routes; the sequence must not go backwards; revoked
    /// hashes mark the matching peers in every conversation. Returns the
    /// body and whether it was new.
    pub fn peer_manifest_accept(
        &self,
        identity: &[u8],
        signed: &[u8],
    ) -> Result<(identity::DeviceManifest, bool), ClientError> {
        let root_bytes: Option<Vec<u8>> = self
            .conn
            .lock()
            .query_row(
                "SELECT root_public FROM peers WHERE peer_identity = ?1 LIMIT 1",
                params![identity],
                |r| r.get(0),
            )
            .optional()?;
        let root_bytes = root_bytes.ok_or(ClientError::UnknownIdentity)?;
        let pk: [u8; 32] = root_bytes
            .as_slice()
            .try_into()
            .map_err(|_| ClientError::UnknownIdentity)?;
        let root = VerifyingKey::from_bytes(&pk).map_err(|_| ClientError::UnknownIdentity)?;
        let known = self.peer_manifest_state(identity)?;
        let (body, state) = identity::accept_manifest(signed, &root, known.as_ref())?;
        let new = known.as_ref().map(|k| k.sequence) != Some(state.sequence);
        if new {
            self.conn.lock().execute(
                "INSERT INTO peer_manifests (identity_id, sequence, hash) VALUES (?1, ?2, ?3)
                 ON CONFLICT(identity_id) DO UPDATE SET sequence = excluded.sequence, hash = excluded.hash",
                params![identity, state.sequence as i64, state.hash],
            )?;
        }
        let revoked: Vec<Vec<u8>> = body
            .revoked_credential_hashes
            .iter()
            .map(|h| h.to_vec())
            .collect();
        self.peers_mark_revoked(&revoked)?;
        Ok((body, new))
    }

    /// New device: accept a grant only if the credential names exactly this
    /// device's keys, verifies under `root_public`, and the manifest (under
    /// the same root) lists it active. Stores identity (without root),
    /// credential and manifest in one unit of work. Returns the identity id.
    pub fn device_link_complete(
        &self,
        credential: &[u8],
        manifest: &[u8],
        root_public: &[u8],
        now: u64,
    ) -> Result<Vec<u8>, ClientError> {
        let device = self.device()?.ok_or(ClientError::NoDevice)?;
        if !device.credential.is_empty() || self.identity_id()?.is_some() {
            return Err(ClientError::DeviceExists);
        }
        let pk: [u8; 32] = root_public
            .try_into()
            .map_err(|_| ClientError::GrantMismatch)?;
        let root = VerifyingKey::from_bytes(&pk).map_err(|_| ClientError::GrantMismatch)?;
        let v = identity::verify_credential(credential, Some(&root), now)?;
        let c = &v.credential;
        let mine = device.keys.public();
        if c.device_id != mine.device_id
            || c.mls_signature_public_key != mine.mls_signature_public_key
            || c.transport_noise_public_key != mine.transport_noise_public_key
            || c.envelope_hpke_public_key != mine.envelope_hpke_public_key
        {
            return Err(ClientError::GrantMismatch);
        }
        let (body, state) = identity::accept_manifest(manifest, &root, None)?;
        if !body
            .active_credential_hashes
            .iter()
            .any(|h| h.as_slice() == v.hash.as_slice())
        {
            return Err(ClientError::GrantManifest);
        }
        let identity_id = identity::identity_id(&root);
        self.conn.unit_of_work(|c| {
            let conn = c.lock();
            conn.execute(
                "INSERT INTO identity (id, root_seed, root_public, identity_id) VALUES (1, NULL, ?1, ?2)",
                params![root_public, identity_id],
            )?;
            conn.execute(
                "UPDATE device SET credential = ?1, credential_hash = ?2 WHERE device_id = ?3",
                params![credential, v.hash, device.keys.device_id.to_vec()],
            )?;
            conn.execute(
                "INSERT INTO manifest (identity_id, sequence, signed, hash) VALUES (?1, ?2, ?3, ?4)",
                params![body.identity_id, state.sequence as i64, manifest, state.hash],
            )?;
            conn.execute(
                "INSERT INTO identity_devices (device_id, credential_hash) VALUES (?1, ?2)",
                params![device.keys.device_id.to_vec(), v.hash],
            )?;
            Ok::<_, rusqlite::Error>(())
        })?;
        Ok(identity_id)
    }

    /// Resume-safe form of [`Client::device_link_complete`]. If an earlier
    /// attempt committed locally but failed before its caller recorded the
    /// next application phase, accept only the byte-for-byte same,
    /// cryptographically valid linkage.
    pub fn device_link_complete_idempotent(
        &self,
        credential: &[u8],
        manifest: &[u8],
        root_public: &[u8],
        now: u64,
    ) -> Result<Vec<u8>, ClientError> {
        match self.device_link_complete(credential, manifest, root_public, now) {
            Ok(identity_id) => Ok(identity_id),
            Err(ClientError::DeviceExists) => {
                let device = self.device()?.ok_or(ClientError::NoDevice)?;
                let stored_identity = self.identity_id()?.ok_or(ClientError::DeviceExists)?;
                let stored_root = self.root_public()?.ok_or(ClientError::DeviceExists)?;
                let public: [u8; 32] = root_public
                    .try_into()
                    .map_err(|_| ClientError::GrantMismatch)?;
                let root =
                    VerifyingKey::from_bytes(&public).map_err(|_| ClientError::GrantMismatch)?;
                let verified = identity::verify_credential(credential, Some(&root), now)?;
                let mine = device.keys.public();
                let same_device = verified.credential.device_id == mine.device_id
                    && verified.credential.mls_signature_public_key
                        == mine.mls_signature_public_key
                    && verified.credential.transport_noise_public_key
                        == mine.transport_noise_public_key
                    && verified.credential.envelope_hpke_public_key
                        == mine.envelope_hpke_public_key;
                let (body, _) = identity::accept_manifest(manifest, &root, None)?;
                let active = body
                    .active_credential_hashes
                    .iter()
                    .any(|hash| hash.as_slice() == verified.hash.as_slice());
                let same_link = same_device
                    && active
                    && device.credential == credential
                    && device.credential_hash == verified.hash
                    && stored_root == root
                    && stored_identity == identity::identity_id(&root);
                if same_link {
                    Ok(stored_identity)
                } else {
                    Err(ClientError::DeviceExists)
                }
            }
            Err(error) => Err(error),
        }
    }

    pub fn manifest_state(&self) -> Result<Option<ManifestState>, ClientError> {
        let row: Option<(i64, Vec<u8>)> = self
            .conn
            .lock()
            .query_row(
                "SELECT sequence, hash FROM manifest ORDER BY sequence DESC LIMIT 1",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        Ok(row.map(|(sequence, hash)| ManifestState {
            sequence: sequence as u64,
            hash,
        }))
    }

    pub fn latest_manifest(&self) -> Result<Option<Vec<u8>>, ClientError> {
        Ok(self
            .conn
            .lock()
            .query_row(
                "SELECT signed FROM manifest ORDER BY sequence DESC LIMIT 1",
                [],
                |r| r.get(0),
            )
            .optional()?)
    }

    /// Remember a realm from its bootstrap.
    pub fn realm_save(
        &self,
        realm_id: &[u8],
        signing_public: &VerifyingKey,
        noise_public: &[u8],
        bootstrap_url: &str,
    ) -> Result<(), ClientError> {
        self.conn.lock().execute(
            "INSERT INTO realm (realm_id, signing_public, noise_public, bootstrap_url)
             VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(realm_id) DO UPDATE SET signing_public = excluded.signing_public,
                 noise_public = excluded.noise_public, bootstrap_url = excluded.bootstrap_url",
            params![
                realm_id,
                signing_public.as_bytes().to_vec(),
                noise_public,
                bootstrap_url
            ],
        )?;
        Ok(())
    }

    /// Verify and store a newer endpoint list; refuses rollbacks.
    pub fn realm_accept_endpoint_list(
        &self,
        realm_id: &[u8],
        signed: &[u8],
    ) -> Result<RealmEndpointList, ClientError> {
        let realm = self.realm()?.ok_or(ClientError::NoDevice)?;
        // Re-fetching the list already stored is idempotent, not a
        // rollback: the sequence rule applies to a *different* list.
        let stored: Option<Vec<u8>> = self
            .conn
            .lock()
            .query_row(
                "SELECT endpoint_list FROM realm WHERE realm_id = ?1",
                params![realm_id],
                |r| r.get(0),
            )
            .optional()?
            .flatten();
        let known = match &stored {
            Some(bytes) if bytes.as_slice() == signed => None,
            _ => realm.endpoint_list.as_ref().map(|l| l.sequence),
        };
        let list = endpoints::verify(signed, &realm.signing_public, realm_id, known)?;
        self.conn.lock().execute(
            "UPDATE realm SET endpoint_list = ?1, endpoint_sequence = ?2, noise_public = ?3 WHERE realm_id = ?4",
            params![signed, list.sequence as i64, list.realm_noise_public_key, realm_id],
        )?;
        Ok(list)
    }

    /// Create or refresh a conversation row and upsert its peers; known
    /// route fields are never overwritten with `None`. Every peer's root is
    /// checked against what this device already knows about that identity,
    /// so a verified contact cannot be replaced by a route that names a
    /// different root.
    pub fn conversation_save(&self, c: &Conversation) -> Result<(), ClientError> {
        // Own other devices are peers but not contacts: there is nobody to
        // read a number with.
        let own = self.identity_id()?;
        for p in &c.peers {
            if !p.root_public.is_empty() && own.as_deref() != Some(p.identity.as_slice()) {
                self.contact_seen(&p.identity, &p.root_public)?;
            }
        }
        let conn = self.conn.lock();
        conn.execute(
            "INSERT INTO conversations (group_id, creator) VALUES (?1, ?2)
             ON CONFLICT(group_id) DO UPDATE SET creator = MAX(creator, excluded.creator)",
            params![c.group_id, c.creator as i64],
        )?;
        for p in &c.peers {
            conn.execute(
                "INSERT INTO peers (group_id, device_id, peer_identity, credential_hash, root_public, mailbox, write_cap, hpke, revoked)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
                 ON CONFLICT(group_id, device_id) DO UPDATE SET
                   mailbox = COALESCE(excluded.mailbox, mailbox),
                   write_cap = COALESCE(excluded.write_cap, write_cap),
                   hpke = COALESCE(excluded.hpke, hpke),
                   revoked = MAX(revoked, excluded.revoked)",
                params![
                    c.group_id,
                    p.device_id,
                    p.identity,
                    p.credential_hash,
                    p.root_public,
                    p.mailbox,
                    p.write_cap,
                    p.hpke,
                    p.revoked as i64
                ],
            )?;
        }
        Ok(())
    }

    fn peers_of(&self, group_id: &[u8]) -> Result<Vec<Peer>, ClientError> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT peer_identity, device_id, credential_hash, root_public, mailbox, write_cap, hpke, revoked
             FROM peers WHERE group_id = ?1 ORDER BY peer_identity, device_id",
        )?;
        let rows = stmt.query_map(params![group_id], |r| {
            Ok(Peer {
                identity: r.get(0)?,
                device_id: r.get(1)?,
                credential_hash: r.get(2)?,
                root_public: r.get(3)?,
                mailbox: r.get(4)?,
                write_cap: r.get(5)?,
                hpke: r.get(6)?,
                revoked: r.get::<_, i64>(7)? != 0,
            })
        })?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    pub fn conversation(&self, group_id: &[u8]) -> Result<Option<Conversation>, ClientError> {
        let creator: Option<i64> = self
            .conn
            .lock()
            .query_row(
                "SELECT creator FROM conversations WHERE group_id = ?1",
                params![group_id],
                |r| r.get(0),
            )
            .optional()?;
        let Some(creator) = creator else {
            return Ok(None);
        };
        Ok(Some(Conversation {
            group_id: group_id.to_vec(),
            creator: creator != 0,
            peers: self.peers_of(group_id)?,
        }))
    }

    pub fn conversations(&self) -> Result<Vec<Conversation>, ClientError> {
        let ids: Vec<Vec<u8>> = {
            let conn = self.conn.lock();
            let mut stmt =
                conn.prepare("SELECT group_id FROM conversations ORDER BY created_at")?;
            let rows = stmt.query_map([], |r| r.get(0))?;
            rows.collect::<Result<_, _>>()?
        };
        let mut out = Vec::new();
        for id in ids {
            if let Some(c) = self.conversation(&id)? {
                out.push(c);
            }
        }
        Ok(out)
    }

    /// How far a previous attempt to join a realm got, if there was one.
    pub fn enrollment(&self) -> Result<Option<EnrollmentProgress>, ClientError> {
        Ok(self
            .conn
            .lock()
            .query_row(
                "SELECT realm_id, invite_hash, credential_hash, phase FROM enrollment WHERE id = 1",
                [],
                |r| {
                    Ok(EnrollmentProgress {
                        realm_id: r.get(0)?,
                        invite_hash: r.get(1)?,
                        credential_hash: r.get(2)?,
                        phase: EnrollmentPhase::from_stored(&r.get::<_, String>(3)?),
                    })
                },
            )
            .optional()?)
    }

    /// Record where an enrollment has reached. Written after the step it
    /// describes is durable, so a resume never claims more than happened.
    pub fn enrollment_save(&self, progress: &EnrollmentProgress) -> Result<(), ClientError> {
        self.conn.lock().execute(
            "INSERT INTO enrollment (id, realm_id, invite_hash, credential_hash, phase, updated_at)
             VALUES (1, ?1, ?2, ?3, ?4, ?5)
             ON CONFLICT(id) DO UPDATE SET
                realm_id = ?1, invite_hash = ?2, credential_hash = ?3, phase = ?4, updated_at = ?5",
            params![
                progress.realm_id,
                progress.invite_hash,
                progress.credential_hash,
                progress.phase.stored(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_secs() as i64)
                    .unwrap_or(0)
            ],
        )?;
        Ok(())
    }

    /// The mailbox request this device will make, created once and kept, so
    /// that a retry after a lost answer asks for the same thing.
    pub fn mailbox_request(&self) -> Result<MailboxRequest, ClientError> {
        if let Some(existing) = self.conn.lock().query_row(
            "SELECT request_key, read_capability, write_capability FROM mailbox_request WHERE id = 1",
            [],
            |r| {
                Ok(MailboxRequest {
                    request_key: r.get(0)?,
                    read_capability: r.get(1)?,
                    write_capability: r.get(2)?,
                })
            },
        ).optional()? {
            return Ok(existing);
        }

        let mut request_key = vec![0u8; 16];
        let mut read_capability = vec![0u8; 32];
        let mut write_capability = vec![0u8; 32];
        for bytes in [
            &mut request_key,
            &mut read_capability,
            &mut write_capability,
        ] {
            getrandom::fill(bytes)
                .map_err(|_| ClientError::Identity(identity::IdentityError::Random))?;
        }
        let request = MailboxRequest {
            request_key,
            read_capability,
            write_capability,
        };
        // Written before anything is sent: a capability the relay accepted
        // and this device forgot would be a mailbox nobody can read.
        self.conn.lock().execute(
            "INSERT INTO mailbox_request (id, request_key, read_capability, write_capability)
             VALUES (1, ?1, ?2, ?3)",
            params![
                request.request_key,
                request.read_capability,
                request.write_capability
            ],
        )?;
        Ok(request)
    }

    /// Save this device's mailbox. Saving the same one again does nothing:
    /// the realm answers a repeated request with the mailbox it already
    /// made, and recording that twice is not a second mailbox.
    pub fn mailbox_save(&self, m: &OwnMailbox) -> Result<(), ClientError> {
        self.conn.lock().execute(
            "INSERT INTO mailbox_own (mailbox_id, read_capability, write_capability)
             VALUES (?1, ?2, ?3)
             ON CONFLICT(mailbox_id) DO NOTHING",
            params![m.mailbox_id, m.read_capability, m.write_capability],
        )?;
        Ok(())
    }

    pub fn mailbox_own(&self) -> Result<Option<OwnMailbox>, ClientError> {
        Ok(self
            .conn
            .lock()
            .query_row(
                "SELECT mailbox_id, read_capability, write_capability FROM mailbox_own ORDER BY created_at LIMIT 1",
                [],
                |r| {
                    Ok(OwnMailbox {
                        mailbox_id: r.get(0)?,
                        read_capability: r.get(1)?,
                        write_capability: r.get(2)?,
                    })
                },
            )
            .optional()?)
    }

    pub fn realm_mark_enrolled(&self, realm_id: &[u8]) -> Result<(), ClientError> {
        self.conn.lock().execute(
            "UPDATE realm SET enrolled = 1 WHERE realm_id = ?1",
            params![realm_id],
        )?;
        Ok(())
    }

    pub fn realm(&self) -> Result<Option<StoredRealm>, ClientError> {
        let row: Option<RealmRow> = self
            .conn
            .lock()
            .query_row(
                "SELECT realm_id, signing_public, noise_public, bootstrap_url, endpoint_list, enrolled FROM realm LIMIT 1",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?)),
            )
            .optional()?;
        let Some((realm_id, sp, noise_public, bootstrap_url, list, enrolled)) = row else {
            return Ok(None);
        };
        let sp: [u8; 32] = sp.as_slice().try_into().expect("32-byte key");
        let signing_public = VerifyingKey::from_bytes(&sp).expect("stored key valid");
        let endpoint_list = match list {
            Some(bytes) => Some(endpoints::verify(&bytes, &signing_public, &realm_id, None)?),
            None => None,
        };
        Ok(Some(StoredRealm {
            realm_id,
            signing_public,
            noise_public,
            bootstrap_url,
            endpoint_list,
            enrolled: enrolled != 0,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identity_device_and_manifest_persist_and_reload() {
        let conn = SharedConn::open_in_memory().unwrap();
        let c = Client::open(conn.clone()).unwrap();
        assert!(c.root().unwrap().is_none());
        let root = c.identity_new().unwrap();
        assert!(matches!(c.identity_new(), Err(ClientError::IdentityExists)));
        assert_eq!(c.root().unwrap().unwrap().identity_id(), root.identity_id());

        let (dev, manifest) = c.device_new(1_800_000_000).unwrap();
        let reloaded = c.device().unwrap().unwrap();
        assert_eq!(reloaded.keys.device_id, dev.keys.device_id);
        assert_eq!(reloaded.credential, dev.credential);
        let v =
            identity::verify_credential(&reloaded.credential, Some(&root.public()), 1_800_000_000)
                .unwrap();
        assert_eq!(
            v.credential.transport_noise_public_key,
            dev.keys.transport_noise.public
        );
        let state = c.manifest_state().unwrap().unwrap();
        assert_eq!(state.sequence, 1);
        assert_eq!(state.hash, identity::manifest_hash(&manifest));
        assert_eq!(c.latest_manifest().unwrap().unwrap(), manifest);
    }

    #[test]
    fn pairing_sessions_are_addressed_and_cleared_by_exact_id() {
        let c = Client::open(SharedConn::open_in_memory().unwrap()).unwrap();
        c.pairing_session_start(b"one", "code-one", 100).unwrap();
        c.pairing_session_start(b"two", "code-two", 200).unwrap();
        assert!(
            c.pairing_session_ready(b"one", "1111-2222", b"c", b"m", b"r")
                .unwrap()
        );
        assert!(
            !c.pairing_session_ready(b"missing", "0000-0000", b"c", b"m", b"r")
                .unwrap()
        );
        assert_eq!(
            c.pairing_session(b"one").unwrap().unwrap().sas.as_deref(),
            Some("1111-2222")
        );
        assert!(c.pairing_session_clear(b"one").unwrap());
        assert!(c.pairing_session(b"one").unwrap().is_none());
        assert_eq!(
            c.latest_pairing_session().unwrap().unwrap().session_id,
            b"two"
        );
        assert_eq!(
            c.pairing_session_cancel(b"missing").unwrap(),
            PairingCancellationStatus::Missing
        );
        c.pairing_session_ready(b"two", "3333-4444", b"c", b"m", b"r")
            .unwrap();
        assert_eq!(
            c.pairing_completion_begin(b"two").unwrap(),
            Some(PairingCompletionPhase::Committing)
        );
        assert_eq!(
            c.pairing_session_cancel(b"two").unwrap(),
            PairingCancellationStatus::AlreadyCommitted
        );
        assert!(c.pairing_session(b"two").unwrap().is_some());
        c.pairing_completion_advance(b"two", PairingCompletionPhase::LocalApplied)
            .unwrap();
        assert_eq!(
            c.pairing_completion_phase(b"two").unwrap(),
            Some(PairingCompletionPhase::LocalApplied)
        );
    }

    #[test]
    fn direct_link_completion_resumes_only_the_same_grant() {
        let c = Client::open(SharedConn::open_in_memory().unwrap()).unwrap();
        assert_eq!(
            c.link_completion_begin(b"credential", b"manifest", b"root")
                .unwrap(),
            PairingCompletionPhase::Committing
        );
        assert!(
            c.link_completion_advance(PairingCompletionPhase::RealmSaved)
                .unwrap()
        );
        assert_eq!(
            c.link_completion_begin(b"credential", b"manifest", b"root")
                .unwrap(),
            PairingCompletionPhase::RealmSaved
        );
        assert!(matches!(
            c.link_completion_begin(b"credential", b"another-manifest", b"root"),
            Err(ClientError::GrantMismatch)
        ));
    }
}
