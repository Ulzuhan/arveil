//! Frame objects and their CBOR encoding.
//!
//! A frame is `{ id, payload }`. `id` correlates requests and responses. The
//! payload is an externally tagged enum: on the wire, a one-entry map whose
//! key is the variant name. The Go relay decodes the same shape.
//!
//! Frames are not signed objects; deterministic encoding is not required
//! here (it is for credentials and manifests, see `docs/PROTOCOL.md` §1).

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
    /// Generic failure reply.
    Error {
        code: u16,
        message: String,
    },
}

/// Encode a frame; refuses frames over [`MAX_FRAME_BYTES`].
pub fn encode(frame: &Frame) -> Result<Vec<u8>, CodecError> {
    let mut out = Vec::new();
    ciborium::into_writer(frame, &mut out).map_err(|e| CodecError::Encode(e.to_string()))?;
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
