//! Attachments (PROTOCOL §7, Phase 1 profile): whole-file AEAD with a random
//! FileKey, an E2EE descriptor that travels inside MLS, and the relay only
//! ever holding ciphertext under an opaque blob id.
//!
//! ```text
//! FileKey   32 random bytes           Nonce  12 random bytes
//! ciphertext = AES-256-GCM(FileKey, Nonce, aad = "arveil/file/v1", plaintext)
//! ciphertext_hash = SHA-256(ciphertext)
//! FileDescriptor { version, blob_id, read_capability, file_key, nonce,
//!                  ciphertext_hash, size, name, mime }   (inside an MLS event)
//! ```
//!
//! The receiver checks the hash and the AEAD tag before writing anything;
//! a hash without authentication is not enough (PROTOCOL §7). Files above
//! 25 MiB are refused; chunking exists only on the wire.

use aes_gcm::aead::{Aead, KeyInit, Payload};
use aes_gcm::{Aes256Gcm, Nonce};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

pub const VERSION: u8 = 1;
pub const MAX_FILE_BYTES: usize = 25 * 1024 * 1024;
const AAD: &[u8] = b"arveil/file/v1";

#[derive(Debug, thiserror::Error)]
pub enum AttachmentError {
    #[error("attachment: file of {0} bytes exceeds the 25 MiB limit")]
    TooLarge(usize),
    #[error("attachment: randomness unavailable")]
    Random,
    #[error("attachment: encryption failed")]
    Encrypt,
    #[error("attachment: ciphertext hash mismatch")]
    HashMismatch,
    #[error("attachment: authentication failed")]
    Authentication,
    #[error("attachment: descriptor: {0}")]
    Descriptor(String),
}

/// What the recipient needs; never leaves MLS protection.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileDescriptor {
    pub version: u8,
    #[serde(with = "serde_bytes")]
    pub blob_id: Vec<u8>,
    #[serde(with = "serde_bytes")]
    pub read_capability: Vec<u8>,
    #[serde(with = "serde_bytes")]
    pub file_key: Vec<u8>,
    #[serde(with = "serde_bytes")]
    pub nonce: Vec<u8>,
    #[serde(with = "serde_bytes")]
    pub ciphertext_hash: Vec<u8>,
    pub size: u64,
    pub name: String,
    pub mime: String,
}

impl FileDescriptor {
    pub fn encode(&self) -> Result<Vec<u8>, AttachmentError> {
        crate::signed::canonical(self).map_err(|e| AttachmentError::Descriptor(e.to_string()))
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, AttachmentError> {
        let d: Self =
            ciborium::from_reader(bytes).map_err(|e| AttachmentError::Descriptor(e.to_string()))?;
        if d.version != VERSION {
            return Err(AttachmentError::Descriptor(format!(
                "unsupported version {}",
                d.version
            )));
        }
        Ok(d)
    }

    /// File name safe to write under a downloads directory: base name only,
    /// no path separators, no leading dots, bounded length.
    pub fn safe_name(&self) -> String {
        let base = self
            .name
            .rsplit(['/', '\\'])
            .next()
            .unwrap_or("file")
            .trim_start_matches('.')
            .chars()
            .filter(|c| !c.is_control())
            .take(120)
            .collect::<String>();
        if base.is_empty() { "file".into() } else { base }
    }
}

/// An encrypted file ready to upload.
pub struct Encrypted {
    pub file_key: Vec<u8>,
    pub nonce: Vec<u8>,
    pub ciphertext: Vec<u8>,
    pub ciphertext_hash: Vec<u8>,
}

pub fn sha256(bytes: &[u8]) -> Vec<u8> {
    Sha256::digest(bytes).to_vec()
}

/// Encrypt a whole file with a fresh key and nonce.
pub fn encrypt(plaintext: &[u8]) -> Result<Encrypted, AttachmentError> {
    let mut file_key = [0u8; 32];
    let mut nonce = [0u8; 12];
    getrandom::fill(&mut file_key).map_err(|_| AttachmentError::Random)?;
    getrandom::fill(&mut nonce).map_err(|_| AttachmentError::Random)?;
    encrypt_with(&file_key, &nonce, plaintext)
}

/// Encrypt with a key and nonce already chosen. Used when an interrupted
/// upload resumes: the same inputs give the same ciphertext, so the bytes
/// the realm already holds stay valid (M3.3). Never call it twice with the
/// same key and nonce over different plaintext.
pub fn encrypt_with(
    file_key: &[u8],
    nonce: &[u8],
    plaintext: &[u8],
) -> Result<Encrypted, AttachmentError> {
    if plaintext.len() > MAX_FILE_BYTES {
        return Err(AttachmentError::TooLarge(plaintext.len()));
    }
    if nonce.len() != 12 {
        return Err(AttachmentError::Encrypt);
    }
    let cipher = Aes256Gcm::new_from_slice(file_key).map_err(|_| AttachmentError::Encrypt)?;
    let ciphertext = cipher
        .encrypt(
            Nonce::from_slice(nonce),
            Payload {
                msg: plaintext,
                aad: AAD,
            },
        )
        .map_err(|_| AttachmentError::Encrypt)?;
    let ciphertext_hash = sha256(&ciphertext);
    Ok(Encrypted {
        file_key: file_key.to_vec(),
        nonce: nonce.to_vec(),
        ciphertext,
        ciphertext_hash,
    })
}

/// Verify the hash, then authenticate and decrypt.
pub fn decrypt(d: &FileDescriptor, ciphertext: &[u8]) -> Result<Vec<u8>, AttachmentError> {
    if sha256(ciphertext) != d.ciphertext_hash {
        return Err(AttachmentError::HashMismatch);
    }
    let cipher =
        Aes256Gcm::new_from_slice(&d.file_key).map_err(|_| AttachmentError::Authentication)?;
    if d.nonce.len() != 12 {
        return Err(AttachmentError::Authentication);
    }
    cipher
        .decrypt(
            Nonce::from_slice(&d.nonce),
            Payload {
                msg: ciphertext,
                aad: AAD,
            },
        )
        .map_err(|_| AttachmentError::Authentication)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn descriptor(e: &Encrypted, size: u64) -> FileDescriptor {
        FileDescriptor {
            version: VERSION,
            blob_id: vec![1; 16],
            read_capability: vec![2; 32],
            file_key: e.file_key.clone(),
            nonce: e.nonce.clone(),
            ciphertext_hash: e.ciphertext_hash.clone(),
            size,
            name: "../../etc/passwd".into(),
            mime: "text/plain".into(),
        }
    }

    #[test]
    fn roundtrip_hash_and_tag_checked() {
        let plain = vec![7u8; 100_000];
        let e = encrypt(&plain).unwrap();
        assert_ne!(e.ciphertext[..32], plain[..32]);
        let d = descriptor(&e, plain.len() as u64);
        assert_eq!(decrypt(&d, &e.ciphertext).unwrap(), plain);
        assert_eq!(d.safe_name(), "passwd");

        let mut tampered = e.ciphertext.clone();
        tampered[500] ^= 1;
        assert!(matches!(
            decrypt(&d, &tampered),
            Err(AttachmentError::HashMismatch)
        ));
        // Right hash, wrong key: authentication fails.
        let mut d2 = d.clone();
        d2.file_key = vec![9; 32];
        assert!(matches!(
            decrypt(&d2, &e.ciphertext),
            Err(AttachmentError::Authentication)
        ));
        // Descriptor round trip.
        let bytes = d.encode().unwrap();
        assert_eq!(FileDescriptor::decode(&bytes).unwrap(), d);
    }

    #[test]
    fn the_same_key_and_nonce_reproduce_the_ciphertext() {
        let plain = vec![3u8; 5000];
        let a = encrypt(&plain).unwrap();
        let b = encrypt_with(&a.file_key, &a.nonce, &plain).unwrap();
        assert_eq!(a.ciphertext, b.ciphertext);
        assert_eq!(a.ciphertext_hash, b.ciphertext_hash);
        assert!(encrypt_with(&a.file_key, &[0; 11], &plain).is_err());
    }

    #[test]
    fn size_limit() {
        assert!(matches!(
            encrypt(&vec![0u8; MAX_FILE_BYTES + 1]),
            Err(AttachmentError::TooLarge(_))
        ));
    }
}
