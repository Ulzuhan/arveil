//! Carrier-independent device↔realm channel (ADR-008).
//!
//! A channel is a Noise `IK` session carrying CBOR frames. It knows nothing
//! about WebSockets, TLS, tunnels or sockets: the carrier hands it byte
//! messages and takes byte messages back. Every byte message is exactly one
//! Noise message (≤ 65 535 bytes), so any carrier that preserves message
//! boundaries can transport it.
//!
//! Layers, bottom-up:
//! - [`noise`]: handshake and transport (`snow`), prologue binding.
//! - [`fragment`]: frames larger than one Noise payload are split and
//!   reassembled with a bounded buffer.
//! - [`codec`]: frame objects, CBOR encoding with size limits.
//! - [`Channel`]: the composition used by the core and the CLI.

pub mod codec;
pub mod fragment;
pub mod noise;

use codec::{CodecError, Frame, MAX_FRAME_BYTES};
use fragment::{FragmentError, Reassembler, fragments};
use noise::{NoiseError, Transport};

pub use noise::{Initiator, PROTOCOL_NAME, Responder, StaticKeypair, prologue};

#[derive(Debug, thiserror::Error)]
pub enum ChannelError {
    #[error(transparent)]
    Noise(#[from] NoiseError),
    #[error(transparent)]
    Fragment(#[from] FragmentError),
    #[error(transparent)]
    Codec(#[from] CodecError),
}

/// An established session: seals outgoing frames into Noise messages and
/// opens incoming Noise messages back into frames.
pub struct Channel {
    transport: Transport,
    reassembler: Reassembler,
}

impl Channel {
    pub fn new(transport: Transport) -> Self {
        Self {
            transport,
            reassembler: Reassembler::new(MAX_FRAME_BYTES),
        }
    }

    /// The peer's static Noise public key, authenticated by the handshake.
    pub fn remote_static(&self) -> &[u8] {
        self.transport.remote_static()
    }

    /// Encode, fragment and seal one frame. Returns the carrier messages to
    /// send, in order.
    pub fn seal(&mut self, frame: &Frame) -> Result<Vec<Vec<u8>>, ChannelError> {
        let bytes = codec::encode(frame)?;
        fragments(&bytes)
            .map(|fragment| self.transport.seal(&fragment).map_err(ChannelError::from))
            .collect()
    }

    /// Open one carrier message. Returns a frame once its last fragment has
    /// arrived, `None` while a frame is still incomplete.
    pub fn open(&mut self, message: &[u8]) -> Result<Option<Frame>, ChannelError> {
        let fragment = self.transport.open(message)?;
        match self.reassembler.push(&fragment)? {
            Some(bytes) => Ok(Some(codec::decode(&bytes)?)),
            None => Ok(None),
        }
    }
}

#[cfg(test)]
mod tests;
