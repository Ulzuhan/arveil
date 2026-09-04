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
use crate::storage::SharedConn;

pub const CLIENT_SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS identity (
    id          INTEGER PRIMARY KEY CHECK (id = 1),
    root_seed   BLOB NOT NULL,
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

/// A mailbox this device owns on the realm.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OwnMailbox {
    pub mailbox_id: Vec<u8>,
    pub read_capability: Vec<u8>,
    pub write_capability: Vec<u8>,
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
            "INSERT INTO identity (id, root_seed, identity_id) VALUES (1, ?1, ?2)",
            params![root.signing.to_bytes().to_vec(), root.identity_id()],
        )?;
        Ok(root)
    }

    pub fn root(&self) -> Result<Option<RootKey>, ClientError> {
        let seed: Option<Vec<u8>> = self
            .conn
            .lock()
            .query_row("SELECT root_seed FROM identity WHERE id = 1", [], |r| {
                r.get(0)
            })
            .optional()?;
        Ok(seed.map(|s| {
            let seed: [u8; 32] = s.as_slice().try_into().expect("32-byte seed");
            RootKey::from_seed(&seed)
        }))
    }

    /// Generate this device's keys, issue its credential and the first
    /// manifest under the local root, and persist everything in one unit of
    /// work. Returns the device and the signed manifest bytes.
    pub fn device_new(
        &self,
        mls_signing_secret: Vec<u8>,
        mls_signing_public: Vec<u8>,
        now: u64,
    ) -> Result<(StoredDevice, Vec<u8>), ClientError> {
        let root = self.root()?.ok_or(ClientError::NoIdentity)?;
        let keys = DeviceKeys::generate(mls_signing_public.clone())?;
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
        let manifest = identity::issue_manifest(
            &root,
            previous.as_ref(),
            std::slice::from_ref(&credential_hash),
            &[],
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
        let known = realm.endpoint_list.as_ref().map(|l| l.sequence);
        let list = endpoints::verify(signed, &realm.signing_public, realm_id, known)?;
        self.conn.lock().execute(
            "UPDATE realm SET endpoint_list = ?1, endpoint_sequence = ?2, noise_public = ?3 WHERE realm_id = ?4",
            params![signed, list.sequence as i64, list.realm_noise_public_key, realm_id],
        )?;
        Ok(list)
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

        let (dev, manifest) = c
            .device_new(vec![1; 32], vec![2; 32], 1_800_000_000)
            .unwrap();
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
