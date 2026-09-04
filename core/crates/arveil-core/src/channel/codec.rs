//! Frame objects and their CBOR encoding.
//!
//! A frame is `{ id, payload }`. `id` correlates requests and responses. The
//! payload is an externally tagged enum: on the wire, a one-entry map whose
//! key is the variant name. The Go relay decodes the same shape.
//!
//! Frames are not signed objects, but they are encoded deterministically
//! anyway so that the Go relay and the core produce identical bytes; the
//! Go tests use the core's encodings as vectors.

use serde::{Deserialize, Serialize};

/// Upper bound for one encoded frame. Blobs move in chunks well below this.
pub const MAX_FRAME_BYTES: usize = 1024 * 1024;

#[derive(Debug, thiserror::Error)]
pub enum CodecError {
    #[error("codec: encoded frame of {0} bytes exceeds {MAX_FRAME_BYTES}")]
    TooLarge(usize),
    #[error("codec: encode: {0}")]
    Encode(String),
    #[error("codec: decode: {0}")]
    Decode(String),
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Frame {
    pub id: u64,
    pub payload: Payload,
}

/// Phase 0 frame catalog. Grows milestone by milestone
/// (`docs/PROTOCOL.md`, "Channel frame catalog").
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Payload {
    /// Liveness for carriers that close idle connections.
    Ping,
    Pong,
    /// Request the realm's signed endpoint list.
    EndpointListGet,
    /// The signed `RealmEndpointList` bytes (deterministic CBOR, signed).
    EndpointList {
        #[serde(with = "serde_bytes")]
        signed: Vec<u8>,
    },
    /// Redeem an invite: enroll this identity and device in one transaction.
    /// Sent on a provisional session (unknown Noise static); the credential
    /// must bind that static key.
    InviteRedeem {
        #[serde(with = "serde_bytes")]
        token: Vec<u8>,
        #[serde(with = "serde_bytes")]
        credential: Vec<u8>,
        #[serde(with = "serde_bytes")]
        manifest: Vec<u8>,
    },
    /// Reply to `InviteRedeem`.
    InviteRedeemed {
        #[serde(with = "serde_bytes")]
        identity_id: Vec<u8>,
    },
    /// Register an additional credential for the session's identity.
    CredentialPut {
        #[serde(with = "serde_bytes")]
        credential: Vec<u8>,
    },
    /// Publish a newer manifest for the session's identity.
    ManifestPut {
        #[serde(with = "serde_bytes")]
        manifest: Vec<u8>,
    },
    /// Open a pairing rendezvous (M3.1). Allowed on a provisional session:
    /// the device that is pairing is not a member yet.
    PairBegin,
    PairStarted {
        #[serde(with = "serde_bytes")]
        pair_id: Vec<u8>,
        #[serde(with = "serde_bytes")]
        capability: Vec<u8>,
        expires_at: u64,
    },
    /// Write one slot of a rendezvous. Same bytes twice is idempotent;
    /// different bytes under a written slot is a conflict.
    PairPut {
        #[serde(with = "serde_bytes")]
        pair_id: Vec<u8>,
        #[serde(with = "serde_bytes")]
        capability: Vec<u8>,
        slot: String,
        #[serde(with = "serde_bytes")]
        data: Vec<u8>,
    },
    PairGet {
        #[serde(with = "serde_bytes")]
        pair_id: Vec<u8>,
        #[serde(with = "serde_bytes")]
        capability: Vec<u8>,
        slot: String,
    },
    /// Empty `data` means the slot has not been written yet.
    PairFetched {
        #[serde(with = "serde_bytes")]
        data: Vec<u8>,
    },
    /// Recover an identity on a clean device (Phase 2, M2.5). The only
    /// frame a provisional session may use to become a member without an
    /// invite: the credential must bind this session's Noise key and the
    /// manifest must advance the chain the realm already holds, both signed
    /// by the root the realm stored when the identity joined.
    RecoverIdentity {
        #[serde(with = "serde_bytes")]
        credential: Vec<u8>,
        #[serde(with = "serde_bytes")]
        manifest: Vec<u8>,
    },
    Recovered {
        #[serde(with = "serde_bytes")]
        identity_id: Vec<u8>,
        /// What the realm held before this call, so a realm restored from an
        /// older snapshot is visible to the recovering device (I-08).
        previous_sequence: u64,
    },
    /// Newest manifest of an identity on the realm (Phase 2, M2.3). The
    /// reply carries an empty `manifest` when the realm has none.
    ManifestGet {
        #[serde(with = "serde_bytes")]
        identity_id: Vec<u8>,
    },
    ManifestLatest {
        #[serde(with = "serde_bytes")]
        manifest: Vec<u8>,
    },
    /// Publish a bounded batch of KeyPackages for the session's device.
    KeyPackagesPublish {
        key_packages: Vec<serde_bytes::ByteBuf>,
    },
    /// Claim one KeyPackage of one device of an identity (consumed
    /// atomically). An empty `device_id` accepts any device (Phase 1 use).
    KeyPackagesClaim {
        #[serde(with = "serde_bytes")]
        identity_id: Vec<u8>,
        #[serde(with = "serde_bytes")]
        device_id: Vec<u8>,
    },
    KeyPackageClaimed {
        #[serde(with = "serde_bytes")]
        key_package: Vec<u8>,
    },
    /// Create a mailbox owned by the session's device (member only).
    MailboxCreate,
    MailboxCreated {
        #[serde(with = "serde_bytes")]
        mailbox_id: Vec<u8>,
        #[serde(with = "serde_bytes")]
        read_capability: Vec<u8>,
        #[serde(with = "serde_bytes")]
        write_capability: Vec<u8>,
    },
    /// Store one sealed envelope (member session + write capability).
    EnvelopePut {
        #[serde(with = "serde_bytes")]
        mailbox_id: Vec<u8>,
        #[serde(with = "serde_bytes")]
        write_capability: Vec<u8>,
        #[serde(with = "serde_bytes")]
        delivery_id: Vec<u8>,
        requested_expiry: u64,
        #[serde(with = "serde_bytes")]
        hpke_enc: Vec<u8>,
        #[serde(with = "serde_bytes")]
        ciphertext: Vec<u8>,
    },
    EnvelopeAccepted {
        effective_expiry: u64,
    },
    /// Page through a mailbox (owner + read capability).
    EnvelopeFetch {
        #[serde(with = "serde_bytes")]
        mailbox_id: Vec<u8>,
        #[serde(with = "serde_bytes")]
        read_capability: Vec<u8>,
        cursor: u64,
        limit: u16,
    },
    Envelopes {
        items: Vec<EnvelopeItem>,
        next_cursor: u64,
    },
    /// Delete named envelopes after durable local custody.
    EnvelopeAck {
        #[serde(with = "serde_bytes")]
        mailbox_id: Vec<u8>,
        #[serde(with = "serde_bytes")]
        read_capability: Vec<u8>,
        delivery_ids: Vec<serde_bytes::ByteBuf>,
    },
    /// Blobs (PROTOCOL §7): staging upload, commit, fetch. Member sessions.
    BlobUploadBegin {
        size: u64,
    },
    BlobUploadStarted {
        #[serde(with = "serde_bytes")]
        blob_id: Vec<u8>,
        #[serde(with = "serde_bytes")]
        read_capability: Vec<u8>,
    },
    BlobChunk {
        #[serde(with = "serde_bytes")]
        blob_id: Vec<u8>,
        offset: u64,
        #[serde(with = "serde_bytes")]
        data: Vec<u8>,
    },
    BlobCommit {
        #[serde(with = "serde_bytes")]
        blob_id: Vec<u8>,
        #[serde(with = "serde_bytes")]
        ciphertext_hash: Vec<u8>,
        requested_expiry: u64,
    },
    BlobCommitted {
        effective_expiry: u64,
    },
    BlobFetch {
        #[serde(with = "serde_bytes")]
        blob_id: Vec<u8>,
        #[serde(with = "serde_bytes")]
        read_capability: Vec<u8>,
        offset: u64,
        length: u32,
    },
    BlobData {
        total_size: u64,
        #[serde(with = "serde_bytes")]
        data: Vec<u8>,
    },
    /// Generic success reply.
    Ack,
    /// Generic failure reply.
    Error {
        code: u16,
        message: String,
    },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct EnvelopeItem {
    pub seq: u64,
    #[serde(with = "serde_bytes")]
    pub delivery_id: Vec<u8>,
    #[serde(with = "serde_bytes")]
    pub hpke_enc: Vec<u8>,
    #[serde(with = "serde_bytes")]
    pub ciphertext: Vec<u8>,
}

/// Error codes carried in `Payload::Error`.
pub mod error_code {
    pub const BAD_REQUEST: u16 = 400;
    pub const UNAUTHORIZED: u16 = 401;
    pub const FORBIDDEN: u16 = 403;
    pub const CONFLICT: u16 = 409;
    pub const GONE: u16 = 410;
    pub const TOO_LARGE: u16 = 413;
    pub const QUOTA: u16 = 429;
    pub const INTERNAL: u16 = 500;
}

/// Encode a frame (deterministic CBOR, so both implementations produce the
/// same bytes for the same frame); refuses frames over [`MAX_FRAME_BYTES`].
pub fn encode(frame: &Frame) -> Result<Vec<u8>, CodecError> {
    let out = crate::signed::canonical(frame).map_err(|e| CodecError::Encode(e.to_string()))?;
    if out.len() > MAX_FRAME_BYTES {
        return Err(CodecError::TooLarge(out.len()));
    }
    Ok(out)
}

/// Decode a frame; refuses inputs over [`MAX_FRAME_BYTES`] before parsing.
pub fn decode(bytes: &[u8]) -> Result<Frame, CodecError> {
    if bytes.len() > MAX_FRAME_BYTES {
        return Err(CodecError::TooLarge(bytes.len()));
    }
    ciborium::from_reader(bytes).map_err(|e| CodecError::Decode(e.to_string()))
}

#[cfg(test)]
mod vector_dump {
    use super::*;

    /// Prints hex vectors for `relay/internal/channel/channel_test.go`.
    /// Run with `cargo test -p arveil-core vector_dump -- --ignored --nocapture`.
    #[test]
    #[ignore]
    fn dump_vectors_for_go() {
        let frames = [
            Frame {
                id: 2,
                payload: Payload::KeyPackagesClaim {
                    identity_id: vec![9, 9, 9, 9],
                    device_id: vec![4, 4],
                },
            },
            Frame {
                id: 3,
                payload: Payload::ManifestGet {
                    identity_id: vec![9, 9, 9, 9],
                },
            },
            Frame {
                id: 3,
                payload: Payload::ManifestLatest {
                    manifest: vec![0xaa, 0xbb],
                },
            },
            Frame {
                id: 4,
                payload: Payload::RecoverIdentity {
                    credential: vec![1, 2],
                    manifest: vec![3],
                },
            },
            Frame {
                id: 4,
                payload: Payload::Recovered {
                    identity_id: vec![9, 9],
                    previous_sequence: 2,
                },
            },
            Frame {
                id: 5,
                payload: Payload::PairBegin,
            },
            Frame {
                id: 5,
                payload: Payload::PairStarted {
                    pair_id: vec![1, 2],
                    capability: vec![3],
                    expires_at: 9,
                },
            },
            Frame {
                id: 6,
                payload: Payload::PairPut {
                    pair_id: vec![1, 2],
                    capability: vec![3],
                    slot: "a".into(),
                    data: vec![4, 5],
                },
            },
            Frame {
                id: 7,
                payload: Payload::PairGet {
                    pair_id: vec![1, 2],
                    capability: vec![3],
                    slot: "b".into(),
                },
            },
            Frame {
                id: 7,
                payload: Payload::PairFetched { data: vec![6] },
            },
        ];
        for f in &frames {
            let bytes = encode(f).unwrap();
            let hex: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
            println!("{:?} => {hex}", f.payload);
        }
    }
}
