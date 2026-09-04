//! Noise `IK` handshake and transport over `snow`.
//!
//! The initiator (device) knows the responder's (realm's) static key from
//! the bootstrap QR or the signed endpoint list. The responder learns the
//! initiator's static key from the handshake and must check it against a
//! device credential before serving any frame. The first message carries no
//! application payload (ADR-008: `IK` gives it neither forward secrecy nor
//! replay protection).

use snow::params::NoiseParams;
use snow::{Builder, HandshakeState, TransportState};

use crate::PROTOCOL_VERSION;

/// Fixed for V1. Both `snow` and Go's `flynn/noise` implement it.
pub const PROTOCOL_NAME: &str = "Noise_IK_25519_ChaChaPoly_BLAKE2s";

/// Largest Noise message on the wire (Noise spec limit).
pub const MAX_NOISE_MESSAGE: usize = 65_535;
/// Largest payload that fits in one Noise transport message.
pub const MAX_NOISE_PAYLOAD: usize = MAX_NOISE_MESSAGE - 16;

#[derive(Debug, thiserror::Error)]
pub enum NoiseError {
    #[error("noise: {0}")]
    Snow(#[from] snow::Error),
    #[error("noise: payload of {0} bytes exceeds one message")]
    PayloadTooLarge(usize),
    #[error("noise: handshake message carried unexpected payload")]
    UnexpectedHandshakePayload,
}

/// Prologue binding the protocol version and the realm identity, so a
/// handshake completed against the wrong realm or version fails even when
/// the keys match.
pub fn prologue(realm_id: &[u8]) -> Vec<u8> {
    let mut p = format!("arveil/{PROTOCOL_VERSION}/").into_bytes();
    p.extend_from_slice(realm_id);
    p
}

fn params() -> NoiseParams {
    PROTOCOL_NAME.parse().expect("valid Noise protocol name")
}

/// A static X25519 keypair for the Noise channel.
#[derive(Clone)]
pub struct StaticKeypair {
    pub private: Vec<u8>,
    pub public: Vec<u8>,
}

impl StaticKeypair {
    pub fn generate() -> Result<Self, NoiseError> {
        let kp = Builder::new(params()).generate_keypair()?;
        Ok(Self {
            private: kp.private,
            public: kp.public,
        })
    }
}

/// Device side of the handshake.
pub struct Initiator {
    state: HandshakeState,
}

impl Initiator {
    pub fn new(
        local: &StaticKeypair,
        remote_static_public: &[u8],
        prologue: &[u8],
    ) -> Result<Self, NoiseError> {
        let state = Builder::new(params())
            .local_private_key(&local.private)?
            .remote_public_key(remote_static_public)?
            .prologue(prologue)?
            .build_initiator()?;
        Ok(Self { state })
    }

    /// Message 1, with an empty payload by design.
    pub fn write_message_1(&mut self) -> Result<Vec<u8>, NoiseError> {
        let mut buf = vec![0u8; MAX_NOISE_MESSAGE];
        let n = self.state.write_message(&[], &mut buf)?;
        buf.truncate(n);
        Ok(buf)
    }

    /// Message 2 from the responder; on success the channel is established.
    pub fn read_message_2(mut self, message: &[u8]) -> Result<Transport, NoiseError> {
        let mut buf = vec![0u8; MAX_NOISE_MESSAGE];
        let n = self.state.read_message(message, &mut buf)?;
        if n != 0 {
            return Err(NoiseError::UnexpectedHandshakePayload);
        }
        Ok(Transport {
            state: self.state.into_transport_mode()?,
        })
    }
}

/// Realm side of the handshake.
pub struct Responder {
    state: HandshakeState,
}

impl Responder {
    pub fn new(local: &StaticKeypair, prologue: &[u8]) -> Result<Self, NoiseError> {
        let state = Builder::new(params())
            .local_private_key(&local.private)?
            .prologue(prologue)?
            .build_responder()?;
        Ok(Self { state })
    }

    /// Message 1 from the initiator. Returns the initiator's static public
    /// key so the caller can decide whether to answer at all.
    pub fn read_message_1(&mut self, message: &[u8]) -> Result<Vec<u8>, NoiseError> {
        let mut buf = vec![0u8; MAX_NOISE_MESSAGE];
        let n = self.state.read_message(message, &mut buf)?;
        if n != 0 {
            return Err(NoiseError::UnexpectedHandshakePayload);
        }
        Ok(self
            .state
            .get_remote_static()
            .expect("IK message 1 carries the initiator static")
            .to_vec())
    }

    /// Message 2; on success the channel is established.
    pub fn write_message_2(mut self) -> Result<(Vec<u8>, Transport), NoiseError> {
        let mut buf = vec![0u8; MAX_NOISE_MESSAGE];
        let n = self.state.write_message(&[], &mut buf)?;
        buf.truncate(n);
        Ok((
            buf,
            Transport {
                state: self.state.into_transport_mode()?,
            },
        ))
    }
}

/// Established Noise transport. One `seal` produces one wire message.
pub struct Transport {
    state: TransportState,
}

impl Transport {
    pub fn remote_static(&self) -> &[u8] {
        self.state
            .get_remote_static()
            .expect("IK authenticates the remote static")
    }

    pub fn seal(&mut self, payload: &[u8]) -> Result<Vec<u8>, NoiseError> {
        if payload.len() > MAX_NOISE_PAYLOAD {
            return Err(NoiseError::PayloadTooLarge(payload.len()));
        }
        let mut buf = vec![0u8; MAX_NOISE_MESSAGE];
        let n = self.state.write_message(payload, &mut buf)?;
        buf.truncate(n);
        Ok(buf)
    }

    pub fn open(&mut self, message: &[u8]) -> Result<Vec<u8>, NoiseError> {
        if message.len() > MAX_NOISE_MESSAGE {
            return Err(NoiseError::PayloadTooLarge(message.len()));
        }
        let mut buf = vec![0u8; MAX_NOISE_MESSAGE];
        let n = self.state.read_message(message, &mut buf)?;
        buf.truncate(n);
        Ok(buf)
    }
}
