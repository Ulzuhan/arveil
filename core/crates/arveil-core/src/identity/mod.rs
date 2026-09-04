//! Cryptographic identity (ADR-005, PROTOCOL §2–§3): a root Ed25519 key, the
//! identity id derived from it, device credentials signed by the root and a
//! chained, sequenced device manifest.
//!
//! Phase 0 (M0.3) keeps the root key on the device that uses it. The
//! identity kit and the admin-device model of ADR-006 come in Phase 2.

use ed25519_dalek::{SigningKey, VerifyingKey};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::channel::StaticKeypair;
use crate::signed::{self, SignedError};

pub const CREDENTIAL_CONTEXT: &str = "arveil/device-credential/v1";
pub const MANIFEST_CONTEXT: &str = "arveil/device-manifest/v1";
const IDENTITY_ID_CONTEXT: &str = "arveil/identity-id/v1";
const CREDENTIAL_HASH_CONTEXT: &str = "arveil/credential-hash/v1";
const MANIFEST_HASH_CONTEXT: &str = "arveil/manifest-hash/v1";

pub const CREDENTIAL_VERSION: u8 = 1;
pub const MANIFEST_VERSION: u8 = 1;

/// `allowed_uses` bit flags.
pub const USE_MLS_LEAF: u8 = 0b001;
pub const USE_TRANSPORT: u8 = 0b010;
pub const USE_ENVELOPE: u8 = 0b100;

#[derive(Debug, thiserror::Error)]
pub enum IdentityError {
    #[error(transparent)]
    Signed(#[from] SignedError),
    #[error("identity: randomness unavailable")]
    Random,
    #[error("identity: unsupported version {0}")]
    UnsupportedVersion(u8),
    #[error("identity: credential root does not match the expected root")]
    RootMismatch,
    #[error("identity: credential not valid at time {0}")]
    NotValidAt(u64),
    #[error("identity: manifest identity id does not match the root")]
    IdentityMismatch,
    #[error("identity: manifest sequence {got} does not exceed known {known}")]
    ManifestRollback { got: u64, known: u64 },
    #[error(
        "identity: manifest sequence {0} conflicts with a different manifest of the same sequence"
    )]
    ManifestConflict(u64),
    #[error("identity: manifest chain broken (previous hash mismatch)")]
    ChainBroken,
}

fn hash(context: &str, data: &[u8]) -> Vec<u8> {
    let mut h = Sha256::new();
    h.update(context.as_bytes());
    h.update(data);
    h.finalize().to_vec()
}

fn random_bytes<const N: usize>() -> Result<[u8; N], IdentityError> {
    let mut b = [0u8; N];
    getrandom::fill(&mut b).map_err(|_| IdentityError::Random)?;
    Ok(b)
}

/// Identity id of a root public key: SHA-256 with domain separation.
pub fn identity_id(root_public: &VerifyingKey) -> Vec<u8> {
    hash(IDENTITY_ID_CONTEXT, root_public.as_bytes())
}

/// Hash by which a signed credential is referenced in manifests.
pub fn credential_hash(signed_credential: &[u8]) -> Vec<u8> {
    hash(CREDENTIAL_HASH_CONTEXT, signed_credential)
}

/// Hash by which a signed manifest is chained to its successor.
pub fn manifest_hash(signed_manifest: &[u8]) -> Vec<u8> {
    hash(MANIFEST_HASH_CONTEXT, signed_manifest)
}

/// The root key. Its secret is the identity; losing it ends continuity.
pub struct RootKey {
    pub signing: SigningKey,
}

impl RootKey {
    pub fn generate() -> Result<Self, IdentityError> {
        Ok(Self {
            signing: SigningKey::from_bytes(&random_bytes::<32>()?),
        })
    }

    pub fn from_seed(seed: &[u8; 32]) -> Self {
        Self {
            signing: SigningKey::from_bytes(seed),
        }
    }

    pub fn public(&self) -> VerifyingKey {
        self.signing.verifying_key()
    }

    pub fn identity_id(&self) -> Vec<u8> {
        identity_id(&self.public())
    }
}

/// Validity window in Unix seconds.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Validity {
    pub not_before: u64,
    pub not_after: u64,
}

/// Body of a device credential (signed by the root).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct DeviceCredential {
    pub version: u8,
    #[serde(with = "serde_bytes")]
    pub identity_root_public_key: Vec<u8>,
    #[serde(with = "serde_bytes")]
    pub device_id: Vec<u8>,
    #[serde(with = "serde_bytes")]
    pub mls_signature_public_key: Vec<u8>,
    #[serde(with = "serde_bytes")]
    pub transport_noise_public_key: Vec<u8>,
    #[serde(with = "serde_bytes")]
    pub envelope_hpke_public_key: Vec<u8>,
    pub validity: Validity,
    pub allowed_uses: u8,
}

/// Body of a device manifest (signed by the root).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct DeviceManifest {
    pub version: u8,
    #[serde(with = "serde_bytes")]
    pub identity_id: Vec<u8>,
    pub manifest_sequence: u64,
    /// Empty for the first manifest of an identity.
    #[serde(with = "serde_bytes")]
    pub previous_manifest_hash: Vec<u8>,
    pub active_credential_hashes: Vec<serde_bytes::ByteBuf>,
    pub revoked_credential_hashes: Vec<serde_bytes::ByteBuf>,
}

/// Public keys a device presents; private halves stay in `DeviceKeys`.
#[derive(Clone, Debug)]
pub struct DevicePublicKeys {
    pub device_id: Vec<u8>,
    pub mls_signature_public_key: Vec<u8>,
    pub transport_noise_public_key: Vec<u8>,
    pub envelope_hpke_public_key: Vec<u8>,
}

/// A device's own key material.
pub struct DeviceKeys {
    pub device_id: [u8; 16],
    pub transport_noise: StaticKeypair,
    /// X25519 keypair for the outer HPKE envelope (M0.4 uses it).
    pub envelope_hpke: StaticKeypair,
    pub mls_signing_public_key: Vec<u8>,
}

impl DeviceKeys {
    /// Generate transport and envelope keys; the MLS signing public key comes
    /// from the MLS engine's identity.
    pub fn generate(mls_signing_public_key: Vec<u8>) -> Result<Self, IdentityError> {
        Ok(Self {
            device_id: random_bytes::<16>()?,
            transport_noise: StaticKeypair::generate().map_err(|_| IdentityError::Random)?,
            envelope_hpke: StaticKeypair::generate().map_err(|_| IdentityError::Random)?,
            mls_signing_public_key,
        })
    }

    pub fn public(&self) -> DevicePublicKeys {
        DevicePublicKeys {
            device_id: self.device_id.to_vec(),
            mls_signature_public_key: self.mls_signing_public_key.clone(),
            transport_noise_public_key: self.transport_noise.public.clone(),
            envelope_hpke_public_key: self.envelope_hpke.public.clone(),
        }
    }
}

/// Issue a signed credential for `device` under `root`.
pub fn issue_credential(
    root: &RootKey,
    device: &DevicePublicKeys,
    validity: Validity,
    allowed_uses: u8,
) -> Result<Vec<u8>, IdentityError> {
    let body = DeviceCredential {
        version: CREDENTIAL_VERSION,
        identity_root_public_key: root.public().as_bytes().to_vec(),
        device_id: device.device_id.clone(),
        mls_signature_public_key: device.mls_signature_public_key.clone(),
        transport_noise_public_key: device.transport_noise_public_key.clone(),
        envelope_hpke_public_key: device.envelope_hpke_public_key.clone(),
        validity,
        allowed_uses,
    };
    Ok(signed::sign_value(
        CREDENTIAL_CONTEXT,
        &body,
        &root.signing,
    )?)
}

/// A credential accepted by [`verify_credential`].
#[derive(Clone, Debug)]
pub struct VerifiedCredential {
    pub credential: DeviceCredential,
    pub root: VerifyingKey,
    pub hash: Vec<u8>,
}

/// Verify a signed credential. The root key is read from the body and the
/// signature checked against it; `expected_root`, when known (a verified
/// contact), must match. `now` is the local clock, informational but
/// enforced against the validity window.
pub fn verify_credential(
    signed_credential: &[u8],
    expected_root: Option<&VerifyingKey>,
    now: u64,
) -> Result<VerifiedCredential, IdentityError> {
    let so = signed::peek(signed_credential)?;
    let body: DeviceCredential = ciborium::from_reader(so.body.as_slice())
        .map_err(|e| SignedError::Decode(e.to_string()))?;
    if body.version != CREDENTIAL_VERSION {
        return Err(IdentityError::UnsupportedVersion(body.version));
    }
    let root_bytes: [u8; 32] = body
        .identity_root_public_key
        .as_slice()
        .try_into()
        .map_err(|_| SignedError::Decode("root key length".into()))?;
    let root = VerifyingKey::from_bytes(&root_bytes)
        .map_err(|_| SignedError::Decode("root key".into()))?;
    if let Some(expected) = expected_root
        && expected != &root
    {
        return Err(IdentityError::RootMismatch);
    }
    signed::verify(signed_credential, CREDENTIAL_CONTEXT, &root)?;
    if now < body.validity.not_before || now > body.validity.not_after {
        return Err(IdentityError::NotValidAt(now));
    }
    Ok(VerifiedCredential {
        credential: body,
        root,
        hash: credential_hash(signed_credential),
    })
}

/// What a client remembers about the newest manifest it accepted.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ManifestState {
    pub sequence: u64,
    pub hash: Vec<u8>,
}

/// Build and sign the next manifest.
pub fn issue_manifest(
    root: &RootKey,
    previous: Option<&ManifestState>,
    active: &[Vec<u8>],
    revoked: &[Vec<u8>],
) -> Result<Vec<u8>, IdentityError> {
    let body = DeviceManifest {
        version: MANIFEST_VERSION,
        identity_id: root.identity_id(),
        manifest_sequence: previous.map_or(1, |p| p.sequence + 1),
        previous_manifest_hash: previous.map_or_else(Vec::new, |p| p.hash.clone()),
        active_credential_hashes: active
            .iter()
            .cloned()
            .map(serde_bytes::ByteBuf::from)
            .collect(),
        revoked_credential_hashes: revoked
            .iter()
            .cloned()
            .map(serde_bytes::ByteBuf::from)
            .collect(),
    };
    Ok(signed::sign_value(MANIFEST_CONTEXT, &body, &root.signing)?)
}

/// Verify a manifest against the root and the newest known state:
/// rollbacks are refused, an equal sequence with different content is a
/// conflict, and the chain must link to the known hash.
pub fn accept_manifest(
    signed_manifest: &[u8],
    root: &VerifyingKey,
    known: Option<&ManifestState>,
) -> Result<(DeviceManifest, ManifestState), IdentityError> {
    let body: DeviceManifest = signed::verify_value(signed_manifest, MANIFEST_CONTEXT, root)?;
    if body.version != MANIFEST_VERSION {
        return Err(IdentityError::UnsupportedVersion(body.version));
    }
    if body.identity_id != identity_id(root) {
        return Err(IdentityError::IdentityMismatch);
    }
    let hash = manifest_hash(signed_manifest);
    match known {
        None => {}
        Some(k) if body.manifest_sequence == k.sequence => {
            if hash == k.hash {
                // Same manifest seen again: idempotent.
                return Ok((
                    body,
                    ManifestState {
                        sequence: k.sequence,
                        hash,
                    },
                ));
            }
            return Err(IdentityError::ManifestConflict(k.sequence));
        }
        Some(k) if body.manifest_sequence < k.sequence => {
            return Err(IdentityError::ManifestRollback {
                got: body.manifest_sequence,
                known: k.sequence,
            });
        }
        Some(k)
            if body.manifest_sequence == k.sequence + 1
                && body.previous_manifest_hash != k.hash =>
        {
            return Err(IdentityError::ChainBroken);
        }
        // A jump of more than one is accepted (the client missed some
        // manifests) but cannot be chain-checked; PROTOCOL §4 leaves
        // detection of hidden updates to cross-checks between clients.
        Some(_) => {}
    }
    let state = ManifestState {
        sequence: body.manifest_sequence,
        hash,
    };
    Ok((body, state))
}

#[cfg(test)]
mod tests;
