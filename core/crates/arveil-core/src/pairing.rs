//! Device pairing over a live channel (PROTOCOL §8, M3.1).
//!
//! Phase 2 linked a device by copying a signed grant between two screens.
//! That authorizes correctly but says nothing about *who* is on the other
//! screen. Here the two devices run a Noise `IK` handshake through a
//! rendezvous the realm brokers but cannot read, and both display a short
//! authentication string derived from the handshake transcript. The user
//! compares the two numbers; the new device applies the grant only after
//! that comparison. Anything in the middle produces a different number.
//!
//! ```text
//! new device : pair_begin -> arveil-pair:v1:<realm>:<pair_id>:<capability>:<static key>
//! admin      : Noise IK message 1 -> slot a
//! new device : Noise IK message 2 -> slot b        both derive the same SAS
//! admin      : sealed grant       -> slot c
//! user       : compares the two numbers, then confirms on the new device
//! ```
//!
//! The code is a bearer secret for the rendezvous, exactly like a QR code:
//! whoever holds it can answer. That is why the SAS, and not the code, is
//! what authenticates the pairing.

use sha2::{Digest, Sha256};

pub const CODE_PREFIX: &str = "arveil-pair:v1";
/// Slots in the rendezvous, in the order they are written.
pub const SLOT_HANDSHAKE_1: &str = "a";
pub const SLOT_HANDSHAKE_2: &str = "b";
pub const SLOT_GRANT: &str = "c";

#[derive(Debug, thiserror::Error)]
pub enum PairingError {
    #[error("pairing: not an {CODE_PREFIX} code")]
    NotACode,
    #[error("pairing: {0} in the code is not hex")]
    BadField(&'static str),
    #[error("pairing: the code names realm {got}, this device knows {known}")]
    WrongRealm { got: String, known: String },
}

/// What the new device shows and the administration device is given.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PairingCode {
    pub realm_id: Vec<u8>,
    pub pair_id: Vec<u8>,
    pub capability: Vec<u8>,
    pub static_public: Vec<u8>,
}

impl PairingCode {
    pub fn to_string_code(&self) -> String {
        format!(
            "{CODE_PREFIX}:{}:{}:{}:{}",
            hex::encode(&self.realm_id),
            hex::encode(&self.pair_id),
            hex::encode(&self.capability),
            hex::encode(&self.static_public)
        )
    }

    pub fn parse(s: &str) -> Result<Self, PairingError> {
        let parts: Vec<&str> = s.trim().split(':').collect();
        if parts.len() != 6 || parts[0] != "arveil-pair" || parts[1] != "v1" {
            return Err(PairingError::NotACode);
        }
        let field = |i: usize, name: &'static str| {
            hex::decode(parts[i]).map_err(|_| PairingError::BadField(name))
        };
        Ok(Self {
            realm_id: field(2, "realm id")?,
            pair_id: field(3, "pair id")?,
            capability: field(4, "capability")?,
            static_public: field(5, "static key")?,
        })
    }

    /// A code for another realm is refused before any handshake.
    pub fn check_realm(&self, known: &[u8]) -> Result<(), PairingError> {
        if self.realm_id != known {
            return Err(PairingError::WrongRealm {
                got: hex::encode(&self.realm_id),
                known: hex::encode(known),
            });
        }
        Ok(())
    }
}

/// Eight digits in two groups, derived from the handshake transcript.
///
/// It is not a secret and not a password: it only tells the user that the
/// two screens are talking to each other. Twenty-six bits of comparison is
/// what a person will actually read aloud; an attacker gets one attempt per
/// pairing, and the user aborts on a mismatch.
pub fn short_authentication_string(handshake_hash: &[u8]) -> String {
    let mut h = Sha256::new();
    h.update(b"arveil/pair-sas/v1");
    h.update(handshake_hash);
    let d = h.finalize();
    let n = u32::from_be_bytes([d[0], d[1], d[2], d[3]]) % 100_000_000;
    format!("{:04}-{:04}", n / 10_000, n % 10_000)
}

/// The public keys the new device asks the administration device to sign,
/// sent inside the handshake so they are bound to the same transcript the
/// user's number covers.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct PairedDeviceKeys {
    #[serde(with = "serde_bytes")]
    pub device_id: Vec<u8>,
    #[serde(with = "serde_bytes")]
    pub mls_signature_public_key: Vec<u8>,
    #[serde(with = "serde_bytes")]
    pub transport_noise_public_key: Vec<u8>,
    #[serde(with = "serde_bytes")]
    pub envelope_hpke_public_key: Vec<u8>,
}

impl From<&crate::identity::DevicePublicKeys> for PairedDeviceKeys {
    fn from(d: &crate::identity::DevicePublicKeys) -> Self {
        Self {
            device_id: d.device_id.clone(),
            mls_signature_public_key: d.mls_signature_public_key.clone(),
            transport_noise_public_key: d.transport_noise_public_key.clone(),
            envelope_hpke_public_key: d.envelope_hpke_public_key.clone(),
        }
    }
}

impl From<&PairedDeviceKeys> for crate::identity::DevicePublicKeys {
    fn from(p: &PairedDeviceKeys) -> Self {
        Self {
            device_id: p.device_id.clone(),
            mls_signature_public_key: p.mls_signature_public_key.clone(),
            transport_noise_public_key: p.transport_noise_public_key.clone(),
            envelope_hpke_public_key: p.envelope_hpke_public_key.clone(),
        }
    }
}

/// Pairing grant sent through the Noise channel: the same objects Phase 2
/// copied by hand, now delivered over an authenticated transport.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct PairingGrant {
    #[serde(with = "serde_bytes")]
    pub credential: Vec<u8>,
    #[serde(with = "serde_bytes")]
    pub manifest: Vec<u8>,
    #[serde(with = "serde_bytes")]
    pub root_public: Vec<u8>,
}

/// What the new device says in message 1 of a link (ADR-012 §3): the keys
/// it wants signed and how it describes itself. The description is shown on
/// the device that authorizes, never trusted.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct LinkHello {
    pub keys: PairedDeviceKeys,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

/// The longest description a new device may give.
pub const MAX_DESCRIPTION_BYTES: usize = 64;

/// What the device that holds the root answers in the last slot of a link,
/// sealed in the pairing channel: the grant once the person confirmed on its
/// screen, or a refusal, so the new device stops waiting at once.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum LinkAnswer {
    Granted(PairingGrant),
    Declined,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::channel::noise::{Initiator, Responder, StaticKeypair, prologue};

    #[test]
    fn a_code_round_trips_and_is_bound_to_its_realm() {
        let c = PairingCode {
            realm_id: vec![1; 32],
            pair_id: vec![2; 16],
            capability: vec![3; 32],
            static_public: vec![4; 32],
        };
        assert_eq!(PairingCode::parse(&c.to_string_code()).unwrap(), c);
        assert!(c.check_realm(&[1; 32]).is_ok());
        assert!(matches!(
            c.check_realm(&[9; 32]),
            Err(PairingError::WrongRealm { .. })
        ));
        assert!(matches!(
            PairingCode::parse("arveil-route:v1:aa"),
            Err(PairingError::NotACode)
        ));
    }

    /// ADR-012 §3 reverses the roles: the device that holds the root answers
    /// with a one-time key shown in its QR, and the new device speaks first,
    /// stating its keys. Both still show the same number, and someone who
    /// answers with a photograph of the QR shows another one.
    #[test]
    fn a_reversed_link_carries_the_keys_first_and_agrees_on_the_number() {
        let new_device = StaticKeypair::generate().unwrap();
        let one_time = StaticKeypair::generate().unwrap();
        let p = prologue(&[7; 32]);
        let hello = LinkHello {
            keys: PairedDeviceKeys {
                device_id: vec![1; 16],
                mls_signature_public_key: vec![2; 32],
                transport_noise_public_key: new_device.public.clone(),
                envelope_hpke_public_key: vec![3; 32],
            },
            description: Some("Pixel 8 · Android 15".into()),
        };
        let payload = crate::signed::canonical(&hello).unwrap();

        let mut i = Initiator::new(&new_device, &one_time.public, &p).unwrap();
        let msg1 = i.write_message_1_payload(&payload).unwrap();
        let mut r = Responder::new(&one_time, &p).unwrap();
        let (remote, said) = r.read_message_1_payload(&msg1).unwrap();
        assert_eq!(remote, new_device.public);
        let heard: LinkHello = ciborium::from_reader(said.as_slice()).unwrap();
        assert_eq!(heard, hello);
        let (msg2, mut r_transport) = r.write_message_2().unwrap();
        let mut i_transport = i.read_message_2(&msg2).unwrap();
        let sas = short_authentication_string(r_transport.handshake_hash());
        assert_eq!(
            sas,
            short_authentication_string(i_transport.handshake_hash())
        );

        let answer = LinkAnswer::Declined;
        let sealed = r_transport
            .seal(&crate::signed::canonical(&answer).unwrap())
            .unwrap();
        let opened: LinkAnswer =
            ciborium::from_reader(i_transport.open(&sealed).unwrap().as_slice()).unwrap();
        assert_eq!(opened, answer);

        // Someone else answering the same QR is another transcript.
        let thief = StaticKeypair::generate().unwrap();
        let mut i2 = Initiator::new(&thief, &one_time.public, &p).unwrap();
        let msg1b = i2.write_message_1_payload(&payload).unwrap();
        let mut r2 = Responder::new(&one_time, &p).unwrap();
        let (remote2, _) = r2.read_message_1_payload(&msg1b).unwrap();
        assert_ne!(
            remote2, new_device.public,
            "the keys it claims are not its own"
        );
        let (msg2b, r2_transport) = r2.write_message_2().unwrap();
        let other =
            short_authentication_string(i2.read_message_2(&msg2b).unwrap().handshake_hash());
        assert_ne!(other, sas);
        assert_eq!(
            other,
            short_authentication_string(r2_transport.handshake_hash())
        );
    }

    /// Both ends of one handshake show the same number; a third device that
    /// answers instead of the intended one shows a different one.
    #[test]
    fn the_authentication_string_matches_only_the_two_real_ends() {
        let new_device = StaticKeypair::generate().unwrap();
        let admin = StaticKeypair::generate().unwrap();
        let p = prologue(&[7; 32]);

        let mut i = Initiator::new(&admin, &new_device.public, &p).unwrap();
        let msg1 = i.write_message_1().unwrap();
        let mut r = Responder::new(&new_device, &p).unwrap();
        r.read_message_1(&msg1).unwrap();
        let (msg2, r_transport) = r.write_message_2().unwrap();
        let i_transport = i.read_message_2(&msg2).unwrap();

        let sas = short_authentication_string(i_transport.handshake_hash());
        assert_eq!(
            sas,
            short_authentication_string(r_transport.handshake_hash())
        );
        assert_eq!(sas.len(), 9, "four digits, a dash, four digits");

        // A second administration device pairing with the same new device
        // gets its own transcript and therefore its own number.
        let other_admin = StaticKeypair::generate().unwrap();
        let mut i2 = Initiator::new(&other_admin, &new_device.public, &p).unwrap();
        let msg1b = i2.write_message_1().unwrap();
        let mut r2 = Responder::new(&new_device, &p).unwrap();
        r2.read_message_1(&msg1b).unwrap();
        let (msg2b, _) = r2.write_message_2().unwrap();
        let other =
            short_authentication_string(i2.read_message_2(&msg2b).unwrap().handshake_hash());
        assert_ne!(sas, other);
    }
}
