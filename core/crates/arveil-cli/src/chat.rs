//! Phase 0 chat: MLS 1:1 conversations through the relay.
//!
//! `chat start` claims the peer's KeyPackage from the relay, creates a group
//! whose context carries the Arveil policy, adds the peer, seals the Welcome
//! to the peer's mailbox and then sends its own route inside the group.
//! `chat send` runs the send unit (MLS encrypt + persist + event + outbox in
//! one transaction) and publishes what is pending. `chat sync` publishes
//! pending envelopes, then fetches the mailbox and runs the receive unit per
//! envelope (dedup, open, MLS process, persist, event) before ACKing.
//!
//! Set `ARVEIL_CRASH_AFTER_COMMIT=1` to make `chat send` exit right after
//! the send unit committed and before anything is published: the next
//! `chat sync` or `chat send` retransmits the stored bytes (I-04).

use std::path::Path;

use arveil_core::channel::codec::Payload;
use arveil_core::client::{Client, Conversation, StoredDevice, StoredRealm};
use arveil_core::delivery::Delivery;
use arveil_core::envelope::{self, EnvelopeContext, KIND_MLS};
use arveil_core::mls::{self, Engine};
use mls_rs::client_builder::MlsConfig;
use mls_rs::group::ReceivedMessage;
use mls_rs::{MlsMessage, WireFormat};
use serde::{Deserialize, Serialize};

use crate::carrier::{Bootstrap, CliError, Connection, block_on, err};
use crate::commands::{Route, enrolled, parse_route, random_delivery_id};

/// Application event inside MLS (PROTOCOL §2, `ApplicationEvent`).
#[derive(Debug, Serialize, Deserialize)]
struct AppEvent {
    kind: String,
    #[serde(with = "serde_bytes")]
    body: Vec<u8>,
}

fn encode_event(kind: &str, body: &[u8]) -> Result<Vec<u8>, CliError> {
    arveil_core::signed::canonical(&AppEvent {
        kind: kind.into(),
        body: body.to_vec(),
    })
    .map_err(err("event"))
}

fn decode_event(bytes: &[u8]) -> Result<AppEvent, CliError> {
    ciborium::from_reader(bytes).map_err(err("event"))
}

struct Session {
    client: Client,
    device: StoredDevice,
    realm: StoredRealm,
    delivery: Delivery,
}

fn session(data_dir: &Path) -> Result<(Session, Engine<impl MlsConfig>), CliError> {
    let (client, device, realm) = enrolled(data_dir)?;
    let delivery = Delivery::open(client.conn.clone()).map_err(err("delivery"))?;
    let engine = mls::open(client.conn.clone(), device.mls_identity());
    Ok((
        Session {
            client,
            device,
            realm,
            delivery,
        },
        engine,
    ))
}

/// Seal `mls_bytes` for the peer of `conv` and enqueue it. Runs inside the
/// caller's unit of work.
fn enqueue_for_peer(
    s: &Session,
    conv: &Conversation,
    mls_bytes: &[u8],
) -> Result<Vec<u8>, rusqlite::Error> {
    let (Some(mailbox), Some(hpke)) = (&conv.peer_mailbox, &conv.peer_hpke) else {
        return Err(rusqlite::Error::InvalidQuery);
    };
    let delivery_id = random_delivery_id().map_err(|_| rusqlite::Error::InvalidQuery)?;
    let ctx = EnvelopeContext::new(&s.realm.realm_id, mailbox, &delivery_id);
    let sealed = envelope::seal(hpke, &ctx, KIND_MLS, mls_bytes)
        .map_err(|_| rusqlite::Error::InvalidQuery)?;
    s.delivery
        .enqueue(mailbox, &delivery_id, &sealed.enc, &sealed.ciphertext)?;
    Ok(delivery_id)
}

/// Publish every pending outbox row. Retransmissions reuse stored bytes.
async fn publish_pending(s: &Session, conn: &mut Connection) -> Result<usize, CliError> {
    let pending = s.delivery.pending().map_err(err("outbox"))?;
    let mut n = 0;
    for row in pending {
        // The write capability belongs to the conversation whose peer owns
        // this mailbox.
        let cap = s
            .client
            .conversations()
            .map_err(err("conversations"))?
            .into_iter()
            .find(|c| c.peer_mailbox.as_deref() == Some(row.mailbox_id.as_slice()))
            .and_then(|c| c.peer_write_cap)
            .ok_or_else(|| CliError("no write capability for a pending envelope".into()))?;
        s.delivery.mark_attempt(row.id).map_err(err("outbox"))?;
        match conn
            .request(Payload::EnvelopePut {
                mailbox_id: row.mailbox_id.clone(),
                write_capability: cap,
                delivery_id: row.delivery_id.clone(),
                requested_expiry: 0,
                hpke_enc: row.hpke_enc.clone(),
                ciphertext: row.ciphertext.clone(),
            })
            .await?
        {
            Payload::EnvelopeAccepted { .. } => {
                s.delivery.mark_accepted(row.id).map_err(err("outbox"))?;
                n += 1;
            }
            other => return Err(CliError(format!("unexpected reply: {other:?}"))),
        }
    }
    Ok(n)
}

fn own_route(s: &Session) -> Result<String, CliError> {
    let m = s
        .client
        .mailbox_own()
        .map_err(err("mailbox"))?
        .ok_or_else(|| CliError("no mailbox; run `mailbox create` first".into()))?;
    let root = s
        .client
        .root()
        .map_err(err("identity"))?
        .ok_or_else(|| CliError("no identity".into()))?;
    Ok(crate::commands::route_string(
        &root.identity_id(),
        &m,
        &s.device.keys.envelope_hpke.public,
    ))
}

/// `arveil chat start --data-dir D <bootstrap> <peer-route>`
pub fn start(data_dir: &Path, bootstrap: &str, peer_route: &str) -> Result<(), CliError> {
    let b = Bootstrap::parse(bootstrap)?;
    let peer: Route = parse_route(peer_route)?;
    let (s, engine) = session(data_dir)?;
    let my_route = own_route(&s)?;

    block_on(async {
        let mut conn = Connection::open(
            &b.url,
            &b.realm_id,
            &b.noise_public,
            &s.device.keys.transport_noise,
        )
        .await?;
        let kp = match conn
            .request(Payload::KeyPackagesClaim {
                identity_id: peer.identity_id.clone(),
            })
            .await?
        {
            Payload::KeyPackageClaimed { key_package } => {
                MlsMessage::from_bytes(&key_package).map_err(err("key package"))?
            }
            other => return Err(CliError(format!("unexpected reply: {other:?}"))),
        };

        // Group creation is one unit of work: MLS state, conversation row,
        // the Welcome and the route message in the outbox.
        let mut group = engine.create_group().map_err(err("mls"))?;
        let commit = group
            .commit_builder()
            .add_member(kp)
            .map_err(err("mls add"))?
            .build()
            .map_err(err("mls commit"))?;
        group.apply_pending_commit().map_err(err("mls apply"))?;
        let conv = Conversation {
            group_id: group.group_id().to_vec(),
            peer_identity: peer.identity_id.clone(),
            peer_mailbox: Some(peer.mailbox_id.clone()),
            peer_write_cap: Some(peer.write_capability.clone()),
            peer_hpke: Some(peer.hpke_public.clone()),
        };
        let welcome = commit.welcome_messages[0]
            .to_bytes()
            .map_err(err("welcome"))?;
        let route_msg = group
            .encrypt_application_message(
                &encode_event("route", my_route.as_bytes())?,
                Default::default(),
            )
            .map_err(err("mls encrypt"))?
            .to_bytes()
            .map_err(err("mls encode"))?;
        s.client
            .conn
            .unit_of_work(|_| {
                group
                    .write_to_storage()
                    .map_err(|_| rusqlite::Error::InvalidQuery)?;
                s.client
                    .conversation_save(&conv)
                    .map_err(|_| rusqlite::Error::InvalidQuery)?;
                enqueue_for_peer(&s, &conv, &welcome)?;
                enqueue_for_peer(&s, &conv, &route_msg)?;
                Ok::<_, rusqlite::Error>(())
            })
            .map_err(err("start unit"))?;
        println!(
            "conversation: {} created (epoch {})",
            hex::encode(&conv.group_id),
            group.current_epoch()
        );
        let n = publish_pending(&s, &mut conn).await?;
        println!("published: {n} envelope(s)");
        conn.close().await;
        Ok(())
    })?
}

/// `arveil chat send --data-dir D <bootstrap> <text>`
pub fn send(data_dir: &Path, bootstrap: &str, text: &str) -> Result<(), CliError> {
    let b = Bootstrap::parse(bootstrap)?;
    let (s, engine) = session(data_dir)?;
    let conv = s
        .client
        .conversations()
        .map_err(err("conversations"))?
        .into_iter()
        .next()
        .ok_or_else(|| CliError("no conversation; run `chat start` or `chat sync` first".into()))?;
    if conv.peer_mailbox.is_none() {
        return Err(CliError("peer route unknown yet; run `chat sync`".into()));
    }
    let mut group = engine.load_group(&conv.group_id).map_err(err("mls load"))?;
    let event_id = random_delivery_id()?;

    // Send unit: nothing leaves the device before this commits.
    s.client
        .conn
        .unit_of_work(|_| {
            let msg = group
                .encrypt_application_message(
                    &encode_event("text", text.as_bytes())
                        .map_err(|_| rusqlite::Error::InvalidQuery)?,
                    Default::default(),
                )
                .map_err(|_| rusqlite::Error::InvalidQuery)?;
            group
                .write_to_storage()
                .map_err(|_| rusqlite::Error::InvalidQuery)?;
            s.delivery
                .record_event(&conv.group_id, &event_id, "sent", text.as_bytes())?;
            let bytes = msg.to_bytes().map_err(|_| rusqlite::Error::InvalidQuery)?;
            enqueue_for_peer(&s, &conv, &bytes)?;
            Ok::<_, rusqlite::Error>(())
        })
        .map_err(err("send unit"))?;
    println!(
        "committed: message stored locally (epoch {})",
        group.current_epoch()
    );

    if std::env::var_os("ARVEIL_CRASH_AFTER_COMMIT").is_some() {
        eprintln!("simulated crash after commit, before publishing");
        std::process::exit(3);
    }

    block_on(async {
        let mut conn = Connection::open(
            &b.url,
            &b.realm_id,
            &b.noise_public,
            &s.device.keys.transport_noise,
        )
        .await?;
        let n = publish_pending(&s, &mut conn).await?;
        println!("published: {n} envelope(s)");
        conn.close().await;
        Ok(())
    })?
}

/// `arveil chat sync --data-dir D <bootstrap>`
pub fn sync(data_dir: &Path, bootstrap: &str) -> Result<(), CliError> {
    let b = Bootstrap::parse(bootstrap)?;
    let (s, engine) = session(data_dir)?;
    let m = s
        .client
        .mailbox_own()
        .map_err(err("mailbox"))?
        .ok_or_else(|| CliError("no mailbox".into()))?;

    block_on(async {
        let mut conn = Connection::open(
            &b.url,
            &b.realm_id,
            &b.noise_public,
            &s.device.keys.transport_noise,
        )
        .await?;
        let published = publish_pending(&s, &mut conn).await?;
        if published > 0 {
            println!("published: {published} pending envelope(s)");
        }
        let cursor = s.delivery.cursor(&m.mailbox_id).map_err(err("cursor"))? as u64;
        let (items, next) = match conn
            .request(Payload::EnvelopeFetch {
                mailbox_id: m.mailbox_id.clone(),
                read_capability: m.read_capability.clone(),
                cursor,
                limit: 50,
            })
            .await?
        {
            Payload::Envelopes { items, next_cursor } => (items, next_cursor),
            other => return Err(CliError(format!("unexpected reply: {other:?}"))),
        };

        let mut new = 0;
        for item in &items {
            let ctx = EnvelopeContext::new(&s.realm.realm_id, &m.mailbox_id, &item.delivery_id);
            let outcome: Result<Option<String>, CliError> = s.client.conn.unit_of_work(|_| {
                if !s
                    .delivery
                    .record_incoming(&m.mailbox_id, &item.delivery_id, item.seq as i64)
                    .map_err(err("inbox"))?
                {
                    return Ok(None);
                }
                let inner = envelope::open(
                    &s.device.keys.envelope_hpke.private,
                    &ctx,
                    &envelope::Sealed {
                        enc: item.hpke_enc.clone(),
                        ciphertext: item.ciphertext.clone(),
                    },
                )
                .map_err(err("open"))?;
                let msg = MlsMessage::from_bytes(&inner.payload).map_err(err("mls parse"))?;
                match msg.wire_format() {
                    WireFormat::Welcome => {
                        let mut group = engine.join(&msg).map_err(err("mls join"))?;
                        group.write_to_storage().map_err(err("mls persist"))?;
                        let peer_index = if group.current_member_index() == 0 {
                            1
                        } else {
                            0
                        };
                        let peer_identity = group
                            .member_at_index(peer_index)
                            .and_then(|mbr| {
                                mbr.signing_identity
                                    .credential
                                    .as_basic()
                                    .map(|c| c.identifier.clone())
                            })
                            .unwrap_or_default();
                        s.client
                            .conversation_save(&Conversation {
                                group_id: group.group_id().to_vec(),
                                peer_identity,
                                peer_mailbox: None,
                                peer_write_cap: None,
                                peer_hpke: None,
                            })
                            .map_err(err("conversation"))?;
                        Ok(Some(format!(
                            "joined conversation {} (epoch {})",
                            hex::encode(group.group_id()),
                            group.current_epoch()
                        )))
                    }
                    WireFormat::PrivateMessage => {
                        let gid = msg
                            .group_id()
                            .ok_or_else(|| CliError("message without group id".into()))?
                            .to_vec();
                        let mut group = engine.load_group(&gid).map_err(err("mls load"))?;
                        let received = group
                            .process_incoming_message(msg)
                            .map_err(err("mls process"))?;
                        group.write_to_storage().map_err(err("mls persist"))?;
                        match received {
                            ReceivedMessage::ApplicationMessage(app) => {
                                let ev = decode_event(app.data())?;
                                match ev.kind.as_str() {
                                    "route" => {
                                        let route =
                                            parse_route(&String::from_utf8_lossy(&ev.body))?;
                                        s.client
                                            .conversation_save(&Conversation {
                                                group_id: gid.clone(),
                                                peer_identity: route.identity_id,
                                                peer_mailbox: Some(route.mailbox_id),
                                                peer_write_cap: Some(route.write_capability),
                                                peer_hpke: Some(route.hpke_public),
                                            })
                                            .map_err(err("conversation"))?;
                                        Ok(Some("peer route learned inside the group".into()))
                                    }
                                    "text" => {
                                        s.delivery
                                            .record_event(
                                                &gid,
                                                &item.delivery_id,
                                                "received",
                                                &ev.body,
                                            )
                                            .map_err(err("event"))?;
                                        Ok(Some(format!(
                                            "message: {}",
                                            String::from_utf8_lossy(&ev.body)
                                        )))
                                    }
                                    other => Ok(Some(format!("event of kind {other} ignored"))),
                                }
                            }
                            ReceivedMessage::Commit(c) => {
                                Ok(Some(format!("commit from leaf {} applied", c.committer)))
                            }
                            other => Ok(Some(format!("mls message {other:?} processed"))),
                        }
                    }
                    other => Err(CliError(format!("unexpected MLS wire format {other:?}"))),
                }
            });
            match outcome {
                Ok(Some(line)) => {
                    new += 1;
                    println!("{line}");
                }
                Ok(None) => println!(
                    "duplicate: delivery {} ignored",
                    hex::encode(&item.delivery_id)
                ),
                Err(e) => println!(
                    "unprocessable: delivery {} left unacked ({e})",
                    hex::encode(&item.delivery_id)
                ),
            }
        }
        let unacked = s.delivery.unacked(&m.mailbox_id).map_err(err("inbox"))?;
        if !unacked.is_empty() {
            match conn
                .request(Payload::EnvelopeAck {
                    mailbox_id: m.mailbox_id.clone(),
                    read_capability: m.read_capability.clone(),
                    delivery_ids: unacked
                        .iter()
                        .cloned()
                        .map(serde_bytes::ByteBuf::from)
                        .collect(),
                })
                .await?
            {
                Payload::Ack => s
                    .delivery
                    .mark_acked(&m.mailbox_id, &unacked)
                    .map_err(err("inbox"))?,
                other => return Err(CliError(format!("unexpected reply: {other:?}"))),
            }
        }
        s.delivery
            .set_cursor(&m.mailbox_id, next as i64)
            .map_err(err("cursor"))?;
        println!(
            "synced: {} envelope(s), {new} new, {} acked",
            items.len(),
            unacked.len()
        );
        conn.close().await;
        Ok(())
    })?
}

/// `arveil chat history --data-dir D`
pub fn history(data_dir: &Path) -> Result<(), CliError> {
    let (s, _engine) = session(data_dir)?;
    for conv in s.client.conversations().map_err(err("conversations"))? {
        println!(
            "conversation {} with {}",
            hex::encode(&conv.group_id),
            hex::encode(&conv.peer_identity)
        );
        for (kind, body) in s.delivery.events(&conv.group_id).map_err(err("events"))? {
            println!("  [{kind:>8}] {}", String::from_utf8_lossy(&body));
        }
    }
    Ok(())
}
