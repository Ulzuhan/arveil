//! M0.5 integration tests (issue #18): 1:1 and 3-member groups, Add and
//! Remove, application messages, policy enforcement, transactional units.

use mls_rs::group::ReceivedMessage;
use mls_rs::{MlsMessage, client_builder::MlsConfig, group::Group};

use super::*;
use crate::storage::SharedConn;

struct Peer<C: MlsConfig> {
    conn: SharedConn,
    identity: MlsIdentity,
    engine: Engine<C>,
}

fn peer(name: &str) -> Peer<impl MlsConfig> {
    let conn = SharedConn::open_in_memory().unwrap();
    let identity = MlsIdentity::generate(name).unwrap();
    let engine = open(conn.clone(), identity.clone());
    Peer {
        conn,
        identity,
        engine,
    }
}

fn decrypt<C: MlsConfig>(group: &mut Group<C>, msg: MlsMessage) -> Vec<u8> {
    match group.process_incoming_message(msg).unwrap() {
        ReceivedMessage::ApplicationMessage(m) => m.data().to_vec(),
        other => panic!("expected application message, got {other:?}"),
    }
}

#[test]
fn one_to_one_group_exchanges_messages_both_ways() {
    let alice = peer("alice");
    let bob = peer("bob");

    let mut g_alice = alice.engine.create_group().unwrap();
    let commit = g_alice
        .commit_builder()
        .add_member(bob.engine.key_package().unwrap())
        .unwrap()
        .build()
        .unwrap();
    g_alice.apply_pending_commit().unwrap();
    let mut g_bob = bob.engine.join(&commit.welcome_messages[0]).unwrap();

    let m = g_alice
        .encrypt_application_message(b"hi bob", Default::default())
        .unwrap();
    assert_eq!(decrypt(&mut g_bob, m), b"hi bob");

    let m = g_bob
        .encrypt_application_message(b"hi alice", Default::default())
        .unwrap();
    assert_eq!(decrypt(&mut g_alice, m), b"hi alice");
    assert_eq!(g_alice.current_epoch(), 1);
    assert_eq!(g_bob.current_epoch(), 1);
}

#[test]
fn three_member_group_add_then_remove() {
    let alice = peer("alice");
    let bob = peer("bob");
    let carol = peer("carol");

    let mut g_alice = alice.engine.create_group().unwrap();
    let commit = g_alice
        .commit_builder()
        .add_member(bob.engine.key_package().unwrap())
        .unwrap()
        .add_member(carol.engine.key_package().unwrap())
        .unwrap()
        .build()
        .unwrap();
    g_alice.apply_pending_commit().unwrap();
    assert_eq!(
        commit.welcome_messages.len(),
        1,
        "one Welcome covers both joiners"
    );
    let mut g_bob = bob.engine.join(&commit.welcome_messages[0]).unwrap();
    let mut g_carol = carol.engine.join(&commit.welcome_messages[0]).unwrap();
    assert_eq!(g_alice.roster().members().len(), 3);

    let m = g_alice
        .encrypt_application_message(b"to all", Default::default())
        .unwrap();
    assert_eq!(decrypt(&mut g_bob, m.clone()), b"to all");
    assert_eq!(decrypt(&mut g_carol, m), b"to all");

    // Remove carol (leaf 2). Alice is the only authorized committer.
    let carol_index = g_carol.current_member_index();
    let commit = g_alice
        .commit_builder()
        .remove_member(carol_index)
        .unwrap()
        .build()
        .unwrap();
    g_alice.apply_pending_commit().unwrap();
    g_bob
        .process_incoming_message(commit.commit_message.clone())
        .unwrap();
    assert_eq!(g_alice.current_epoch(), 2);
    assert_eq!(g_bob.current_epoch(), 2);
    assert_eq!(g_alice.roster().members().len(), 2);

    // Carol learns she was removed; a message from the new epoch is not for her.
    g_carol
        .process_incoming_message(commit.commit_message)
        .unwrap();
    let m = g_alice
        .encrypt_application_message(b"after removal", Default::default())
        .unwrap();
    assert_eq!(decrypt(&mut g_bob, m.clone()), b"after removal");
    assert!(
        g_carol.process_incoming_message(m).is_err(),
        "a removed member cannot read the new epoch (I-06)"
    );
}

#[test]
fn unauthorized_commit_is_refused_by_every_member() {
    let alice = peer("alice");
    let bob = peer("bob");
    let carol = peer("carol");

    let mut g_alice = alice.engine.create_group().unwrap();
    let commit = g_alice
        .commit_builder()
        .add_member(bob.engine.key_package().unwrap())
        .unwrap()
        .add_member(carol.engine.key_package().unwrap())
        .unwrap()
        .build()
        .unwrap();
    g_alice.apply_pending_commit().unwrap();
    let mut g_bob = bob.engine.join(&commit.welcome_messages[0]).unwrap();
    let mut g_carol = carol.engine.join(&commit.welcome_messages[0]).unwrap();

    // Bob's own client refuses to produce the commit (Send direction).
    let err = g_bob.commit_builder().build().unwrap_err().to_string();
    assert!(
        err.contains("only the lowest active leaf may commit"),
        "got: {err}"
    );

    // A forged commit from bob, built by a client without rules, is refused
    // by alice and carol (Receive direction) with the epoch unchanged.
    let rogue = rogue_commit_from(&bob, &commit.welcome_messages[0]);
    for (name, g) in [("alice", &mut g_alice), ("carol", &mut g_carol)] {
        let before = g.current_epoch();
        let err = g
            .process_incoming_message(rogue.clone())
            .unwrap_err()
            .to_string();
        assert!(
            err.contains("only the lowest active leaf may commit"),
            "{name}: {err}"
        );
        assert_eq!(g.current_epoch(), before, "{name}: epoch must not move");
    }
}

/// Mark a device id revoked in a peer's store, the way an accepted manifest
/// does, so its policy sees the revocation (M2.4).
fn mark_revoked<C: MlsConfig>(p: &Peer<C>, device: &[u8]) {
    p.conn
        .lock()
        .execute_batch(crate::client::CLIENT_SCHEMA)
        .unwrap();
    p.conn
        .lock()
        .execute(
            "INSERT INTO identity_devices (device_id, credential_hash, revoked) VALUES (?1, X'00', 1)",
            [device],
        )
        .unwrap();
}

#[test]
fn the_successor_removes_a_revoked_committer_and_everyone_accepts() {
    let alice = peer("alice");
    let bob = peer("bob");
    let carol = peer("carol");

    let mut g_alice = alice.engine.create_group().unwrap();
    let commit = g_alice
        .commit_builder()
        .add_member(bob.engine.key_package().unwrap())
        .unwrap()
        .add_member(carol.engine.key_package().unwrap())
        .unwrap()
        .build()
        .unwrap();
    g_alice.apply_pending_commit().unwrap();
    let mut g_bob = bob.engine.join(&commit.welcome_messages[0]).unwrap();
    let mut g_carol = carol.engine.join(&commit.welcome_messages[0]).unwrap();

    // Alice (leaf 0) is revoked. Bob and carol learn it from a manifest.
    for p in [&bob.conn, &carol.conn] {
        p.lock()
            .execute_batch(crate::client::CLIENT_SCHEMA)
            .unwrap();
        p.lock()
            .execute(
                "INSERT INTO identity_devices (device_id, credential_hash, revoked) VALUES (?1, X'00', 1)",
                [b"alice".as_slice()],
            )
            .unwrap();
    }

    // Bob, the lowest leaf that is not revoked, may commit only if the same
    // commit removes alice.
    let err = g_bob.commit_builder().build().unwrap_err().to_string();
    assert!(
        err.contains("must also remove the revoked leaf 0"),
        "got: {err}"
    );

    let removal = g_bob
        .commit_builder()
        .remove_member(0)
        .unwrap()
        .build()
        .unwrap();
    g_bob.apply_pending_commit().unwrap();
    match g_carol
        .process_incoming_message(removal.commit_message.clone())
        .unwrap()
    {
        ReceivedMessage::Commit(c) => assert_eq!(c.committer, 1),
        other => panic!("expected a commit, got {other:?}"),
    }
    assert_eq!(g_bob.current_epoch(), g_carol.current_epoch());
    assert_eq!(g_bob.roster().members().len(), 2);

    // Carol (leaf 2) is still not the committer while bob holds leaf 1.
    let err = g_carol.commit_builder().build().unwrap_err().to_string();
    assert!(
        err.contains("only the lowest active leaf may commit"),
        "got: {err}"
    );

    // And a device that nobody revoked cannot be displaced by removing it.
    mark_revoked(&carol, b"nobody");
    let err = g_carol
        .commit_builder()
        .remove_member(1)
        .unwrap()
        .build()
        .unwrap_err()
        .to_string();
    assert!(
        err.contains("only the lowest active leaf may commit"),
        "got: {err}"
    );
}

/// Build a commit from bob's identity using a client with *default* rules,
/// joined from the same Welcome and sharing bob's key package table so the
/// Welcome decrypts. Simulates a dishonest or buggy client.
fn rogue_commit_from<C: MlsConfig>(bob: &Peer<C>, welcome: &MlsMessage) -> MlsMessage {
    use mls_rs::Client;
    use mls_rs::identity::basic::BasicIdentityProvider;
    use mls_rs_crypto_rustcrypto::RustCryptoProvider;

    let client = Client::builder()
        .identity_provider(BasicIdentityProvider)
        .crypto_provider(RustCryptoProvider::default())
        .key_package_repo(store::SqliteKeyPackageStore::new(bob.conn.clone()))
        .group_state_storage(store::SqliteGroupStore::new(bob.conn.clone()))
        .psk_store(store::SqlitePskStore::new(bob.conn.clone()))
        .extension_type(policy::GROUP_POLICY_EXTENSION_TYPE)
        .signing_identity(
            bob.identity.signing_identity.clone(),
            bob.identity.secret.clone(),
            CIPHERSUITE,
        )
        .build();
    let (mut g, _) = client.join_group(None, welcome, None).unwrap();
    g.commit_builder().build().unwrap().commit_message
}

#[test]
fn group_without_policy_fails_closed() {
    let alice = peer("alice");
    let bob = peer("bob");
    let mut g = alice.engine.create_group_without_policy().unwrap();
    let err = g
        .commit_builder()
        .add_member(bob.engine.key_package().unwrap())
        .unwrap()
        .build()
        .unwrap_err()
        .to_string();
    assert!(err.contains("no Arveil policy extension"), "got: {err}");
}

#[test]
fn group_state_and_outbox_share_the_unit_of_work() {
    let alice = peer("alice");
    let delivery = crate::delivery::Delivery::open(alice.conn.clone()).unwrap();
    let mut g = alice.engine.create_group().unwrap();
    let id = g.group_id().to_vec();

    let failed: Result<(), rusqlite::Error> = alice.conn.unit_of_work(|_| {
        delivery.enqueue(b"mailbox", b"d1", None, b"enc", b"ct")?;
        g.write_to_storage().unwrap();
        Err(rusqlite::Error::InvalidQuery)
    });
    assert!(failed.is_err());
    assert_eq!(alice.conn.count("outbox").unwrap(), 0);
    assert!(alice.engine.load_group(&id).is_err());

    alice
        .conn
        .unit_of_work(|_| {
            delivery.enqueue(b"mailbox", b"d1", None, b"enc", b"ct")?;
            g.write_to_storage().unwrap();
            Ok::<_, rusqlite::Error>(())
        })
        .unwrap();
    assert_eq!(alice.conn.count("outbox").unwrap(), 1);
    assert_eq!(alice.engine.load_group(&id).unwrap().current_epoch(), 0);
}
