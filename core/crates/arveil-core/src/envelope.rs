//! Outer envelope per recipient device (PROTOCOL §1–§2, THREAT_MODEL §3).
//!
//! One MLS ciphertext, one HPKE seal per receiving device. The envelope hides
//! MLS headers and cross-recipient equality from the relay; it does not hide
//! size, timing or destination. Sizes are blurred with bucketed padding.
//!
//! ```text
//! info = "arveil/envelope/v1"
//! aad  = canonical CBOR { version, realm_id, mailbox_id, delivery_id }
//! InnerPayload { version, kind, payload, padding }   (canonical CBOR, padded to a bucket)
//! ```
//!
//! Suite: DHKEM(X25519, HKDF-SHA256), HKDF-SHA256, AES-128-GCM (RFC 9180),
//! base mode. The recipient key is the device's `envelope_hpke_public_key`
//! from its credential; it is static, so no forward secrecy is claimed for
//! the outer layer (content confidentiality rests on MLS).

use hpke_rs::{Hpke, HpkePrivateKey, HpkePublicKey, Mode};
use hpke_rs_crypto::types::{AeadAlgorithm, KdfAlgorithm, KemAlgorithm};
use hpke_rs_rust_crypto::HpkeRustCrypto;
use serde::{Deserialize, Serialize};

use crate::signed::canonical;

pub const VERSION: u8 = 1;
const INFO: &[u8] = b"arveil/envelope/v1";

/// Inner payload kinds (PROTOCOL §2, `kind`).
pub const KIND_MLS: u8 = 1;
pub const KIND_DEVICE_LINK: u8 = 2;
pub const KIND_HISTORY: u8 = 3;

/// Padding buckets for the encoded inner payload, in bytes. The largest
/// bucket matches the relay's envelope limit (ARCHITECTURE §5).
pub const BUCKETS: [usize; 6] = [256, 1024, 4096, 16_384, 65_536, 262_144];

#[derive(Debug, thiserror::Error)]
pub enum EnvelopeError {
    #[error("envelope: payload too large for any bucket ({0} bytes)")]
    TooLarge(usize),
    #[error("envelope: encode: {0}")]
    Encode(String),
    #[error("envelope: decode: {0}")]
    Decode(String),
    #[error("envelope: hpke: {0:?}")]
    Hpke(hpke_rs::HpkeError),
    #[error("envelope: unsupported version {0}")]
    UnsupportedVersion(u8),
}

/// Authenticated context: the envelope is bound to one delivery.
#[derive(Clone, Debug, Serialize)]
pub struct EnvelopeContext<'a> {
    pub version: u8,
    #[serde(with = "serde_bytes")]
    pub realm_id: &'a [u8],
    #[serde(with = "serde_bytes")]
    pub mailbox_id: &'a [u8],
    #[serde(with = "serde_bytes")]
    pub delivery_id: &'a [u8],
}

impl<'a> EnvelopeContext<'a> {
    pub fn new(realm_id: &'a [u8], mailbox_id: &'a [u8], delivery_id: &'a [u8]) -> Self {
        Self {
            version: VERSION,
            realm_id,
            mailbox_id,
            delivery_id,
        }
    }

    fn aad(&self) -> Result<Vec<u8>, EnvelopeError> {
        canonical(self).map_err(|e| EnvelopeError::Encode(e.to_string()))
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct InnerPayload {
    pub version: u8,
    pub kind: u8,
    #[serde(with = "serde_bytes")]
    pub payload: Vec<u8>,
    #[serde(with = "serde_bytes")]
    pub padding: Vec<u8>,
}

/// What travels to the relay: the KEM encapsulation and the ciphertext.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Sealed {
    pub enc: Vec<u8>,
    pub ciphertext: Vec<u8>,
}

fn suite() -> Hpke<HpkeRustCrypto> {
    Hpke::new(
        Mode::Base,
        KemAlgorithm::DhKem25519,
        KdfAlgorithm::HkdfSha256,
        AeadAlgorithm::Aes128Gcm,
    )
}

/// Bucket the encoded inner payload will be padded to.
pub fn bucket_for(encoded_len: usize) -> Result<usize, EnvelopeError> {
    BUCKETS
        .iter()
        .copied()
        .find(|b| *b >= encoded_len)
        .ok_or(EnvelopeError::TooLarge(encoded_len))
}

/// Encode `kind`/`payload` padded to a bucket boundary.
pub fn pad(kind: u8, payload: &[u8]) -> Result<Vec<u8>, EnvelopeError> {
    let mut inner = InnerPayload {
        version: VERSION,
        kind,
        payload: payload.to_vec(),
        padding: Vec::new(),
    };
    let base = canonical(&inner).map_err(|e| EnvelopeError::Encode(e.to_string()))?;
    let target = bucket_for(base.len())?;
    // The CBOR length prefix of `padding` grows with its size; converge.
    let mut pad_len = target - base.len();
    for _ in 0..4 {
        inner.padding = vec![0u8; pad_len.saturating_sub(inner_padding_overhead(pad_len))];
        let encoded = canonical(&inner).map_err(|e| EnvelopeError::Encode(e.to_string()))?;
        if encoded.len() == target {
            return Ok(encoded);
        }
        pad_len = pad_len + target - encoded.len();
    }
    Err(EnvelopeError::Encode("padding did not converge".into()))
}

/// Extra bytes the CBOR byte-string header takes over the 1-byte header of
/// an empty padding.
fn inner_padding_overhead(len: usize) -> usize {
    match len {
        0..=23 => 0,
        24..=255 => 1,
        256..=65_535 => 2,
        _ => 4,
    }
}

/// Seal `payload` for `recipient_public` (32-byte X25519) under `ctx`.
pub fn seal(
    recipient_public: &[u8],
    ctx: &EnvelopeContext<'_>,
    kind: u8,
    payload: &[u8],
) -> Result<Sealed, EnvelopeError> {
    let plaintext = pad(kind, payload)?;
    let pk = HpkePublicKey::new(recipient_public.to_vec());
    let (enc, ct) = suite()
        .seal(&pk, INFO, &ctx.aad()?, &plaintext, None, None, None)
        .map_err(EnvelopeError::Hpke)?;
    Ok(Sealed {
        enc: enc.as_slice().to_vec(),
        ciphertext: ct.as_slice().to_vec(),
    })
}

/// Open a sealed envelope with the recipient's private key under `ctx`.
pub fn open(
    recipient_private: &[u8],
    ctx: &EnvelopeContext<'_>,
    sealed: &Sealed,
) -> Result<InnerPayload, EnvelopeError> {
    let sk = HpkePrivateKey::new(recipient_private.to_vec());
    let plaintext = suite()
        .open(
            &sealed.enc,
            &sk,
            INFO,
            &ctx.aad()?,
            &sealed.ciphertext,
            None,
            None,
            None,
        )
        .map_err(EnvelopeError::Hpke)?;
    let inner: InnerPayload = ciborium::from_reader(plaintext.as_slice())
        .map_err(|e| EnvelopeError::Decode(e.to_string()))?;
    if inner.version != VERSION {
        return Err(EnvelopeError::UnsupportedVersion(inner.version));
    }
    Ok(inner)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::channel::StaticKeypair;

    #[test]
    fn seal_open_roundtrip_and_context_binding() {
        let kp = StaticKeypair::generate().unwrap();
        let ctx = EnvelopeContext::new(b"realm", b"mailbox-1", b"delivery-1");
        let sealed = seal(&kp.public, &ctx, KIND_MLS, b"hello").unwrap();
        let inner = open(&kp.private, &ctx, &sealed).unwrap();
        assert_eq!(inner.kind, KIND_MLS);
        assert_eq!(inner.payload, b"hello");

        // Same plaintext twice: different encapsulation and ciphertext.
        let again = seal(&kp.public, &ctx, KIND_MLS, b"hello").unwrap();
        assert_ne!(again, sealed);

        // Wrong delivery id or mailbox: AAD mismatch.
        let other = EnvelopeContext::new(b"realm", b"mailbox-1", b"delivery-2");
        assert!(open(&kp.private, &other, &sealed).is_err());
        let other = EnvelopeContext::new(b"realm", b"mailbox-2", b"delivery-1");
        assert!(open(&kp.private, &other, &sealed).is_err());

        // Wrong key.
        let stranger = StaticKeypair::generate().unwrap();
        assert!(open(&stranger.private, &ctx, &sealed).is_err());
    }

    #[test]
    fn padding_lands_exactly_on_buckets() {
        for (len, expect) in [
            (0, 256),
            (200, 256),
            (240, 1024),
            (900, 1024),
            (1000, 4096),
            (5000, 16_384),
        ] {
            let encoded = pad(KIND_MLS, &vec![7u8; len]).unwrap();
            assert_eq!(encoded.len(), expect, "payload of {len} bytes");
            let inner: InnerPayload = ciborium::from_reader(encoded.as_slice()).unwrap();
            assert_eq!(inner.payload.len(), len);
        }
        assert!(pad(KIND_MLS, &vec![0u8; 300_000]).is_err());
    }

    #[test]
    fn ciphertext_size_reveals_only_the_bucket() {
        let kp = StaticKeypair::generate().unwrap();
        let ctx = EnvelopeContext::new(b"r", b"m", b"d");
        let a = seal(&kp.public, &ctx, KIND_MLS, b"x").unwrap();
        let b = seal(&kp.public, &ctx, KIND_MLS, &[1u8; 150]).unwrap();
        assert_eq!(a.ciphertext.len(), b.ciphertext.len());
    }
}
