//! `RealmEndpointList` and its signed envelope (ADR-008, PROTOCOL §3).
//!
//! Wire format, shared with the Go relay's `internal/endpoints`:
//!
//! ```text
//! SignedObject { context: tstr, body: bstr, signature: bstr(64) }
//! signature = Ed25519( u16be(len(context)) || context || body )
//! body      = deterministic CBOR of RealmEndpointList
//! ```
//!
//! The device verifies with the realm signing key it learned at bootstrap,
//! keeps the highest sequence it has accepted, and refuses rollbacks.

use ed25519_dalek::VerifyingKey;
use serde::{Deserialize, Serialize};

use crate::signed::{self, SignedError};

pub const CONTEXT: &str = "arveil/endpoint-list/v1";
pub const VERSION: u8 = 1;

#[derive(Debug, thiserror::Error)]
pub enum EndpointListError {
    #[error("endpoint list: decode: {0}")]
    Decode(String),
    #[error("endpoint list: wrong context {0:?}")]
    WrongContext(String),
    #[error("endpoint list: bad signature")]
    BadSignature,
    #[error("endpoint list: unsupported version {0}")]
    UnsupportedVersion(u8),
    #[error("endpoint list: realm id does not match the bootstrap")]
    RealmMismatch,
    #[error("endpoint list: sequence {got} does not exceed known {known}")]
    Rollback { got: u64, known: u64 },
    #[error("endpoint list: no endpoints")]
    Empty,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Endpoint {
    pub kind: String,
    pub url: String,
    pub priority: u8,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RealmEndpointList {
    pub version: u8,
    #[serde(with = "serde_bytes")]
    pub realm_id: Vec<u8>,
    pub sequence: u64,
    #[serde(with = "serde_bytes")]
    pub realm_noise_public_key: Vec<u8>,
    pub endpoints: Vec<Endpoint>,
}

pub use crate::signed::{SignedObject, signing_input};

/// Verify a signed list against the realm signing key and the expected
/// realm id; `known_sequence` is the highest sequence accepted so far.
pub fn verify(
    signed: &[u8],
    realm_signing_key: &VerifyingKey,
    expected_realm_id: &[u8],
    known_sequence: Option<u64>,
) -> Result<RealmEndpointList, EndpointListError> {
    let list: RealmEndpointList = signed::verify_value(signed, CONTEXT, realm_signing_key)
        .map_err(|e| match e {
            SignedError::WrongContext { got, .. } => EndpointListError::WrongContext(got),
            SignedError::BadSignature => EndpointListError::BadSignature,
            other => EndpointListError::Decode(other.to_string()),
        })?;
    if list.version != VERSION {
        return Err(EndpointListError::UnsupportedVersion(list.version));
    }
    if list.realm_id != expected_realm_id {
        return Err(EndpointListError::RealmMismatch);
    }
    if let Some(known) = known_sequence
        && list.sequence <= known
    {
        return Err(EndpointListError::Rollback {
            got: list.sequence,
            known,
        });
    }
    if list.endpoints.is_empty() {
        return Err(EndpointListError::Empty);
    }
    Ok(list)
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::{Signer, SigningKey};

    fn signed_list(key: &SigningKey, sequence: u64, realm_id: &[u8]) -> Vec<u8> {
        let list = RealmEndpointList {
            version: VERSION,
            realm_id: realm_id.to_vec(),
            sequence,
            realm_noise_public_key: vec![9; 32],
            endpoints: vec![Endpoint {
                kind: "lan".into(),
                url: "ws://127.0.0.1:8447/v1/channel".into(),
                priority: 0,
            }],
        };
        let mut body = Vec::new();
        ciborium::into_writer(&list, &mut body).unwrap();
        let signature = key.sign(&signing_input(CONTEXT, &body)).to_bytes().to_vec();
        let mut out = Vec::new();
        ciborium::into_writer(
            &SignedObject {
                context: CONTEXT.into(),
                body,
                signature,
            },
            &mut out,
        )
        .unwrap();
        out
    }

    #[test]
    fn verifies_and_enforces_sequence_and_realm() {
        let key = SigningKey::from_bytes(&[7u8; 32]);
        let vk = key.verifying_key();
        let realm = [1u8; 32];

        let s5 = signed_list(&key, 5, &realm);
        let list = verify(&s5, &vk, &realm, None).unwrap();
        assert_eq!(list.sequence, 5);
        assert!(verify(&s5, &vk, &realm, Some(4)).is_ok());
        assert!(matches!(
            verify(&s5, &vk, &realm, Some(5)),
            Err(EndpointListError::Rollback { .. })
        ));
        assert!(matches!(
            verify(&s5, &vk, &[2u8; 32], None),
            Err(EndpointListError::RealmMismatch)
        ));

        let other = SigningKey::from_bytes(&[8u8; 32]).verifying_key();
        assert!(matches!(
            verify(&s5, &other, &realm, None),
            Err(EndpointListError::BadSignature)
        ));

        let mut tampered = s5.clone();
        let last = tampered.len() - 1;
        tampered[last] ^= 1;
        assert!(verify(&tampered, &vk, &realm, None).is_err());
    }
}
