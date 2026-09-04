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
    #[error("client: device already linked or enrolled")]
    DeviceExists,
    #[error("client: unknown device {0} for this identity")]
    UnknownDevice(String),
    #[error("client: refusing to revoke the device in use; do it from another device")]
    RevokeSelf,
    #[error("client: manifest for an identity with no known root key")]
    UnknownIdentity,
}

fn hex_of(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// Default credential validity for Phase 0: one year.
pub const DEFAULT_VALIDITY_SECS: u64 = 365 * 24 * 3600;

pub struct Client {
    pub conn: SharedConn,
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
    /// route fields are never overwritten with `None`.
    pub fn conversation_save(&self, c: &Conversation) -> Result<(), ClientError> {
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

    pub fn mailbox_save(&self, m: &OwnMailbox) -> Result<(), ClientError> {
        self.conn.lock().execute(
            "INSERT INTO mailbox_own (mailbox_id, read_capability, write_capability) VALUES (?1, ?2, ?3)",
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
}
