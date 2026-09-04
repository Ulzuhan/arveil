//! M0.2 acceptance (issues #2 to #6) at the channel layer, carrier-free.

use proptest::prelude::*;

use super::codec::{Frame, MAX_FRAME_BYTES, Payload, decode, encode};
use super::fragment::{FRAGMENT_DATA, Reassembler, fragments};
use super::noise::MAX_NOISE_MESSAGE;
use super::*;

fn realm() -> (StaticKeypair, Vec<u8>) {
    (StaticKeypair::generate().unwrap(), prologue(b"realm-test"))
}

/// Full handshake; returns (device channel, realm channel, device static public).
fn establish(realm_key: &StaticKeypair, prologue: &[u8]) -> (Channel, Channel, Vec<u8>) {
    let device = StaticKeypair::generate().unwrap();
    let mut init = Initiator::new(&device, &realm_key.public, prologue).unwrap();
    let m1 = init.write_message_1().unwrap();

    let mut resp = Responder::new(realm_key, prologue).unwrap();
    let seen = resp.read_message_1(&m1).unwrap();
    assert_eq!(seen, device.public, "responder learns the device static");
    let (m2, realm_transport) = resp.write_message_2().unwrap();

    let device_transport = init.read_message_2(&m2).unwrap();
    (
        Channel::new(device_transport),
        Channel::new(realm_transport),
        device.public,
    )
}

#[test]
fn handshake_then_frames_both_ways() {
    let (key, pro) = realm();
    let (mut dev, mut rlm, dev_pub) = establish(&key, &pro);
    assert_eq!(rlm.remote_static(), dev_pub);
    assert_eq!(dev.remote_static(), key.public);

    let req = Frame {
        id: 7,
        payload: Payload::EndpointListGet,
    };
    let msgs = dev.seal(&req).unwrap();
    assert_eq!(msgs.len(), 1);
    assert_eq!(rlm.open(&msgs[0]).unwrap(), Some(req));

    let reply = Frame {
        id: 7,
        payload: Payload::EndpointList {
            signed: vec![1, 2, 3],
        },
    };
    let msgs = rlm.seal(&reply).unwrap();
    assert_eq!(dev.open(&msgs[0]).unwrap(), Some(reply));
}

/// #2: a device holding the wrong realm key never gets past message 1.
#[test]
fn wrong_realm_static_fails_before_any_frame() {
    let (real_key, pro) = realm();
    let (impostor, _) = realm();
    let device = StaticKeypair::generate().unwrap();

    // Device believes the impostor's key is the realm's.
    let mut init = Initiator::new(&device, &impostor.public, &pro).unwrap();
    let m1 = init.write_message_1().unwrap();
    let mut resp = Responder::new(&real_key, &pro).unwrap();
    assert!(
        resp.read_message_1(&m1).is_err(),
        "the real realm cannot even read message 1: no frame is ever processed"
    );

    // Symmetric: right key, wrong prologue (other realm id or version).
    let mut init = Initiator::new(&device, &real_key.public, &prologue(b"other")).unwrap();
    let m1 = init.write_message_1().unwrap();
    let mut resp = Responder::new(&real_key, &pro).unwrap();
    assert!(resp.read_message_1(&m1).is_err());
}

/// #3: replaying message 1 yields a responder session the replayer cannot
/// drive: it cannot open message 2 and cannot forge a transport message.
#[test]
fn replayed_first_message_has_no_effect() {
    let (key, pro) = realm();
    let device = StaticKeypair::generate().unwrap();
    let mut init = Initiator::new(&device, &key.public, &pro).unwrap();
    let m1 = init.write_message_1().unwrap();

    // Legitimate session.
    let mut resp = Responder::new(&key, &pro).unwrap();
    resp.read_message_1(&m1).unwrap();
    let (m2, _realm_transport) = resp.write_message_2().unwrap();
    let _device_transport = init.read_message_2(&m2).unwrap();

    // Replay of m1 against a fresh responder.
    let mut resp2 = Responder::new(&key, &pro).unwrap();
    let claimed = resp2.read_message_1(&m1).unwrap();
    assert_eq!(
        claimed, device.public,
        "IK cannot detect the replay by itself"
    );
    let (m2_replay, mut realm_transport2) = resp2.write_message_2().unwrap();

    // The replayer holds m1 and m2_replay but not the device's ephemeral:
    // a second initiator with the same static cannot open m2_replay.
    let mut other_init = Initiator::new(&device, &key.public, &pro).unwrap();
    let _ = other_init.write_message_1().unwrap();
    assert!(other_init.read_message_2(&m2_replay).is_err());

    // And anything the replayer sends as "transport" fails to open, so the
    // responder processes no frame from the replayed session.
    let forged = vec![0u8; 64];
    assert!(realm_transport2.open(&forged).is_err());
    assert!(realm_transport2.open(&m1).is_err());
}

/// #4: frames above one Noise payload fragment and reassemble.
#[test]
fn large_frame_fragments_and_reassembles() {
    let (key, pro) = realm();
    let (mut dev, mut rlm, _) = establish(&key, &pro);

    let big = Frame {
        id: 1,
        payload: Payload::EndpointList {
            signed: vec![0xAB; 200_000],
        },
    };
    let msgs = dev.seal(&big).unwrap();
    assert!(
        msgs.len() >= 4,
        "200 KiB needs several fragments, got {}",
        msgs.len()
    );
    assert!(msgs.iter().all(|m| m.len() <= MAX_NOISE_MESSAGE));

    let mut got = None;
    for (i, m) in msgs.iter().enumerate() {
        let r = rlm.open(m).unwrap();
        if i + 1 < msgs.len() {
            assert!(
                r.is_none(),
                "frame must not be delivered before its last fragment"
            );
        } else {
            got = r;
        }
    }
    assert_eq!(got, Some(big));
}

/// #4: the reassembler refuses to grow past the frame limit and resets.
#[test]
fn oversized_reassembly_is_refused_within_bounds() {
    let mut r = Reassembler::new(3 * FRAGMENT_DATA);
    let chunk = vec![0u8; FRAGMENT_DATA];
    let mut frag = vec![0u8];
    frag.extend_from_slice(&chunk);
    assert!(r.push(&frag).unwrap().is_none());
    assert!(r.push(&frag).unwrap().is_none());
    assert!(r.push(&frag).unwrap().is_none());
    assert!(r.push(&frag).is_err(), "fourth fragment exceeds the limit");
    assert!(!r.is_mid_frame(), "buffer is dropped after the violation");
}

#[test]
fn encoded_frame_over_limit_is_refused() {
    let too_big = Frame {
        id: 0,
        payload: Payload::EndpointList {
            signed: vec![0; MAX_FRAME_BYTES + 1],
        },
    };
    assert!(encode(&too_big).is_err());
}

#[test]
fn fragments_of_empty_input_is_one_last_fragment() {
    let f: Vec<_> = fragments(&[]).collect();
    assert_eq!(f, vec![vec![super::fragment::FLAG_LAST]]);
}

fn arb_payload() -> impl Strategy<Value = Payload> {
    prop_oneof![
        Just(Payload::Ping),
        Just(Payload::Pong),
        Just(Payload::EndpointListGet),
        proptest::collection::vec(any::<u8>(), 0..4096)
            .prop_map(|signed| Payload::EndpointList { signed }),
        (any::<u16>(), ".{0,64}").prop_map(|(code, message)| Payload::Error { code, message }),
    ]
}

proptest! {
    /// #6: any frame round-trips through encode/decode.
    #[test]
    fn frame_roundtrip(id in any::<u64>(), payload in arb_payload()) {
        let frame = Frame { id, payload };
        let bytes = encode(&frame).unwrap();
        prop_assert_eq!(decode(&bytes).unwrap(), frame);
    }

    /// #6 / I-10: arbitrary bytes never panic the decoder or the reassembler.
    #[test]
    fn garbage_never_panics(bytes in proptest::collection::vec(any::<u8>(), 0..2048)) {
        let _ = decode(&bytes);
        let mut r = Reassembler::new(MAX_FRAME_BYTES);
        let _ = r.push(&bytes);
    }

    /// Fragmentation is lossless for any size up to a few fragments.
    #[test]
    fn fragment_roundtrip(bytes in proptest::collection::vec(any::<u8>(), 0..(3 * FRAGMENT_DATA + 5))) {
        let mut r = Reassembler::new(MAX_FRAME_BYTES);
        let mut out = None;
        for f in fragments(&bytes) {
            out = r.push(&f).unwrap();
        }
        prop_assert_eq!(out, Some(bytes));
    }
}
