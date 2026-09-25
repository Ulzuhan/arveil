//! Who wrote each event and when, from the MLS leaf that sent it to the
//! page a screen reads. Three devices in one real MLS group, in-process:
//! this profile, another device of the same identity, and another identity.

use super::*;

fn peer_of(identity: Vec<u8>, device: &StoredDevice, root_public: &[u8]) -> Peer {
    Peer {
        identity,
        device_id: device.keys.device_id.to_vec(),
        credential_hash: device.credential_hash.clone(),
        root_public: root_public.to_vec(),
        mailbox: None,
        write_cap: None,
        hpke: None,
        revoked: false,
    }
}

fn text(event: &str) -> Vec<u8> {
    encode_event("text", event.as_bytes()).unwrap()
}

#[test]
fn received_messages_name_their_sender_and_keep_their_time() {
    let path = std::env::temp_dir().join(format!(
        "arveil-history-{}",
        hex::encode(random_delivery_id().unwrap())
    ));
    let config = ProfileConfig::unencrypted(&path);
    let client = open_client(&config).unwrap();
    let root = client.identity_new().unwrap();
    let (me, _) = client.device_new(onboarding::now()).unwrap();
    client
        .realm_save(&[7; 32], &root.public(), &[8; 32], "ws://127.0.0.1:9")
        .unwrap();
    client.realm_mark_enrolled(&[7; 32]).unwrap();
    client
        .mailbox_save(&OwnMailbox {
            mailbox_id: vec![3; 16],
            read_capability: vec![4; 32],
            write_capability: vec![5; 32],
        })
        .unwrap();

    // Another device of this identity, authorized here.
    let linked = Client::open(SharedConn::open_in_memory().unwrap()).unwrap();
    let pending = linked.device_pending_new().unwrap();
    let (credential, manifest) = client
        .device_authorize(&pending.keys.public(), onboarding::now())
        .unwrap();
    linked
        .device_link_complete(
            &credential,
            &manifest,
            root.public().as_bytes(),
            onboarding::now(),
        )
        .unwrap();
    let linked_device = linked.device().unwrap().unwrap();

    // Another identity.
    let other = Client::open(SharedConn::open_in_memory().unwrap()).unwrap();
    let other_root = other.identity_new().unwrap();
    let (other_device, _) = other.device_new(onboarding::now()).unwrap();

    let engine = client.mls_engine(me.mls_identity());
    let linked_engine = linked.mls_engine(linked_device.mls_identity());
    let other_engine = other.mls_engine(other_device.mls_identity());
    let mut group = engine.create_group().unwrap();
    let commit = group
        .commit_builder()
        .add_member(linked_engine.key_package().unwrap())
        .unwrap()
        .add_member(other_engine.key_package().unwrap())
        .unwrap()
        .build()
        .unwrap();
    group.apply_pending_commit().unwrap();
    group.write_to_storage().unwrap();
    let gid = group.group_id().to_vec();
    let mut linked_group = linked_engine.join(&commit.welcome_messages[0]).unwrap();
    let mut other_group = other_engine.join(&commit.welcome_messages[0]).unwrap();

    // At first this profile knows only its own other device in the group.
    client
        .conversation_save(&Conversation {
            group_id: gid.clone(),
            creator: true,
            peers: vec![peer_of(
                root.identity_id(),
                &linked_device,
                root.public().as_bytes(),
            )],
        })
        .unwrap();

    let (s, receiving) = session(&config).unwrap();
    let from_other = other_group
        .encrypt_application_message(&text("hola desde otra identidad"), vec![])
        .unwrap();
    handle_mls(&s, &receiving, from_other, b"from-other-0001").unwrap();
    let from_linked = linked_group
        .encrypt_application_message(&text("desde mi otro dispositivo"), vec![])
        .unwrap();
    handle_mls(&s, &receiving, from_linked, b"from-linked-001").unwrap();
    // Rows recorded before senders were kept.
    s.delivery
        .record_event(&gid, b"legacy-received", "received", b"sin remitente")
        .unwrap();
    s.delivery
        .record_event(&gid, b"legacy-sent-0001", "sent", b"enviado antes")
        .unwrap();

    // The other device was unknown when its message arrived: MLS still
    // names the device, and the identity stays empty rather than guessed.
    let stored = s.delivery.events_page(&gid, None, 10).unwrap();
    let raw = stored
        .iter()
        .find(|e| e.event_id == b"from-other-0001")
        .unwrap();
    assert_eq!(
        raw.sender_device.as_deref(),
        Some(&other_device.keys.device_id[..])
    );
    assert_eq!(raw.sender_identity, None);
    let raw_linked = stored
        .iter()
        .find(|e| e.event_id == b"from-linked-001")
        .unwrap();
    assert_eq!(raw_linked.sender_identity, Some(root.identity_id()));

    // Learning the device later names the earlier message.
    client
        .conversation_save(&Conversation {
            group_id: gid.clone(),
            creator: true,
            peers: vec![peer_of(
                other_root.identity_id(),
                &other_device,
                other_root.public().as_bytes(),
            )],
        })
        .unwrap();
    let page = history_page(&config, &gid, None, 50).unwrap();
    let find = |body: &str| {
        page.events
            .iter()
            .find(|e| e.body == body.as_bytes())
            .unwrap()
            .clone()
    };
    let now = onboarding::now() as i64;

    let other_message = find("hola desde otra identidad");
    assert_eq!(
        other_message.sender_identity,
        Some(other_root.identity_id())
    );
    assert_eq!(
        other_message.sender_label.as_deref(),
        Some(hex::encode(&other_root.identity_id()[..4]).as_str()),
        "an unnamed contact is shown by a short identifier"
    );
    assert!(!other_message.own);
    assert!((now - other_message.created_at).abs() < 60);

    let linked_message = find("desde mi otro dispositivo");
    assert!(linked_message.own, "another device of this identity is own");
    assert_eq!(linked_message.sender_label, None);

    let legacy_in = find("sin remitente");
    assert_eq!(
        (
            legacy_in.sender_identity,
            legacy_in.sender_label,
            legacy_in.own
        ),
        (None, None, false),
        "nothing guesses who wrote an old received row"
    );
    let legacy_out = find("enviado antes");
    assert!(legacy_out.own);
    assert_eq!(legacy_out.sender_identity, Some(root.identity_id()));

    // A local name reaches the page as the label.
    client
        .contact_rename(&other_root.identity_id(), "Lucía")
        .unwrap();
    let page = history_page(&config, &gid, None, 50).unwrap();
    let renamed = page
        .events
        .iter()
        .find(|e| e.body == b"hola desde otra identidad")
        .unwrap();
    assert_eq!(renamed.sender_label.as_deref(), Some("Lucía"));

    drop((s, receiving, engine, client));
    std::fs::remove_dir_all(&path).ok();
}
