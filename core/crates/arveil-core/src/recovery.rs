//! Identity kit and history archive (PROTOCOL §9, ADR-006).
//!
//! Three mechanisms are kept apart on purpose: recovering the **identity**
//! (this module's kit), enrolling a **device** (`client::device_link_*`) and
//! recovering **history** (this module's archive). Each has its own secret,
//! and neither file carries active MLS material or device private keys.
//!
//! Both files are `age` (X25519 recipient) so the format and its review come
//! from outside this project. The secret handed to the user is the age
//! identity itself, high entropy by construction: no password KDF, no ad hoc
//! construction.

use serde::{Deserialize, Serialize};

pub const KIT_VERSION: u8 = 1;
pub const ARCHIVE_VERSION: u8 = 1;

#[derive(Debug, thiserror::Error)]
pub enum RecoveryError {
    #[error("recovery: {0}")]
    Encode(String),
    #[error("recovery: encryption failed: {0}")]
    Encrypt(String),
    #[error("recovery: wrong secret, or the file is not an Arveil {0}")]
    Decrypt(&'static str),
    #[error("recovery: bad secret: {0}")]
    Secret(String),
    #[error("recovery: unsupported {0} version {1}")]
    Version(&'static str, u8),
}

/// The identity kit: enough to prove the identity again on a clean client,
/// and to know which manifest it had last seen. No device keys, no MLS.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct IdentityKit {
    pub version: u8,
    #[serde(with = "serde_bytes")]
    pub root_seed: Vec<u8>,
    #[serde(with = "serde_bytes")]
    pub identity_id: Vec<u8>,
    pub manifest_sequence: u64,
    /// The newest manifest this identity signed, so recovery can chain from
    /// it even if the realm serves an older one.
    #[serde(with = "serde_bytes")]
    pub latest_manifest: Vec<u8>,
    pub exported_at: u64,
}

/// One archived record. It is history: importing it never produces a new
/// event, never re-sends anything and never restores MLS state (I-07).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ArchiveRecord {
    #[serde(with = "serde_bytes")]
    pub group_id: Vec<u8>,
    #[serde(with = "serde_bytes")]
    pub event_id: Vec<u8>,
    pub kind: String,
    #[serde(with = "serde_bytes")]
    pub body: Vec<u8>,
    pub created_at: i64,
    /// Attachment bytes, when the exporting device still had the file.
    pub file_name: Option<String>,
    #[serde(with = "serde_bytes")]
    pub file: Vec<u8>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct HistoryArchive {
    pub version: u8,
    #[serde(with = "serde_bytes")]
    pub identity_id: Vec<u8>,
    pub exported_at: u64,
    pub records: Vec<ArchiveRecord>,
}

/// A fresh age secret and the recipient it encrypts to. The secret is shown
/// to the user once and never stored by Arveil.
pub struct Secret {
    pub identity: age::x25519::Identity,
}

impl Secret {
    pub fn generate() -> Self {
        Self {
            identity: age::x25519::Identity::generate(),
        }
    }

    pub fn parse(s: &str) -> Result<Self, RecoveryError> {
        let identity: age::x25519::Identity = s
            .trim()
            .parse()
            .map_err(|e: &str| RecoveryError::Secret(e.to_string()))?;
        Ok(Self { identity })
    }

    /// The `AGE-SECRET-KEY-1…` string. Losing it loses the file.
    pub fn to_string_once(&self) -> String {
        use age::secrecy::ExposeSecret;
        self.identity.to_string().expose_secret().to_string()
    }
}

fn seal<T: Serialize>(value: &T, secret: &Secret) -> Result<Vec<u8>, RecoveryError> {
    let plaintext =
        crate::signed::canonical(value).map_err(|e| RecoveryError::Encode(e.to_string()))?;
    age::encrypt(&secret.identity.to_public(), &plaintext)
        .map_err(|e| RecoveryError::Encrypt(e.to_string()))
}

fn open<T: serde::de::DeserializeOwned>(
    bytes: &[u8],
    secret: &Secret,
    what: &'static str,
) -> Result<T, RecoveryError> {
    let plaintext =
        age::decrypt(&secret.identity, bytes).map_err(|_| RecoveryError::Decrypt(what))?;
    ciborium::from_reader(plaintext.as_slice()).map_err(|_| RecoveryError::Decrypt(what))
}

pub fn kit_seal(kit: &IdentityKit, secret: &Secret) -> Result<Vec<u8>, RecoveryError> {
    seal(kit, secret)
}

pub fn kit_open(bytes: &[u8], secret: &Secret) -> Result<IdentityKit, RecoveryError> {
    let kit: IdentityKit = open(bytes, secret, "identity kit")?;
    if kit.version != KIT_VERSION {
        return Err(RecoveryError::Version("identity kit", kit.version));
    }
    Ok(kit)
}

pub fn archive_seal(a: &HistoryArchive, secret: &Secret) -> Result<Vec<u8>, RecoveryError> {
    seal(a, secret)
}

pub fn archive_open(bytes: &[u8], secret: &Secret) -> Result<HistoryArchive, RecoveryError> {
    let a: HistoryArchive = open(bytes, secret, "history archive")?;
    if a.version != ARCHIVE_VERSION {
        return Err(RecoveryError::Version("history archive", a.version));
    }
    Ok(a)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kit() -> IdentityKit {
        IdentityKit {
            version: KIT_VERSION,
            root_seed: vec![7; 32],
            identity_id: vec![1; 32],
            manifest_sequence: 3,
            latest_manifest: vec![9; 64],
            exported_at: 1_756_000_000,
        }
    }

    #[test]
    fn kit_round_trips_and_hides_the_root() {
        let secret = Secret::generate();
        let sealed = kit_seal(&kit(), &secret).unwrap();
        // The root seed is not in the file, and the file says it is age.
        assert!(sealed.starts_with(b"age-encryption.org/v1"));
        assert!(
            !sealed.windows(32).any(|w| w == [7u8; 32]),
            "root seed found in the kit file"
        );
        assert_eq!(kit_open(&sealed, &secret).unwrap(), kit());

        let other = Secret::generate();
        assert!(matches!(
            kit_open(&sealed, &other),
            Err(RecoveryError::Decrypt(_))
        ));
        // The printed secret opens it again.
        let same = Secret::parse(&secret.to_string_once()).unwrap();
        assert_eq!(kit_open(&sealed, &same).unwrap(), kit());
    }

    #[test]
    fn archive_round_trips_and_hides_message_text() {
        let secret = Secret::generate();
        let a = HistoryArchive {
            version: ARCHIVE_VERSION,
            identity_id: vec![1; 32],
            exported_at: 1_756_000_000,
            records: vec![ArchiveRecord {
                group_id: vec![2; 32],
                event_id: vec![3; 16],
                kind: "received".into(),
                body: b"hola familia".to_vec(),
                created_at: 1_756_000_000,
                file_name: None,
                file: Vec::new(),
            }],
        };
        let sealed = archive_seal(&a, &secret).unwrap();
        assert!(
            !sealed
                .windows(b"hola familia".len())
                .any(|w| w == b"hola familia"),
            "message text found in the archive file"
        );
        assert_eq!(archive_open(&sealed, &secret).unwrap(), a);
    }

    #[test]
    fn a_kit_of_another_version_is_refused() {
        let secret = Secret::generate();
        let mut k = kit();
        k.version = 9;
        let sealed = kit_seal(&k, &secret).unwrap();
        assert!(matches!(
            kit_open(&sealed, &secret),
            Err(RecoveryError::Version("identity kit", 9))
        ));
    }
}
