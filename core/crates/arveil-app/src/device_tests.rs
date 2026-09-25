use super::*;
use arveil_core::channel::codec::Frame;
use arveil_core::channel::{Channel, Responder, StaticKeypair};
use futures_util::SinkExt;
use tokio_tungstenite::tungstenite::Message;

#[derive(Default)]
struct Probe {
    manifests: Mutex<Vec<Vec<u8>>>,
    lose_manifest_ack: AtomicBool,
    lose_envelope_ack: AtomicBool,
    envelopes: Mutex<Vec<(Vec<u8>, Vec<u8>)>>,
}

struct Relay {
    noise: StaticKeypair,
    signing: ed25519_dalek::SigningKey,
    url: String,
    probe: Arc<Probe>,
    stop: Option<tokio::sync::oneshot::Sender<()>>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl Relay {
    fn new() -> Self {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("ws://{}/v1/channel", listener.local_addr().unwrap());
        listener.set_nonblocking(true).unwrap();
        let noise = StaticKeypair::generate().unwrap();
        let signing = ed25519_dalek::SigningKey::from_bytes(&[8; 32]);
        let endpoints = arveil_core::channel::endpoints::RealmEndpointList {
            version: 1,
            realm_id: vec![7; 32],
            sequence: 1,
            realm_noise_public_key: noise.public.clone(),
            endpoints: vec![arveil_core::channel::endpoints::Endpoint {
                kind: "test".into(),
                url: url.clone(),
                priority: 0,
            }],
        };
        let signed = arveil_core::signed::sign_value(
            arveil_core::channel::endpoints::CONTEXT,
            &endpoints,
            &signing,
        )
        .unwrap();
        let probe = Arc::new(Probe::default());
        let state = probe.clone();
        let key = noise.clone();
        let (stop, mut stopped) = tokio::sync::oneshot::channel();
        let thread = std::thread::spawn(move || {
            tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap().block_on(async move {
                let listener = tokio::net::TcpListener::from_std(listener).unwrap();
                let mut tasks = Vec::new();
                loop {
                    tokio::select! {
                        _ = &mut stopped => break,
                        incoming = listener.accept() => {
                            let (socket, _) = incoming.unwrap();
                            tasks.push(tokio::spawn(serve(socket, key.clone(), signed.clone(), state.clone())));
                        }
                    }
                }
                for task in tasks { task.abort(); let _ = task.await; }
            });
        });
        Self {
            noise,
            signing,
            url,
            probe,
            stop: Some(stop),
            thread: Some(thread),
        }
    }
    fn bootstrap(&self) -> String {
        format!(
            "arveil-bootstrap:v0:{}:{}:{}:{}",
            hex::encode([7; 32]),
            hex::encode(self.signing.verifying_key().as_bytes()),
            hex::encode(&self.noise.public),
            self.url
        )
    }
}
impl Drop for Relay {
    fn drop(&mut self) {
        let _ = self.stop.take().unwrap().send(());
        self.thread.take().unwrap().join().unwrap();
    }
}

async fn serve(
    socket: tokio::net::TcpStream,
    key: StaticKeypair,
    endpoints: Vec<u8>,
    probe: Arc<Probe>,
) {
    let mut ws = tokio_tungstenite::accept_async(socket).await.unwrap();
    let Ok(Message::Binary(first)) = ws.next().await.unwrap() else {
        return;
    };
    let mut responder = Responder::new(&key, &arveil_core::channel::prologue(&[7; 32])).unwrap();
    responder.read_message_1(&first).unwrap();
    let (second, transport) = responder.write_message_2().unwrap();
    ws.send(Message::Binary(second.into())).await.unwrap();
    let mut channel = Channel::new(transport);
    while let Some(Ok(Message::Binary(bytes))) = ws.next().await {
        let Some(frame) = channel.open(&bytes).unwrap() else {
            continue;
        };
        let reply = match frame.payload {
            Payload::EndpointListGet => Payload::EndpointList {
                signed: endpoints.clone(),
            },
            Payload::ManifestPut { manifest } => {
                probe.manifests.lock().unwrap().push(manifest);
                if probe.lose_manifest_ack.swap(false, Ordering::SeqCst) {
                    return;
                }
                Payload::Ack
            }
            Payload::EnvelopePut {
                delivery_id,
                ciphertext,
                ..
            } => {
                probe
                    .envelopes
                    .lock()
                    .unwrap()
                    .push((delivery_id, ciphertext));
                if probe.lose_envelope_ack.swap(false, Ordering::SeqCst) {
                    return;
                }
                Payload::EnvelopeAccepted {
                    effective_expiry: onboarding::now() + 600,
                }
            }
            Payload::ManifestGet { .. } => Payload::ManifestLatest {
                manifest: probe
                    .manifests
                    .lock()
                    .unwrap()
                    .last()
                    .cloned()
                    .unwrap_or_default(),
            },
            Payload::KeyPackagesStatus => Payload::KeyPackagesAvailable { count: 100 },
            Payload::EnvelopeFetch { .. } => Payload::Envelopes {
                items: vec![],
                next_cursor: 0,
            },
            other => panic!("unexpected test payload: {other:?}"),
        };
        for bytes in channel
            .seal(&Frame {
                id: frame.id,
                payload: reply,
            })
            .unwrap()
        {
            if ws.send(Message::Binary(bytes.into())).await.is_err() {
                return;
            }
        }
    }
}

struct Fixture {
    config: ProfileConfig,
    app: Application,
    target: Vec<u8>,
    group: Vec<u8>,
    linked: Client,
}

impl Fixture {
    fn new(relay: &Relay) -> Self {
        let path = std::env::temp_dir().join(format!(
            "arveil-devices-{}",
            hex::encode(random_delivery_id().unwrap())
        ));
        let config = ProfileConfig::encrypted(&path, "23".repeat(32))
            .unwrap()
            .with_manual_attachments();
        let client = open_client(&config).unwrap();
        let root = client.identity_new().unwrap();
        let (me, _) = client.device_new(onboarding::now()).unwrap();
        client
            .realm_save(
                &[7; 32],
                &relay.signing.verifying_key(),
                &relay.noise.public,
                &relay.url,
            )
            .unwrap();
        client.realm_mark_enrolled(&[7; 32]).unwrap();
        client
            .mailbox_save(&OwnMailbox {
                mailbox_id: vec![3; 16],
                read_capability: vec![4; 32],
                write_capability: vec![5; 32],
            })
            .unwrap();
        let linked = Client::open(SharedConn::open_in_memory().unwrap()).unwrap();
        let target = linked.device_pending_new().unwrap();
        let (credential, manifest) = client
            .device_authorize(&target.keys.public(), onboarding::now())
            .unwrap();
        linked
            .device_link_complete(
                &credential,
                &manifest,
                root.public().as_bytes(),
                onboarding::now(),
            )
            .unwrap();
        let other = Client::open(SharedConn::open_in_memory().unwrap()).unwrap();
        let other_root = other.identity_new().unwrap();
        let (other_device, _) = other.device_new(onboarding::now()).unwrap();
        let engine = client.mls_engine(me.mls_identity());
        let target_engine = linked.mls_engine(linked.device().unwrap().unwrap().mls_identity());
        let other_engine = other.mls_engine(other_device.mls_identity());
        let mut group = engine.create_group().unwrap();
        group
            .commit_builder()
            .add_member(target_engine.key_package().unwrap())
            .unwrap()
            .add_member(other_engine.key_package().unwrap())
            .unwrap()
            .build()
            .unwrap();
        group.apply_pending_commit().unwrap();
        group.write_to_storage().unwrap();
        let target_id = target.keys.device_id.to_vec();
        client
            .conversation_save(&Conversation {
                group_id: group.group_id().to_vec(),
                creator: true,
                peers: vec![
                    Peer {
                        identity: root.identity_id(),
                        device_id: target_id.clone(),
                        credential_hash: arveil_core::identity::credential_hash(&credential),
                        root_public: root.public().as_bytes().to_vec(),
                        mailbox: Some(vec![9; 16]),
                        write_cap: Some(vec![10; 32]),
                        hpke: Some(target.keys.envelope_hpke.public),
                        revoked: false,
                    },
                    Peer {
                        identity: other_root.identity_id(),
                        device_id: other_device.keys.device_id.to_vec(),
                        credential_hash: other_device.credential_hash,
                        root_public: other_root.public().as_bytes().to_vec(),
                        mailbox: Some(vec![11; 16]),
                        write_cap: Some(vec![12; 32]),
                        hpke: Some(other_device.keys.envelope_hpke.public),
                        revoked: false,
                    },
                ],
            })
            .unwrap();
        Self {
            app: Application::open(config.clone()).unwrap(),
            config,
            target: target_id,
            group: group.group_id().to_vec(),
            linked,
        }
    }
    fn progress(&self) -> RevocationProgress {
        self.app
            .devices()
            .unwrap()
            .devices
            .into_iter()
            .find(|d| d.device_id == self.target)
            .unwrap()
            .revocation
            .unwrap()
    }
    fn reopen(&mut self) {
        self.app.close();
        self.app = Application::open(self.config.clone()).unwrap();
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        self.app.close();
        std::fs::remove_dir_all(&self.config.dir).unwrap();
    }
}

#[test]
fn revocation_resumes_lost_acks_and_reopen_without_new_manifests_or_mls_changes() {
    let relay = Relay::new();
    let mut f = Fixture::new(&relay);
    relay.probe.lose_manifest_ack.store(true, Ordering::SeqCst);
    let target = hex::encode(&f.target);
    assert!(f.app.revoke_device(&relay.bootstrap(), &target).is_err());
    let before = f.app.devices().unwrap();
    assert_eq!(before.manifest_sequence, 3);
    assert_eq!(f.progress().groups_waiting, 0);
    assert!(!f.progress().relay_published);
    assert_eq!(f.progress().notifications_pending, 2);
    let (s, engine) = session(&f.config).unwrap();
    let epoch = engine.load_group(&f.group).unwrap().current_epoch();
    let sealed = s.delivery.pending().unwrap();
    assert!(
        sealed.iter().all(|r| r.mailbox_id == vec![11; 16]),
        "revoked recipient got notifications"
    );
    drop(engine);
    drop(s);
    f.reopen();
    relay.probe.lose_envelope_ack.store(true, Ordering::SeqCst);
    assert!(f.app.revoke_device(&relay.bootstrap(), &target).is_err());
    assert!(f.progress().relay_published);
    assert_eq!(f.progress().notifications_pending, 2);
    f.reopen();
    // Normal sync resumes an earlier confirmed revocation.
    f.app.sync(&relay.bootstrap()).unwrap();
    assert_eq!(f.progress().notifications_pending, 0);
    let (s, engine) = session(&f.config).unwrap();
    assert_eq!(engine.load_group(&f.group).unwrap().current_epoch(), epoch);
    assert_eq!(
        f.app.devices().unwrap().manifest_sequence,
        before.manifest_sequence
    );
    assert!(s.delivery.pending().unwrap().is_empty());
    let manifests = relay.probe.manifests.lock().unwrap();
    assert_eq!(manifests.len(), 2);
    assert_eq!(manifests[0], manifests[1]);
    let envelopes = relay.probe.envelopes.lock().unwrap();
    assert_eq!(envelopes.len(), 3);
    assert_eq!(
        envelopes[0], envelopes[1],
        "lost ACK retry changed the sealed bytes/id"
    );
    assert_ne!(envelopes[1].0, envelopes[2].0);
}

#[test]
fn invalid_revocations_and_failed_local_transaction_leave_no_partial_state() {
    let relay = Relay::new();
    let f = Fixture::new(&relay);
    let client = open_client(&f.config).unwrap();
    let before = client.latest_manifest().unwrap();
    let own = client.device().unwrap().unwrap().keys.device_id;
    for id in [hex::encode(own), "unknown".into(), hex::encode([99; 16])] {
        assert!(f.app.revoke_device(&relay.bootstrap(), &id).is_err());
    }
    assert!(
        f.linked.device_revoke(&own).is_err(),
        "linked device must not have root authority"
    );
    assert_eq!(client.latest_manifest().unwrap(), before);
    assert!(client.revocations().unwrap().is_empty());
    let conn =
        SharedConn::open_file_keyed(&f.config.dir.join("client.db"), f.config.key()).unwrap();
    conn.lock().execute_batch("CREATE TRIGGER fail_revoke BEFORE INSERT ON device_revocations BEGIN SELECT RAISE(ABORT, 'injected'); END;").unwrap();
    assert!(
        f.app
            .revoke_device(&relay.bootstrap(), &hex::encode(&f.target))
            .is_err()
    );
    assert_eq!(client.latest_manifest().unwrap(), before);
    assert!(!client.device_revoked(&f.target).unwrap());
    assert!(client.revocations().unwrap().is_empty());
    assert!(relay.probe.manifests.lock().unwrap().is_empty());
}

#[test]
fn group_failure_rolls_back_mls_and_outbox_then_retry_uses_the_latest_manifest() {
    let relay = Relay::new();
    let mut f = Fixture::new(&relay);
    let epoch = {
        let (_, engine) = session(&f.config).unwrap();
        engine.load_group(&f.group).unwrap().current_epoch()
    };
    let conn =
        SharedConn::open_file_keyed(&f.config.dir.join("client.db"), f.config.key()).unwrap();
    conn.lock().execute_batch("CREATE TRIGGER fail_group BEFORE INSERT ON revocation_groups BEGIN SELECT RAISE(ABORT, 'injected'); END;").unwrap();
    assert!(
        f.app
            .revoke_device(&relay.bootstrap(), &hex::encode(&f.target))
            .is_err()
    );
    assert_eq!(f.progress().groups_waiting, 1);
    assert_eq!(f.progress().notifications_pending, 0);
    assert!(!f.progress().relay_published);
    {
        let (s, engine) = session(&f.config).unwrap();
        assert_eq!(engine.load_group(&f.group).unwrap().current_epoch(), epoch);
        assert!(s.delivery.pending().unwrap().is_empty());
    }
    conn.lock()
        .execute_batch("DROP TRIGGER fail_group")
        .unwrap();
    // A later authorized link advances the manifest while revocation is pending.
    let another = Client::open(SharedConn::open_in_memory().unwrap()).unwrap();
    let public = another.device_pending_new().unwrap().keys.public();
    let client = open_client(&f.config).unwrap();
    client.device_authorize(&public, onboarding::now()).unwrap();
    let latest = client.latest_manifest().unwrap().unwrap();
    f.reopen();
    f.app.sync(&relay.bootstrap()).unwrap();
    assert_eq!(f.progress().groups_waiting, 0);
    assert!(f.progress().relay_published);
    assert_eq!(f.app.devices().unwrap().manifest_sequence, 4);
    assert_eq!(*relay.probe.manifests.lock().unwrap(), vec![latest]);
}
