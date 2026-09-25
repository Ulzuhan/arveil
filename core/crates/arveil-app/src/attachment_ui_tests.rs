use super::*;
use arveil_core::channel::codec::Frame;
use arveil_core::channel::{Channel, Responder, StaticKeypair};
use futures_util::SinkExt;
use tokio_tungstenite::tungstenite::Message;

#[derive(Default)]
struct Probe {
    blobs: Mutex<HashMap<Vec<u8>, Vec<u8>>>,
    begins: AtomicUsize,
    lose_upload_ack: AtomicBool,
    interrupt_download: AtomicBool,
    fetches: Mutex<Vec<u64>>,
    mode: AtomicUsize, // 1: bad hash, 2: oversized reply, 3: expired, 4: denied
    gate: AtomicBool,
    blocked: Mutex<Option<mpsc::Sender<()>>>,
    release: tokio::sync::Notify,
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
            Payload::BlobUploadBegin { .. } => {
                let n = probe.begins.fetch_add(1, Ordering::SeqCst) + 1;
                let id = vec![n as u8; 16];
                probe.blobs.lock().unwrap().insert(id.clone(), vec![]);
                Payload::BlobUploadStarted {
                    blob_id: id,
                    read_capability: vec![2; 32],
                }
            }
            Payload::BlobResume { blob_id } => Payload::BlobOffset {
                offset: probe.blobs.lock().unwrap()[&blob_id].len() as u64,
            },
            Payload::BlobChunk {
                blob_id,
                offset,
                data,
            } => {
                {
                    let mut all = probe.blobs.lock().unwrap();
                    let bytes = all.get_mut(&blob_id).unwrap();
                    assert_eq!(offset as usize, bytes.len());
                    bytes.extend_from_slice(&data);
                }
                if probe.lose_upload_ack.swap(false, Ordering::SeqCst) {
                    return;
                }
                Payload::Ack
            }
            Payload::BlobCommit { .. } => Payload::BlobCommitted {
                effective_expiry: onboarding::now() + 300,
            },
            Payload::BlobFetch {
                blob_id,
                offset,
                length,
                ..
            } => {
                probe.fetches.lock().unwrap().push(offset);
                if offset > 0 && probe.interrupt_download.swap(false, Ordering::SeqCst) {
                    return;
                }
                if offset > 0 && probe.gate.swap(false, Ordering::SeqCst) {
                    probe
                        .blocked
                        .lock()
                        .unwrap()
                        .take()
                        .unwrap()
                        .send(())
                        .unwrap();
                    probe.release.notified().await;
                }
                let mode = probe.mode.load(Ordering::SeqCst);
                if mode >= 3 {
                    Payload::Error {
                        code: if mode == 3 { 410 } else { 403 },
                        message: "unavailable".into(),
                    }
                } else {
                    let bytes = probe.blobs.lock().unwrap()[&blob_id].clone();
                    let end = (offset as usize + length as usize).min(bytes.len());
                    let mut data = bytes[offset as usize..end].to_vec();
                    if mode == 1 && !data.is_empty() {
                        data[0] ^= 1;
                    }
                    Payload::BlobData {
                        total_size: if mode == 2 {
                            u64::MAX
                        } else {
                            bytes.len() as u64
                        },
                        data,
                    }
                }
            }
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
    group: Vec<u8>,
    app: Application,
}
impl Fixture {
    fn new(relay: &Relay) -> Self {
        let path = std::env::temp_dir().join(format!(
            "arveil-files-{}",
            hex::encode(random_delivery_id().unwrap())
        ));
        std::fs::create_dir_all(&path).unwrap();
        let config = ProfileConfig::encrypted(&path, "19".repeat(32))
            .unwrap()
            .with_manual_attachments();
        let client = open_client(&config).unwrap();
        client.identity_new().unwrap();
        client.device_new(onboarding::now()).unwrap();
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
        let (s, engine) = session(&config).unwrap();
        let mut group = engine.create_group().unwrap();
        group.write_to_storage().unwrap();
        let id = group.group_id().to_vec();
        s.client
            .conversation_save(&Conversation {
                group_id: id.clone(),
                creator: true,
                peers: vec![],
            })
            .unwrap();
        Self {
            app: Application::open(config.clone()).unwrap(),
            config: config.clone(),
            group: id,
        }
    }
    fn reopen(&mut self) {
        self.app.close();
        self.app = Application::open(self.config.clone()).unwrap();
    }
    fn receive(&self, outgoing: &[u8]) -> Vec<u8> {
        let s = local(&self.config).unwrap();
        let row = s.delivery.attachment(outgoing).unwrap().unwrap();
        let id = random_delivery_id().unwrap();
        s.delivery
            .record_event(&self.group, &id, "file-pending", &row.descriptor)
            .unwrap();
        id
    }
    fn state(&self, id: &[u8]) -> AttachmentSummary {
        self.app
            .history_page(&self.group, None, 200)
            .unwrap()
            .events
            .into_iter()
            .find(|e| e.event_id == id)
            .unwrap()
            .attachment
            .unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.app.close();
        std::fs::remove_dir_all(self.config.dir()).unwrap();
    }
}

#[test]
fn upload_lost_ack_and_download_disconnect_resume_after_encrypted_reopen() {
    let relay = Relay::new();
    let mut f = Fixture::new(&relay);
    let bytes = b"attachment-private-content".repeat(7000);
    let id = f
        .app
        .queue_attachment(f.group.clone(), "../../same.txt".into(), bytes.clone())
        .unwrap();
    assert_eq!(f.state(&id).name, "same.txt");
    relay.probe.lose_upload_ack.store(true, Ordering::SeqCst);
    assert!(
        f.app
            .resume_attachment(relay.bootstrap(), f.group.clone(), id.clone())
            .is_err()
    );
    f.reopen();
    f.app
        .resume_attachment(relay.bootstrap(), f.group.clone(), id.clone())
        .unwrap();
    assert_eq!(relay.probe.begins.load(Ordering::SeqCst), 1);
    assert_eq!(f.state(&id).state, AttachmentState::Sent);
    f.app
        .resume_attachment(relay.bootstrap(), f.group.clone(), id.clone())
        .unwrap();
    assert_eq!(
        f.app.history_page(&f.group, None, 50).unwrap().events.len(),
        1
    );
    let incoming = f.receive(&id);
    relay.probe.interrupt_download.store(true, Ordering::SeqCst);
    assert!(
        f.app
            .resume_attachment(relay.bootstrap(), f.group.clone(), incoming.clone())
            .is_err()
    );
    assert_eq!(f.state(&incoming).transferred, BLOB_CHUNK as u64);
    f.reopen();
    f.app
        .resume_attachment(relay.bootstrap(), f.group.clone(), incoming.clone())
        .unwrap();
    assert_eq!(
        f.app
            .export_attachment(f.group.clone(), incoming.clone())
            .unwrap(),
        bytes
    );
    assert_eq!(
        relay.probe.fetches.lock().unwrap()[..3],
        [0, BLOB_CHUNK as u64, BLOB_CHUNK as u64]
    );
    assert!(!f.config.dir().join("downloads").exists());
    assert!(f.app.export_attachment(vec![99], incoming).is_err());
    assert!(
        !std::fs::read(f.config.dir().join("client.db"))
            .unwrap()
            .windows(26)
            .any(|w| w == b"attachment-private-content")
    );
}

#[test]
fn cancellation_during_a_request_stops_later_writes_and_can_redownload() {
    let relay = Relay::new();
    let f = Fixture::new(&relay);
    let bytes = vec![42; BLOB_CHUNK * 3];
    let id = f
        .app
        .queue_attachment(f.group.clone(), "same.txt".into(), bytes.clone())
        .unwrap();
    f.app
        .resume_attachment(relay.bootstrap(), f.group.clone(), id.clone())
        .unwrap();
    let incoming = f.receive(&id);
    let (tx, rx) = mpsc::channel();
    *relay.probe.blocked.lock().unwrap() = Some(tx);
    relay.probe.gate.store(true, Ordering::SeqCst);
    let app = f.app.clone();
    let bootstrap = relay.bootstrap();
    let group = f.group.clone();
    let event = incoming.clone();
    let worker = std::thread::spawn(move || app.resume_attachment(bootstrap, group, event));
    rx.recv_timeout(std::time::Duration::from_secs(5)).unwrap();
    f.app
        .cancel_attachment(f.group.clone(), incoming.clone())
        .unwrap();
    relay.probe.release.notify_one();
    worker.join().unwrap().unwrap();
    assert_eq!(f.state(&incoming).state, AttachmentState::Cancelled);
    assert_eq!(f.state(&incoming).transferred, 0);
    assert!(
        f.app
            .export_attachment(f.group.clone(), incoming.clone())
            .is_err()
    );
    f.app
        .resume_attachment(relay.bootstrap(), f.group.clone(), incoming.clone())
        .unwrap();
    assert_eq!(
        f.app.export_attachment(f.group.clone(), incoming).unwrap(),
        bytes
    );
    let cancelled = f
        .app
        .queue_attachment(f.group.clone(), "same.txt".into(), vec![0; 20])
        .unwrap();
    f.app
        .cancel_attachment(f.group.clone(), cancelled.clone())
        .unwrap();
    assert!(
        f.app
            .resume_attachment(relay.bootstrap(), f.group.clone(), cancelled)
            .is_err()
    );
    assert_eq!(f.app.export_attachment(f.group.clone(), id).unwrap(), bytes);
}

#[test]
fn bad_ciphertext_size_expiry_and_denial_never_export_unverified_bytes() {
    let relay = Relay::new();
    let f = Fixture::new(&relay);
    let id = f
        .app
        .queue_attachment(f.group.clone(), "same.txt".into(), vec![9; 100])
        .unwrap();
    f.app
        .resume_attachment(relay.bootstrap(), f.group.clone(), id.clone())
        .unwrap();
    for (mode, expected) in [
        (1, AttachmentState::Invalid),
        (2, AttachmentState::Invalid),
        (3, AttachmentState::Expired),
        (4, AttachmentState::Unavailable),
    ] {
        let incoming = f.receive(&id);
        relay.probe.mode.store(mode, Ordering::SeqCst);
        let _ = f
            .app
            .resume_attachment(relay.bootstrap(), f.group.clone(), incoming.clone());
        assert_eq!(f.state(&incoming).state, expected);
        assert!(f.app.export_attachment(f.group.clone(), incoming).is_err());
    }
    assert!(
        f.app
            .queue_attachment(
                f.group.clone(),
                "large".into(),
                vec![0; MAX_ATTACHMENT_BYTES + 1]
            )
            .is_err()
    );
    let s = local(&f.config).unwrap();
    let mut d = descriptor(
        &s.delivery.attachment(&id).unwrap().unwrap().descriptor,
        true,
    )
    .unwrap();
    d.size = u64::MAX;
    let invalid = random_delivery_id().unwrap();
    s.delivery
        .record_event(&f.group, &invalid, "file-pending", &d.encode().unwrap())
        .unwrap();
    assert_eq!(f.state(&invalid).state, AttachmentState::Invalid);
}
