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

#[test]
fn conversation_rows_count_unread_and_keep_markers() {
    let path = std::env::temp_dir().join(format!(
        "arveil-summaries-{}",
        hex::encode(random_delivery_id().unwrap())
    ));
    let config = ProfileConfig::unencrypted(&path);
    let client = open_client(&config).unwrap();
    client.identity_new().unwrap();
    client.device_new(onboarding::now()).unwrap();
    let other = Client::open(SharedConn::open_in_memory().unwrap()).unwrap();
    let other_root = other.identity_new().unwrap();
    let (other_device, _) = other.device_new(onboarding::now()).unwrap();
    let them = EventSender {
        device_id: Some(other_device.keys.device_id.to_vec()),
        identity_id: Some(other_root.identity_id()),
    };
    let (quiet, busy, empty) = (vec![1u8; 32], vec![2u8; 32], vec![3u8; 32]);
    for group in [&quiet, &busy, &empty] {
        client
            .conversation_save(&Conversation {
                group_id: group.clone(),
                creator: true,
                peers: vec![peer_of(
                    other_root.identity_id(),
                    &other_device,
                    other_root.public().as_bytes(),
                )],
            })
            .unwrap();
    }
    client
        .contact_rename(&other_root.identity_id(), "Lucía")
        .unwrap();
    let delivery = client.delivery().unwrap();
    let long = "una línea\ncon salto y un texto bastante largo ".repeat(6);
    delivery
        .record_event_by(&quiet, b"q-1", "received", b"hola", Some(&them))
        .unwrap();
    delivery
        .record_event_by(&busy, b"b-1", "received", b"primero", Some(&them))
        .unwrap();
    delivery
        .record_event_by(&busy, b"b-2", "sent", b"respuesta", None)
        .unwrap();
    delivery
        .record_event_by(&busy, b"b-3", "received", long.as_bytes(), Some(&them))
        .unwrap();

    let app = Application::open(config.clone()).unwrap();
    let rows = app.conversations().unwrap();
    // The application keeps the order conversations were started: the
    // command line lists them so and its scripts pick them by position.
    // Screens order by `last_activity` instead.
    let order: Vec<_> = rows.iter().map(|r| r.group_id.clone()).collect();
    assert_eq!(order, [quiet.clone(), busy.clone(), empty.clone()]);
    let row = |group: &[u8]| rows.iter().find(|r| r.group_id == group).unwrap().clone();
    let busy_row = row(&busy);
    assert_eq!(busy_row.unread, 2, "the sent reply is not unread");
    let last = busy_row.last_event.unwrap();
    assert_eq!(last.sender_label.as_deref(), Some("Lucía"));
    assert!(!last.own);
    assert_eq!(row(&quiet).unread, 1);
    let empty_row = row(&empty);
    assert_eq!((empty_row.unread, empty_row.last_event), (0, None));
    assert!(empty_row.last_activity > 0);

    let cursor = app
        .history_page(&busy, None, 10)
        .unwrap()
        .events
        .last()
        .unwrap()
        .cursor;
    assert_eq!(
        app.mark_read(&busy, cursor).unwrap(),
        ReadMarker { cursor, unread: 0 }
    );
    // A stale screen cannot move the marker back.
    assert_eq!(app.mark_read(&busy, 1).unwrap().cursor, cursor);
    app.close();
    drop(app);

    // Markers survive reopening, and what arrives next is unread again.
    delivery
        .record_event_by(&busy, b"b-4", "received", b"otra vez", Some(&them))
        .unwrap();
    let app = Application::open(config).unwrap();
    let rows = app.conversations().unwrap();
    let busy_row = rows.iter().find(|r| r.group_id == busy).unwrap();
    assert_eq!(busy_row.unread, 1);
    assert_eq!(rows.iter().find(|r| r.group_id == quiet).unwrap().unread, 1);
    app.close();
    drop((app, delivery, client));
    std::fs::remove_dir_all(&path).ok();
}

#[test]
fn a_contacts_new_device_is_announced_in_every_shared_conversation() {
    let path = std::env::temp_dir().join(format!(
        "arveil-notices-{}",
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
    let other = Client::open(SharedConn::open_in_memory().unwrap()).unwrap();
    let other_root = other.identity_new().unwrap();
    let (other_device, _) = other.device_new(onboarding::now()).unwrap();

    let engine = client.mls_engine(me.mls_identity());
    let other_engine = other.mls_engine(other_device.mls_identity());
    let mut group = engine.create_group().unwrap();
    let commit = group
        .commit_builder()
        .add_member(other_engine.key_package().unwrap())
        .unwrap()
        .build()
        .unwrap();
    group.apply_pending_commit().unwrap();
    group.write_to_storage().unwrap();
    let gid = group.group_id().to_vec();
    let mut other_group = other_engine.join(&commit.welcome_messages[0]).unwrap();
    // A second conversation with the same contact, carried elsewhere.
    let second = vec![6u8; 32];
    for group_id in [gid.clone(), second.clone()] {
        client
            .conversation_save(&Conversation {
                group_id,
                creator: true,
                peers: vec![peer_of(
                    other_root.identity_id(),
                    &other_device,
                    other_root.public().as_bytes(),
                )],
            })
            .unwrap();
    }
    let (s, receiving) = session(&config).unwrap();
    let notices = |group: &[u8]| {
        history_page(&config, group, None, 20)
            .unwrap()
            .events
            .into_iter()
            .filter(|e| e.notice.is_some())
            .collect::<Vec<_>>()
    };

    // The first manifest this profile learns is a baseline, not news.
    let baseline = other.latest_manifest().unwrap().unwrap();
    let message = other_group
        .encrypt_application_message(&encode_event("manifest", &baseline).unwrap(), vec![])
        .unwrap();
    handle_mls(&s, &receiving, message, b"manifest-first-1").unwrap();
    assert!(notices(&gid).is_empty());

    // The contact links another device.
    let extra = Client::open(SharedConn::open_in_memory().unwrap()).unwrap();
    let pending = extra.device_pending_new().unwrap();
    other
        .device_authorize(&pending.keys.public(), onboarding::now())
        .unwrap();
    let next = other.latest_manifest().unwrap().unwrap();
    let message = other_group
        .encrypt_application_message(&encode_event("manifest", &next).unwrap(), vec![])
        .unwrap();
    handle_mls(&s, &receiving, message, b"manifest-second2").unwrap();
    for group_id in [&gid, &second] {
        let found = notices(group_id);
        assert_eq!(found.len(), 1, "one notice in each shared conversation");
        let notice = &found[0];
        assert_eq!(
            notice.notice,
            Some(DeviceChange {
                added: 1,
                removed: 0
            })
        );
        assert_eq!(notice.sender_identity, Some(other_root.identity_id()));
        assert!(notice.sender_label.is_some());
        assert!(!notice.own);
        assert!(notice.body.is_empty() || DeviceChange::decode(&notice.body).is_some());
    }
    // Notices are not messages: nothing is unread.
    for row in conversation_summaries(&config).unwrap() {
        assert_eq!(row.unread, 0);
    }
    // The same manifest again announces nothing more.
    let message = other_group
        .encrypt_application_message(&encode_event("manifest", &next).unwrap(), vec![])
        .unwrap();
    handle_mls(&s, &receiving, message, b"manifest-repeat3").unwrap();
    assert_eq!(notices(&gid).len(), 1);

    drop((s, receiving, engine, client));
    std::fs::remove_dir_all(&path).ok();
}
