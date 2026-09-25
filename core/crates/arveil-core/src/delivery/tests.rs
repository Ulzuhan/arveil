//! I-04 and I-05 under crash injection (issue #14), in-process: two MLS
//! peers, sealed envelopes, and units of work that fail at chosen points.

use mls_rs::client_builder::MlsConfig;
use mls_rs::group::{Group, ReceivedMessage};

use super::*;
use crate::envelope::{self, EnvelopeContext, KIND_MLS};
use crate::identity::DeviceKeys;
use crate::mls::{Engine, MlsIdentity, open as open_engine};

struct Peer<C: MlsConfig> {
    conn: SharedConn,
    engine: Engine<C>,
    delivery: Delivery,
    hpke: crate::channel::StaticKeypair,
    mailbox: Vec<u8>,
}

fn peer(name: &str) -> Peer<impl MlsConfig> {
    let conn = SharedConn::open_in_memory().unwrap();
    let engine = open_engine(conn.clone(), MlsIdentity::generate(name).unwrap());
    let delivery = Delivery::open(conn.clone()).unwrap();
    let keys = DeviceKeys::generate(vec![0; 32]).unwrap();
    Peer {
        conn,
        engine,
        delivery,
        hpke: keys.envelope_hpke,
        mailbox: format!("mailbox-{name}").into_bytes(),
    }
}

#[derive(Debug)]
struct Crash;

impl From<rusqlite::Error> for Crash {
    fn from(_: rusqlite::Error) -> Self {
        Crash
    }
}

/// alice creates a group with bob; both persist their groups.
fn setup<A: MlsConfig, B: MlsConfig>(alice: &Peer<A>, bob: &Peer<B>) -> (Group<A>, Group<B>) {
    let mut g_alice = alice.engine.create_group().unwrap();
    let commit = g_alice
        .commit_builder()
        .add_member(bob.engine.key_package().unwrap())
        .unwrap()
        .build()
        .unwrap();
    g_alice.apply_pending_commit().unwrap();
    g_alice.write_to_storage().unwrap();
    let mut g_bob = bob.engine.join(&commit.welcome_messages[0]).unwrap();
    g_bob.write_to_storage().unwrap();
    (g_alice, g_bob)
}

/// The send unit: MLS encrypt + persist + event + outbox, all or nothing.
fn send_unit<A: MlsConfig>(
    alice: &Peer<A>,
    group: &mut Group<A>,
    recipient_hpke_public: &[u8],
    recipient_mailbox: &[u8],
    delivery_id: &[u8],
    text: &[u8],
    crash_after_enqueue: bool,
) -> Result<(), Crash> {
    alice.conn.unit_of_work(|_| {
        let msg = group
            .encrypt_application_message(text, Default::default())
            .map_err(|_| Crash)?;
        group.write_to_storage().map_err(|_| Crash)?;
        alice
            .delivery
            .record_event(group.group_id(), delivery_id, "message", text)?;
        let ctx = EnvelopeContext::new(b"realm", recipient_mailbox, delivery_id);
        let sealed = envelope::seal(
            recipient_hpke_public,
            &ctx,
            KIND_MLS,
            &msg.to_bytes().map_err(|_| Crash)?,
        )
        .map_err(|_| Crash)?;
        alice.delivery.enqueue(
            recipient_mailbox,
            delivery_id,
            Some(delivery_id),
            &sealed.enc,
            &sealed.ciphertext,
        )?;
        if crash_after_enqueue {
            return Err(Crash);
        }
        Ok(())
    })
}

/// The receive unit: dedup + open + MLS process + persist + event, then ACK
/// outside. Returns the decrypted text, or `None` for a duplicate.
fn receive_unit<B: MlsConfig>(
    bob: &Peer<B>,
    group: &mut Group<B>,
    seq: i64,
    row: &OutboxRow,
    crash_before_commit: bool,
) -> Result<Option<Vec<u8>>, Crash> {
    bob.conn.unit_of_work(|_| {
        if !bob
            .delivery
            .record_incoming(&row.mailbox_id, &row.delivery_id, seq)?
        {
            return Ok(None);
        }
        let ctx = EnvelopeContext::new(b"realm", &row.mailbox_id, &row.delivery_id);
        let inner = envelope::open(
            &bob.hpke.private,
            &ctx,
            &envelope::Sealed {
                enc: row.hpke_enc.clone(),
                ciphertext: row.ciphertext.clone(),
            },
        )
        .map_err(|_| Crash)?;
        let msg = mls_rs::MlsMessage::from_bytes(&inner.payload).map_err(|_| Crash)?;
        let text = match group.process_incoming_message(msg).map_err(|_| Crash)? {
            ReceivedMessage::ApplicationMessage(m) => m.data().to_vec(),
            _ => return Err(Crash),
        };
        group.write_to_storage().map_err(|_| Crash)?;
        bob.delivery
            .record_event(group.group_id(), &row.delivery_id, "message", &text)?;
        if crash_before_commit {
            return Err(Crash);
        }
        Ok(Some(text))
    })
}

#[test]
fn i04_send_unit_is_all_or_nothing_and_retransmits_stored_bytes() {
    let alice = peer("alice");
    let bob = peer("bob");
    let (mut g_alice, mut g_bob) = setup(&alice, &bob);
    let group_id = g_alice.group_id().to_vec();

    // Crash after everything was written but before commit: no trace.
    let r = send_unit(
        &alice,
        &mut g_alice,
        &bob.hpke.public,
        &bob.mailbox,
        b"d1",
        b"first",
        true,
    );
    assert!(r.is_err());
    assert!(alice.delivery.pending().unwrap().is_empty());
    assert_eq!(alice.delivery.event_count().unwrap(), 0);
    // The in-memory handle advanced; the persisted state did not. The app
    // must reload the group before retrying: that is the contract.
    let mut g_alice = alice.engine.load_group(&group_id).unwrap();

    // Retry succeeds: exactly one outbox row with the bytes to send.
    send_unit(
        &alice,
        &mut g_alice,
        &bob.hpke.public,
        &bob.mailbox,
        b"d1",
        b"first",
        false,
    )
    .unwrap();
    let pending = alice.delivery.pending().unwrap();
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].event_id.as_deref(), Some(b"d1".as_slice()));
    assert_eq!(alice.delivery.event_count().unwrap(), 1);

    // Retransmission reuses the stored bytes: identical across attempts.
    alice.delivery.mark_attempt(pending[0].id).unwrap();
    let again = alice.delivery.pending().unwrap();
    assert_eq!(again[0].ciphertext, pending[0].ciphertext);
    assert_eq!(again[0].hpke_enc, pending[0].hpke_enc);
    assert_eq!(again[0].attempts, 1);

    // The receiver decrypts the stored bytes exactly once; a duplicate
    // delivery is dropped before MLS sees it.
    let text = receive_unit(&bob, &mut g_bob, 1, &pending[0], false).unwrap();
    assert_eq!(text, Some(b"first".to_vec()));
    let dup = receive_unit(&bob, &mut g_bob, 1, &pending[0], false).unwrap();
    assert_eq!(dup, None, "duplicate delivery produces no second event");
    assert_eq!(bob.delivery.event_count().unwrap(), 1);

    // Relay acceptance is recorded after the fact, idempotently.
    alice
        .delivery
        .mark_accepted(pending[0].id, Some(2_000))
        .unwrap();
    alice.delivery.mark_accepted(pending[0].id, None).unwrap();
    assert!(alice.delivery.pending().unwrap().is_empty());
    // Truthful states: accepted with the relay's expiry, then expired/unknown.
    let states = alice.delivery.states_for_event(b"d1", 1_000).unwrap();
    assert_eq!(states[0].1, "accepted (relay keeps it until 2000)");
    let states = alice.delivery.states_for_event(b"d1", 3_000).unwrap();
    assert_eq!(states[0].1, "expired/unknown");
}

#[test]
fn i05_receive_unit_commits_before_ack_and_survives_a_crash() {
    let alice = peer("alice");
    let bob = peer("bob");
    let (mut g_alice, mut g_bob) = setup(&alice, &bob);
    let bob_group_id = g_bob.group_id().to_vec();

    send_unit(
        &alice,
        &mut g_alice,
        &bob.hpke.public,
        &bob.mailbox,
        b"d2",
        b"second",
        false,
    )
    .unwrap();
    let row = alice.delivery.pending().unwrap().remove(0);

    // Crash before commit: nothing recorded, nothing to ACK, no event.
    assert!(receive_unit(&bob, &mut g_bob, 1, &row, true).is_err());
    assert!(bob.delivery.unacked(&row.mailbox_id).unwrap().is_empty());
    assert_eq!(bob.delivery.event_count().unwrap(), 0);

    // Reload from storage (the in-memory group consumed the message) and
    // process again: exactly one event, and the delivery awaits ACK.
    let mut g_bob = bob.engine.load_group(&bob_group_id).unwrap();
    let text = receive_unit(&bob, &mut g_bob, 1, &row, false).unwrap();
    assert_eq!(text, Some(b"second".to_vec()));
    assert_eq!(bob.delivery.event_count().unwrap(), 1);
    let unacked = bob.delivery.unacked(&row.mailbox_id).unwrap();
    assert_eq!(unacked, vec![row.delivery_id.clone()]);

    // ACK after the commit; a redelivery after ACK is still a duplicate.
    bob.delivery.mark_acked(&row.mailbox_id, &unacked).unwrap();
    assert!(bob.delivery.unacked(&row.mailbox_id).unwrap().is_empty());
    assert_eq!(
        receive_unit(&bob, &mut g_bob, 1, &row, false).unwrap(),
        None
    );
    assert_eq!(bob.delivery.event_count().unwrap(), 1);

    // Cursor bookkeeping.
    assert_eq!(bob.delivery.cursor(&row.mailbox_id).unwrap(), 0);
    bob.delivery.set_cursor(&row.mailbox_id, 1).unwrap();
    assert_eq!(bob.delivery.cursor(&row.mailbox_id).unwrap(), 1);
    bob.delivery.set_cursor(&row.mailbox_id, 0).unwrap();
    assert_eq!(
        bob.delivery.cursor(&row.mailbox_id).unwrap(),
        1,
        "a stale sync cannot move the cursor backwards"
    );
}

#[test]
fn events_keep_their_sender_and_time() {
    let conn = SharedConn::open_in_memory().unwrap();
    let delivery = Delivery::open(conn).unwrap();
    let group = [1u8; 32];
    delivery
        .record_event(&group, b"legacy", "received", b"sin remitente")
        .unwrap();
    let known = EventSender {
        device_id: Some(vec![2; 16]),
        identity_id: Some(vec![3; 32]),
    };
    delivery
        .record_event_by(&group, b"known", "received", b"hola", Some(&known))
        .unwrap();
    let unknown_identity = EventSender {
        device_id: Some(vec![4; 16]),
        identity_id: None,
    };
    delivery
        .record_event_by(
            &group,
            b"device-only",
            "received",
            b"dispositivo sin identidad",
            Some(&unknown_identity),
        )
        .unwrap();

    let page = delivery.events_page(&group, None, 10).unwrap();
    let by_id = |id: &[u8]| page.iter().find(|e| e.event_id == id).unwrap();
    let legacy = by_id(b"legacy");
    assert_eq!(
        (&legacy.sender_device, &legacy.sender_identity),
        (&None, &None)
    );
    let recorded = by_id(b"known");
    assert_eq!(recorded.sender_device.as_deref(), Some(&[2u8; 16][..]));
    assert_eq!(recorded.sender_identity.as_deref(), Some(&[3u8; 32][..]));
    let partial = by_id(b"device-only");
    assert_eq!(partial.sender_device.as_deref(), Some(&[4u8; 16][..]));
    assert_eq!(partial.sender_identity, None);
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;
    assert!(page.iter().all(|e| (now - e.created_at).abs() < 60));

    // Changing a transfer's kind keeps who wrote it.
    delivery
        .update_event(b"known", "file-unavailable", &[])
        .unwrap();
    let page = delivery.events_page(&group, None, 10).unwrap();
    let updated = page.iter().find(|e| e.event_id == b"known").unwrap();
    assert_eq!(updated.sender_identity.as_deref(), Some(&[3u8; 32][..]));
}

#[test]
fn read_markers_only_move_forward_and_count_what_others_wrote() {
    let conn = SharedConn::open_in_memory().unwrap();
    let delivery = Delivery::open(conn).unwrap();
    let group = [1u8; 32];
    let me = vec![9u8; 32];
    let other = EventSender {
        device_id: Some(vec![2; 16]),
        identity_id: Some(vec![3; 32]),
    };
    let own_device = EventSender {
        device_id: Some(vec![4; 16]),
        identity_id: Some(me.clone()),
    };
    let cursor_of = |d: &Delivery, id: &[u8]| {
        d.events_page(&group, None, 50)
            .unwrap()
            .into_iter()
            .find(|e| e.event_id == id)
            .unwrap()
            .cursor
    };

    // Nothing read yet, and nothing to mark in an empty conversation.
    assert_eq!(delivery.mark_read(&group, 10).unwrap(), 0);
    assert_eq!(delivery.unread_count(&group, Some(&me)).unwrap(), 0);

    delivery
        .record_event_by(&group, b"in-1", "received", b"a", Some(&other))
        .unwrap();
    delivery
        .record_event_by(&group, b"mine", "sent", b"b", None)
        .unwrap();
    delivery
        .record_event_by(
            &group,
            b"from-my-phone",
            "received",
            b"c",
            Some(&own_device),
        )
        .unwrap();
    delivery
        .record_event(&group, b"legacy-in", "received", b"d")
        .unwrap();
    // Another identity's message and an old row nobody can attribute; what
    // this identity wrote, from any device, never counts.
    assert_eq!(delivery.unread_count(&group, Some(&me)).unwrap(), 2);

    let first = cursor_of(&delivery, b"in-1");
    assert_eq!(delivery.mark_read(&group, first).unwrap(), first);
    assert_eq!(delivery.unread_count(&group, Some(&me)).unwrap(), 1);

    // A screen that marks past the end cannot hide what arrives later.
    let newest = cursor_of(&delivery, b"legacy-in");
    assert_eq!(delivery.mark_read(&group, i64::MAX).unwrap(), newest);
    delivery
        .record_event_by(&group, b"in-2", "received", b"e", Some(&other))
        .unwrap();
    assert_eq!(delivery.unread_count(&group, Some(&me)).unwrap(), 1);

    // A stale screen marking an older cursor does not move it back.
    assert_eq!(delivery.mark_read(&group, first).unwrap(), newest);
    assert_eq!(delivery.mark_read(&group, 0).unwrap(), newest);
    assert_eq!(delivery.unread_count(&group, Some(&me)).unwrap(), 1);

    // Markers are per conversation.
    assert_eq!(delivery.read_cursor(&[2u8; 32]).unwrap(), 0);
}

#[test]
fn notices_are_never_unread() {
    let conn = SharedConn::open_in_memory().unwrap();
    let delivery = Delivery::open(conn).unwrap();
    let group = [1u8; 32];
    let them = EventSender {
        device_id: None,
        identity_id: Some(vec![3; 32]),
    };
    delivery
        .record_event_by(&group, b"notice", DEVICES_CHANGED, b"", Some(&them))
        .unwrap();
    assert_eq!(delivery.unread_count(&group, Some(&[9u8; 32])).unwrap(), 0);
    // One notice per conversation and manifest: the identifier differs by
    // group and by sequence, and is stable.
    let id = |sequence, group: &[u8]| notice_event_id(&[3u8; 32], sequence, group);
    assert_eq!(id(2, &group), id(2, &group));
    assert_ne!(id(2, &group), id(3, &group));
    assert_ne!(id(2, &group), id(2, &[2u8; 32]));
}
