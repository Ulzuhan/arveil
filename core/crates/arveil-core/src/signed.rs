//! Deterministic CBOR and the signed-object envelope used by every object
//! Arveil signs itself (PROTOCOL §1): endpoint lists, device credentials,
//! device manifests.
//!
//! ```text
//! SignedObject { context: tstr, body: bstr, signature: bstr(64) }
//! signature = Ed25519( u16be(len(context)) || context || body )
//! body      = deterministic CBOR (RFC 8949 §4.2.1 core ordering)
//! ```
//!
//! Verifiers check the signature over the *received* body bytes and then
//! decode; they never re-encode. Determinism matters for hashing signed
//! objects consistently across implementations.

use ciborium::Value;
use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};
use serde::{Deserialize, Serialize, de::DeserializeOwned};

#[derive(Debug, thiserror::Error)]
pub enum SignedError {
    #[error("signed object: encode: {0}")]
    Encode(String),
    #[error("signed object: decode: {0}")]
    Decode(String),
    #[error("signed object: expected context {expected:?}, got {got:?}")]
    WrongContext { expected: String, got: String },
    #[error("signed object: bad signature")]
    BadSignature,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SignedObject {
    pub context: String,
    #[serde(with = "serde_bytes")]
    pub body: Vec<u8>,
    #[serde(with = "serde_bytes")]
    pub signature: Vec<u8>,
}

/// Bytes covered by the signature.
pub fn signing_input(context: &str, body: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(2 + context.len() + body.len());
    out.extend_from_slice(&(context.len() as u16).to_be_bytes());
    out.extend_from_slice(context.as_bytes());
    out.extend_from_slice(body);
    out
}

/// Encode with RFC 8949 core deterministic map ordering.
pub fn canonical<T: Serialize>(value: &T) -> Result<Vec<u8>, SignedError> {
    let mut v = Value::serialized(value).map_err(|e| SignedError::Encode(e.to_string()))?;
    sort_maps(&mut v);
    let mut out = Vec::new();
    ciborium::into_writer(&v, &mut out).map_err(|e| SignedError::Encode(e.to_string()))?;
    Ok(out)
}

fn encoded(v: &Value) -> Vec<u8> {
    let mut out = Vec::new();
    ciborium::into_writer(v, &mut out).expect("value encodes");
    out
}

fn sort_maps(v: &mut Value) {
    match v {
        Value::Map(entries) => {
            for (_, val) in entries.iter_mut() {
                sort_maps(val);
            }
            entries.sort_by_cached_key(|(k, _)| {
                let e = encoded(k);
                (e.len(), e)
            });
        }
        Value::Array(items) => items.iter_mut().for_each(sort_maps),
        Value::Tag(_, inner) => sort_maps(inner),
        _ => {}
    }
}

/// Sign `body` under `context` and return the SignedObject bytes.
pub fn sign(context: &str, body: &[u8], key: &SigningKey) -> Result<Vec<u8>, SignedError> {
    let signature = key.sign(&signing_input(context, body)).to_bytes().to_vec();
    canonical(&SignedObject {
        context: context.to_string(),
        body: body.to_vec(),
        signature,
    })
}

/// Encode `value` canonically, then sign it.
pub fn sign_value<T: Serialize>(
    context: &str,
    value: &T,
    key: &SigningKey,
) -> Result<Vec<u8>, SignedError> {
    sign(context, &canonical(value)?, key)
}

/// Verify a SignedObject against `key` and `context`; returns the body bytes.
pub fn verify(signed: &[u8], context: &str, key: &VerifyingKey) -> Result<Vec<u8>, SignedError> {
    let so: SignedObject =
        ciborium::from_reader(signed).map_err(|e| SignedError::Decode(e.to_string()))?;
    if so.context != context {
        return Err(SignedError::WrongContext {
            expected: context.to_string(),
            got: so.context,
        });
    }
    let sig: [u8; 64] = so
        .signature
        .as_slice()
        .try_into()
        .map_err(|_| SignedError::BadSignature)?;
    key.verify_strict(
        &signing_input(&so.context, &so.body),
        &Signature::from_bytes(&sig),
    )
    .map_err(|_| SignedError::BadSignature)?;
    Ok(so.body)
}

/// Verify and decode the body.
pub fn verify_value<T: DeserializeOwned>(
    signed: &[u8],
    context: &str,
    key: &VerifyingKey,
) -> Result<T, SignedError> {
    let body = verify(signed, context, key)?;
    ciborium::from_reader(body.as_slice()).map_err(|e| SignedError::Decode(e.to_string()))
}

/// Read the context and body of a signed object without verifying it, for
/// callers that must first learn which key to verify with (a credential
/// carries its own root key).
pub fn peek(signed: &[u8]) -> Result<SignedObject, SignedError> {
    ciborium::from_reader(signed).map_err(|e| SignedError::Decode(e.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Serialize)]
    struct Unsorted {
        zeta: u8,
        a: u8,
        long_name: u8,
        bb: u8,
    }

    #[test]
    fn canonical_orders_keys_by_length_then_bytes() {
        let bytes = canonical(&Unsorted {
            zeta: 1,
            a: 2,
            long_name: 3,
            bb: 4,
        })
        .unwrap();
        // a, bb, zeta, long_name
        let expected = [
            0xa4, 0x61, b'a', 2, 0x62, b'b', b'b', 4, 0x64, b'z', b'e', b't', b'a', 1, 0x69, b'l',
            b'o', b'n', b'g', b'_', b'n', b'a', b'm', b'e', 3,
        ];
        assert_eq!(bytes, expected);
    }

    #[test]
    fn sign_verify_and_context_binding() {
        let key = SigningKey::from_bytes(&[3u8; 32]);
        let signed = sign("arveil/test/v1", b"hello", &key).unwrap();
        assert_eq!(
            verify(&signed, "arveil/test/v1", &key.verifying_key()).unwrap(),
            b"hello"
        );
        assert!(matches!(
            verify(&signed, "arveil/other/v1", &key.verifying_key()),
            Err(SignedError::WrongContext { .. })
        ));
        let other = SigningKey::from_bytes(&[4u8; 32]);
        assert!(matches!(
            verify(&signed, "arveil/test/v1", &other.verifying_key()),
            Err(SignedError::BadSignature)
        ));
    }
}
