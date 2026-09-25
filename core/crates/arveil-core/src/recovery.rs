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
pub const MAX_ARCHIVE_BYTES: usize = 64 * 1024 * 1024;
pub const MAX_ARCHIVE_RECORDS: usize = 10_000;
pub const MAX_ARCHIVE_PAYLOAD_BYTES: usize = 48 * 1024 * 1024;

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
    /// Distinguishes an available empty file from a missing copy. Older v1 files omit it.
    #[serde(default)]
    pub file_present: bool,
    /// The identity that wrote the record, as the exporting device knew it.
    /// An archive is user-supplied history: this names an author, it does
    /// not prove one. Older v1 files omit it, and builds that predate it
    /// ignore it; a record without an author does not write the field.
    #[serde(default, with = "serde_bytes", skip_serializing_if = "Option::is_none")]
    pub sender_identity: Option<Vec<u8>>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct HistoryArchive {
    pub version: u8,
    #[serde(with = "serde_bytes")]
    pub identity_id: Vec<u8>,
    pub exported_at: u64,
    #[serde(deserialize_with = "bounded_records")]
    pub records: Vec<ArchiveRecord>,
}

// Enforce the record ceiling during decoding, before allocating a collection
// based on an untrusted CBOR array length. Ciphertext size is bounded separately.
fn bounded_records<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<Vec<ArchiveRecord>, D::Error> {
    struct Records;
    impl<'de> serde::de::Visitor<'de> for Records {
        type Value = Vec<ArchiveRecord>;
        fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.write_str("a bounded history archive")
        }
        fn visit_seq<A: serde::de::SeqAccess<'de>>(
            self,
            mut seq: A,
        ) -> Result<Self::Value, A::Error> {
            let mut records = Vec::new();
            while let Some(record) = seq.next_element()? {
                if records.len() == MAX_ARCHIVE_RECORDS {
                    return Err(serde::de::Error::custom("too many archived records"));
                }
                records.push(record);
            }
            Ok(records)
        }
    }
    deserializer.deserialize_seq(Records)
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
    if bytes.len() > MAX_ARCHIVE_BYTES {
        return Err(RecoveryError::Decrypt("history archive"));
    }
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

    /// Archives stay version 1 in both directions: a record without an
    /// author writes exactly what builds before authors wrote, a record from
    /// before reads without one, and a build from before reads a record
    /// that names one.
    #[test]
    fn the_author_is_optional_in_both_directions() {
        #[derive(Serialize, Deserialize, Debug, PartialEq)]
        struct Before {
            #[serde(with = "serde_bytes")]
            group_id: Vec<u8>,
            #[serde(with = "serde_bytes")]
            event_id: Vec<u8>,
            kind: String,
            #[serde(with = "serde_bytes")]
            body: Vec<u8>,
            created_at: i64,
            file_name: Option<String>,
            #[serde(with = "serde_bytes")]
            file: Vec<u8>,
            #[serde(default)]
            file_present: bool,
        }
        let before = Before {
            group_id: vec![2; 32],
            event_id: vec![3; 16],
            kind: "received".into(),
            body: b"hola".to_vec(),
            created_at: 1_756_000_000,
            file_name: None,
            file: Vec::new(),
            file_present: false,
        };
        let mut old_bytes = Vec::new();
        ciborium::into_writer(&before, &mut old_bytes).unwrap();
        let read: ArchiveRecord = ciborium::from_reader(old_bytes.as_slice()).unwrap();
        assert_eq!(read.sender_identity, None);
        let mut rewritten = Vec::new();
        ciborium::into_writer(&read, &mut rewritten).unwrap();
        assert_eq!(rewritten, old_bytes, "no author, no new field");

        let named = ArchiveRecord {
            sender_identity: Some(vec![5; 32]),
            ..read
        };
        let mut new_bytes = Vec::new();
        ciborium::into_writer(&named, &mut new_bytes).unwrap();
        let old_reader: Before = ciborium::from_reader(new_bytes.as_slice()).unwrap();
        assert_eq!(old_reader, before, "an older build ignores the author");
        let again: ArchiveRecord = ciborium::from_reader(new_bytes.as_slice()).unwrap();
        assert_eq!(again.sender_identity, Some(vec![5; 32]));
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
                file_present: false,
                sender_identity: None,
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
