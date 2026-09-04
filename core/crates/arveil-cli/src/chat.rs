//! Phase 1 chat: MLS groups of N devices through the relay.
//!
//! `chat start` claims one KeyPackage per peer, creates a group whose
//! context carries the Arveil policy (creator = committer), adds every peer
//! in one commit, seals the Welcome to each peer and then sends the roster
//! (every member's route, including its own) inside the group.
//! `chat add` (creator only) adds a member later: Welcome to the newcomer,
//! commit to the existing members, updated roster to everyone.
//! `chat send` runs the send unit once (MLS encrypt + persist + event) and
//! enqueues one envelope per routable peer; peers without a route are
//! visible as pending. `chat sync` publishes what is pending, then fetches
//! the mailbox and runs the receive unit per envelope before ACKing.
//!
//! Set `ARVEIL_CRASH_AFTER_COMMIT=1` to make `chat send` exit right after
//! the send unit committed and before anything is published (I-04).

use std::path::Path;

use arveil_core::attachments::{self, FileDescriptor};
use arveil_core::channel::codec::Payload;
use arveil_core::client::{Client, Conversation, Peer, StoredDevice, StoredRealm};
use arveil_core::delivery::Delivery;
use arveil_core::envelope::{self, EnvelopeContext, KIND_MLS};
use arveil_core::mls::{self, Engine};
use mls_rs::client_builder::MlsConfig;
use mls_rs::group::{Group, ReceivedMessage};
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
    identity_id: Vec<u8>,
}

fn session(data_dir: &Path) -> Result<(Session, Engine<impl MlsConfig>), CliError> {
    let (client, device, realm) = enrolled(data_dir)?;
    let delivery = Delivery::open(client.conn.clone()).map_err(err("delivery"))?;
    let identity_id = client
        .identity_id()
        .map_err(err("identity"))?
        .ok_or_else(|| CliError("no identity".into()))?;
    let engine = mls::open(client.conn.clone(), device.mls_identity());
    Ok((
        Session {
            client,
            device,
            realm,
            delivery,
            identity_id,
        },
        engine,
    ))
}

fn own_route(s: &Session) -> Result<String, CliError> {
    let m = s
        .client
        .mailbox_own()
        .map_err(err("mailbox"))?
        .ok_or_else(|| CliError("no mailbox; run `mailbox create` first".into()))?;
    crate::commands::route_string(&s.client, &s.device, &m)
}

fn peer_from_route(r: &Route) -> Peer {
    Peer {
        identity: r.identity_id.clone(),
        device_id: r.device_id.clone(),
        credential_hash: r.credential_hash.clone(),
        root_public: r.root_public.clone(),
        mailbox: Some(r.mailbox_id.clone()),
        write_cap: Some(r.write_capability.clone()),
        hpke: Some(r.hpke_public.clone()),
        revoked: false,
    }
}

fn route_of_peer(p: &Peer) -> Option<String> {
    match (&p.mailbox, &p.write_cap, &p.hpke) {
        (Some(m), Some(w), Some(h)) => Some(format!(
            "arveil-route:v1:{}:{}:{}:{}:{}:{}:{}",
            hex::encode(&p.identity),
            hex::encode(&p.device_id),
            hex::encode(&p.credential_hash),
            hex::encode(&p.root_public),
            hex::encode(m),
            hex::encode(w),
            hex::encode(h)
        )),
        _ => None,
    }
}

/// Seal `mls_bytes` for one peer and enqueue it. Inside the unit of work.
/// A peer without a route is skipped here and visible in `history`.
fn enqueue_for(
    s: &Session,
    peer: &Peer,
    event_id: Option<&[u8]>,
    mls_bytes: &[u8],
) -> Result<bool, rusqlite::Error> {
    let (Some(mailbox), Some(hpke)) = (&peer.mailbox, &peer.hpke) else {
        return Ok(false);
    };
    let delivery_id = random_delivery_id().map_err(|_| rusqlite::Error::InvalidQuery)?;
    let ctx = EnvelopeContext::new(&s.realm.realm_id, mailbox, &delivery_id);
    let sealed = envelope::seal(hpke, &ctx, KIND_MLS, mls_bytes)
        .map_err(|_| rusqlite::Error::InvalidQuery)?;
    s.delivery.enqueue(
        mailbox,
        &delivery_id,
        event_id,
        &sealed.enc,
        &sealed.ciphertext,
    )?;
    Ok(true)
}

/// What one fan-out did, so the CLI can report it without guessing.
#[derive(Default, Clone, Copy)]
struct FanOut {
    sent: usize,
    no_route: usize,
    revoked: usize,
}

impl FanOut {
    /// The tail of the line describing what did not go out.
    fn note(&self) -> String {
        let mut parts = Vec::new();
        if self.no_route > 0 {
            parts.push(format!("{} peer(s) without a route yet", self.no_route));
        }
        if self.revoked > 0 {
            parts.push(format!("{} revoked device(s) skipped", self.revoked));
        }
        if parts.is_empty() {
            String::new()
        } else {
            format!(", {}", parts.join(", "))
        }
    }
}

/// Fan-out: one envelope per routable, non-revoked peer device.
fn enqueue_for_all(
    s: &Session,
    peers: &[Peer],
    event_id: Option<&[u8]>,
    mls_bytes: &[u8],
) -> Result<FanOut, rusqlite::Error> {
    let mut out = FanOut::default();
    for p in peers {
        // A device known to be revoked receives nothing more.
        if p.revoked {
            out.revoked += 1;
            continue;
        }
        if enqueue_for(s, p, event_id, mls_bytes)? {
            out.sent += 1;
        } else {
            out.no_route += 1;
        }
    }
    Ok(out)
}

/// Write capability for a mailbox, from any conversation that knows it.
fn write_cap_for(s: &Session, mailbox: &[u8]) -> Result<Vec<u8>, CliError> {
    for c in s.client.conversations().map_err(err("conversations"))? {
        for p in c.peers {
            if p.mailbox.as_deref() == Some(mailbox)
                && let Some(cap) = p.write_cap
            {
                return Ok(cap);
            }
        }
    }
    Err(CliError(
        "no write capability for a pending envelope".into(),
    ))
}

/// Requested envelope expiry: `ARVEIL_ENVELOPE_TTL_SECS` from now, or 0
/// to accept the relay's default. The relay may shorten it and reports the
/// effective value, which the outbox records.
fn requested_expiry() -> u64 {
    std::env::var("ARVEIL_ENVELOPE_TTL_SECS")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .map(|ttl| {
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0)
                + ttl
        })
        .unwrap_or(0)
}

/// Publish every pending outbox row. Retransmissions reuse stored bytes.
async fn publish_pending(s: &Session, conn: &mut Connection) -> Result<usize, CliError> {
    let pending = s.delivery.pending().map_err(err("outbox"))?;
    let mut n = 0;
    for row in pending {
        let cap = write_cap_for(s, &row.mailbox_id)?;
        s.delivery.mark_attempt(row.id).map_err(err("outbox"))?;
        let reply = conn
            .request(Payload::EnvelopePut {
                mailbox_id: row.mailbox_id.clone(),
                write_capability: cap,
                delivery_id: row.delivery_id.clone(),
                requested_expiry: requested_expiry(),
                hpke_enc: row.hpke_enc.clone(),
                ciphertext: row.ciphertext.clone(),
            })
            .await;
        match reply {
            Ok(Payload::EnvelopeAccepted { effective_expiry }) => {
                s.delivery
                    .mark_accepted(row.id, Some(effective_expiry as i64))
                    .map_err(err("outbox"))?;
                n += 1;
            }
            Ok(other) => return Err(CliError(format!("unexpected reply: {other:?}"))),
            // A revoked device's capabilities are gone: the envelope will
            // never be accepted. Say so once and stop retrying it.
            Err(e) if e.0.contains("(403)") || e.0.contains("(410)") => {
                s.delivery
                    .mark_undeliverable(row.id)
                    .map_err(err("outbox"))?;
                println!(
                    "undeliverable: mailbox {} refused the envelope ({e})",
                    hex::encode(&row.mailbox_id[..4])
                );
            }
            Err(e) => return Err(e),
        }
    }
    Ok(n)
}

/// Device ids currently holding a leaf in the group, from the MLS roster.
fn roster_device_ids<C: MlsConfig>(group: &Group<C>) -> Vec<Vec<u8>> {
    group
        .roster()
        .members()
        .into_iter()
        .filter_map(|m| {
            m.signing_identity
                .credential
                .as_basic()
                .map(|b| b.identifier.clone())
        })
        .collect()
}

/// The leaf this device holds, and whether it is the authorized committer:
/// the lowest leaf that is not known to be revoked (policy v2).
fn committer_leaf<C: MlsConfig>(s: &Session, group: &Group<C>) -> Option<u32> {
    let mut members: Vec<_> = group.roster().members();
    members.sort_by_key(|m| m.index);
    members
        .into_iter()
        .find(|m| {
            let device = m
                .signing_identity
                .credential
                .as_basic()
                .map(|c| c.identifier.clone())
                .unwrap_or_default();
            !s.client.device_revoked(&device).unwrap_or(false)
        })
        .map(|m| m.index)
}

fn i_am_committer<C: MlsConfig>(s: &Session, group: &Group<C>) -> bool {
    committer_leaf(s, group) == Some(group.current_member_index())
}

/// Revoked devices that still hold a leaf. While any exists, this device
/// refuses to send: the epoch still lets them read (PROTOCOL §8).
fn revoked_leaves<C: MlsConfig>(conv: &Conversation, group: &Group<C>) -> Vec<Vec<u8>> {
    let leaves = roster_device_ids(group);
    conv.peers
        .iter()
        .filter(|p| p.revoked && leaves.contains(&p.device_id))
        .map(|p| p.device_id.clone())
        .collect()
}

/// Refuse to send while a revoked device is still a member.
fn guard_revoked<C: MlsConfig>(conv: &Conversation, group: &Group<C>) -> Result<(), CliError> {
    let stuck = revoked_leaves(conv, group);
    if stuck.is_empty() {
        return Ok(());
    }
    Err(CliError(format!(
        "paused: {} revoked device(s) still in the group ({}); waiting for the committer to remove them",
        stuck.len(),
        stuck
            .iter()
            .map(|d| hex::encode(&d[..4]))
            .collect::<Vec<_>>()
            .join(", ")
    )))
}

/// Encrypt a signed manifest as a `manifest` event for the group.
fn manifest_message<C: MlsConfig>(
    group: &mut Group<C>,
    manifest: &[u8],
) -> Result<Vec<u8>, CliError> {
    group
        .encrypt_application_message(&encode_event("manifest", manifest)?, Default::default())
        .map_err(err("mls encrypt"))?
        .to_bytes()
        .map_err(err("mls encode"))
}

/// Connect through the first endpoint that completes the handshake, in
/// priority order from the stored signed list, with the bootstrap URL as
/// the last resort. A dead or hostile endpoint costs one failed attempt.
/// After connecting, the list is refreshed; a lower sequence is refused.
async fn connect(s: &Session, b: &Bootstrap) -> Result<Connection, CliError> {
    let mut candidates: Vec<String> = Vec::new();
    if let Some(list) = &s.realm.endpoint_list {
        let mut eps = list.endpoints.clone();
        eps.sort_by_key(|e| e.priority);
        candidates.extend(eps.into_iter().filter(|e| e.kind != "admin").map(|e| e.url));
    }
    if !candidates.contains(&b.url) {
        candidates.push(b.url.clone());
    }
    let mut last = CliError("no endpoints".into());
    for url in &candidates {
        match Connection::open(
            url,
            &b.realm_id,
            &s.realm.noise_public,
            &s.device.keys.transport_noise,
        )
        .await
        {
            Ok(mut conn) => {
                if candidates.first() != Some(url) {
                    println!("endpoint: {url} (earlier endpoints unreachable)");
                }
                if let Ok(Payload::EndpointList { signed }) =
                    conn.request(Payload::EndpointListGet).await
                {
                    match s.client.realm_accept_endpoint_list(&b.realm_id, &signed) {
                        Ok(list) => {
                            if s.realm.endpoint_list.as_ref().map(|l| l.sequence)
                                != Some(list.sequence)
                            {
                                println!(
                                    "endpoint list: sequence {} with {} endpoint(s) stored",
                                    list.sequence,
                                    list.endpoints.len()
                                );
                            }
                        }
                        Err(e) => println!("endpoint list: refused ({e})"),
                    }
                }
                return Ok(conn);
            }
            Err(e) => {
                println!("endpoint: {url} failed ({e}); trying the next one");
                last = e;
            }
        }
    }
    Err(last)
}

async fn claim_key_package(conn: &mut Connection, r: &Route) -> Result<MlsMessage, CliError> {
    match conn
        .request(Payload::KeyPackagesClaim {
            identity_id: r.identity_id.clone(),
            device_id: r.device_id.clone(),
        })
        .await?
    {
        Payload::KeyPackageClaimed { key_package } => {
            MlsMessage::from_bytes(&key_package).map_err(err("key package"))
        }
        other => Err(CliError(format!("unexpected reply: {other:?}"))),
    }
}

/// The roster event: every member's route, this device's first.
fn roster_message<C: MlsConfig>(
    s: &Session,
    group: &mut Group<C>,
    peers: &[Peer],
) -> Result<Vec<u8>, CliError> {
    let mut routes = vec![own_route(s)?];
    routes.extend(peers.iter().filter_map(route_of_peer));
    group
        .encrypt_application_message(
            &encode_event("roster", routes.join("\n").as_bytes())?,
            Default::default(),
        )
        .map_err(err("mls encrypt"))?
        .to_bytes()
        .map_err(err("mls encode"))
}

fn single_conversation(s: &Session) -> Result<Conversation, CliError> {
    s.client
        .conversations()
        .map_err(err("conversations"))?
        .into_iter()
        .next()
        .ok_or_else(|| CliError("no conversation; run `chat start` or `chat sync` first".into()))
}

/// `arveil chat start --data-dir D <bootstrap> <peer-route>...`
pub fn start(data_dir: &Path, bootstrap: &str, peer_routes: &[&str]) -> Result<(), CliError> {
    let b = Bootstrap::parse(bootstrap)?;
    let peers: Vec<Route> = peer_routes
        .iter()
        .map(|r| parse_route(r))
        .collect::<Result<_, _>>()?;
    if peers.is_empty() {
        return Err(CliError("chat start needs at least one peer route".into()));
    }
    let (s, engine) = session(data_dir)?;

    block_on(async {
        let mut conn = connect(&s, &b).await?;
        let mut kps = Vec::new();
        for p in &peers {
            kps.push(claim_key_package(&mut conn, p).await?);
        }

        let mut group = engine.create_group().map_err(err("mls"))?;
        let mut cb = group.commit_builder();
        for kp in kps {
            cb = cb.add_member(kp).map_err(err("mls add"))?;
        }
        let commit = cb.build().map_err(err("mls commit"))?;
        group.apply_pending_commit().map_err(err("mls apply"))?;
        let conv = Conversation {
            group_id: group.group_id().to_vec(),
            creator: true,
            peers: peers.iter().map(peer_from_route).collect(),
        };
        let welcome = commit
            .welcome_messages
            .first()
            .ok_or_else(|| CliError("no welcome produced".into()))?
            .to_bytes()
            .map_err(err("welcome"))?;
        let roster = roster_message(&s, &mut group, &conv.peers)?;

        s.client
            .conn
            .unit_of_work(|_| {
                group
                    .write_to_storage()
                    .map_err(|_| rusqlite::Error::InvalidQuery)?;
                s.client
                    .conversation_save(&conv)
                    .map_err(|_| rusqlite::Error::InvalidQuery)?;
                enqueue_for_all(&s, &conv.peers, None, &welcome)?;
                enqueue_for_all(&s, &conv.peers, None, &roster)?;
                Ok::<_, rusqlite::Error>(())
            })
            .map_err(err("start unit"))?;
        println!(
            "conversation: {} created with {} peer(s) (epoch {})",
            hex::encode(&conv.group_id),
            conv.peers.len(),
            group.current_epoch()
        );
        let n = publish_pending(&s, &mut conn).await?;
        println!("published: {n} envelope(s)");
        conn.close().await;
        Ok(())
    })?
}

/// `arveil chat add --data-dir D <bootstrap> <peer-route>` (creator only)
pub fn add(data_dir: &Path, bootstrap: &str, peer_route: &str) -> Result<(), CliError> {
    let b = Bootstrap::parse(bootstrap)?;
    let newcomer = parse_route(peer_route)?;
    let (s, engine) = session(data_dir)?;
    let conv = single_conversation(&s)?;
    let mut group = engine.load_group(&conv.group_id).map_err(err("mls load"))?;

    block_on(async {
        let mut conn = connect(&s, &b).await?;
        let kp = claim_key_package(&mut conn, &newcomer).await?;
        // On a device that is not the lowest active leaf, the policy
        // refuses this before anything is produced.
        let commit = group
            .commit_builder()
            .add_member(kp)
            .map_err(err("mls add"))?
            .build()
            .map_err(err("mls commit"))?;
        group.apply_pending_commit().map_err(err("mls apply"))?;
        let new_peer = peer_from_route(&newcomer);
        let mut all = conv.clone();
        all.peers.push(new_peer.clone());
        let welcome = commit
            .welcome_messages
            .first()
            .ok_or_else(|| CliError("no welcome produced".into()))?
            .to_bytes()
            .map_err(err("welcome"))?;
        let commit_bytes = commit.commit_message.to_bytes().map_err(err("commit"))?;
        let roster = roster_message(&s, &mut group, &all.peers)?;

        s.client
            .conn
            .unit_of_work(|_| {
                group
                    .write_to_storage()
                    .map_err(|_| rusqlite::Error::InvalidQuery)?;
                s.client
                    .conversation_save(&all)
                    .map_err(|_| rusqlite::Error::InvalidQuery)?;
                enqueue_for_all(&s, &conv.peers, None, &commit_bytes)?;
                enqueue_for(&s, &new_peer, None, &welcome)?;
                enqueue_for_all(&s, &all.peers, None, &roster)?;
                Ok::<_, rusqlite::Error>(())
            })
            .map_err(err("add unit"))?;
        println!(
            "added: device {} of {} (epoch {})",
            hex::encode(&newcomer.device_id),
            hex::encode(&newcomer.identity_id[..4]),
            group.current_epoch()
        );
        let n = publish_pending(&s, &mut conn).await?;
        println!("published: {n} envelope(s)");
        conn.close().await;
        Ok(())
    })?
}

/// `arveil chat remove --data-dir D <bootstrap> <device-id>` (committer only)
///
/// Removes a leaf whose credential this device knows to be revoked, from a
/// manifest it verified under that identity's root. A device that is not
/// revoked is never removed this way: revocation is the authority, the
/// commit only enacts it.
pub fn remove(data_dir: &Path, bootstrap: &str, device_hex: &str) -> Result<(), CliError> {
    let b = Bootstrap::parse(bootstrap)?;
    let device_id = hex::decode(device_hex).map_err(err("device id"))?;
    let (s, engine) = session(data_dir)?;
    let conv = single_conversation(&s)?;
    if !conv
        .peers
        .iter()
        .any(|p| p.device_id == device_id && p.revoked)
    {
        return Err(CliError(
            "that device is not known to be revoked here; a verified manifest must say so first"
                .into(),
        ));
    }
    let mut group = engine.load_group(&conv.group_id).map_err(err("mls load"))?;
    let index = group
        .roster()
        .members()
        .into_iter()
        .find(|m| {
            m.signing_identity
                .credential
                .as_basic()
                .map(|c| c.identifier == device_id)
                .unwrap_or(false)
        })
        .map(|m| m.index)
        .ok_or_else(|| CliError("that device holds no leaf in this conversation".into()))?;

    block_on(async {
        let mut conn = connect(&s, &b).await?;
        let commit = group
            .commit_builder()
            .remove_member(index)
            .map_err(err("mls remove"))?
            .build()
            .map_err(err("mls commit"))?;
        group.apply_pending_commit().map_err(err("mls apply"))?;
        let bytes = commit.commit_message.to_bytes().map_err(err("commit"))?;
        s.client
            .conn
            .unit_of_work(|_| {
                group
                    .write_to_storage()
                    .map_err(|_| rusqlite::Error::InvalidQuery)?;
                enqueue_for_all(&s, &conv.peers, None, &bytes)
            })
            .map_err(err("remove unit"))?;
        println!(
            "removed: leaf {index} of device {} (epoch {})",
            hex::encode(&device_id),
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
    let conv = single_conversation(&s)?;
    let mut group = engine.load_group(&conv.group_id).map_err(err("mls load"))?;
    guard_revoked(&conv, &group)?;
    let event_id = random_delivery_id()?;

    // Send unit: nothing leaves the device before this commits.
    let fan = s
        .client
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
            enqueue_for_all(&s, &conv.peers, Some(&event_id), &bytes)
        })
        .map_err(err("send unit"))?;
    println!(
        "committed: message stored locally (epoch {}), {} envelope(s) queued{}",
        group.current_epoch(),
        fan.sent,
        fan.note()
    );

    if std::env::var_os("ARVEIL_CRASH_AFTER_COMMIT").is_some() {
        eprintln!("simulated crash after commit, before publishing");
        std::process::exit(3);
    }

    // Publishing is best effort: the message is already durable. A relay
    // that cannot be reached leaves it queued for the next send or sync.
    let outcome: Result<usize, CliError> = block_on(async {
        let mut conn = connect(&s, &b).await?;
        let n = publish_pending(&s, &mut conn).await?;
        conn.close().await;
        Ok(n)
    })?;
    match outcome {
        Ok(n) => println!("published: {n} envelope(s)"),
        Err(e) if e.0.starts_with("connect:") => {
            let pending = s.delivery.pending().map_err(err("outbox"))?.len();
            println!(
                "queued: relay unreachable ({e}); {pending} envelope(s) pending for the next sync"
            );
        }
        Err(e) => return Err(e),
    }
    Ok(())
}

/// Process one decrypted MLS message inside the receive unit.
fn handle_mls<C: MlsConfig>(
    s: &Session,
    engine: &Engine<C>,
    msg: MlsMessage,
    delivery_id: &[u8],
) -> Result<String, CliError> {
    match msg.wire_format() {
        WireFormat::Welcome => {
            let mut group = engine.join(&msg).map_err(err("mls join"))?;
            group.write_to_storage().map_err(err("mls persist"))?;
            s.client
                .conversation_save(&Conversation {
                    group_id: group.group_id().to_vec(),
                    creator: false,
                    peers: Vec::new(),
                })
                .map_err(err("conversation"))?;
            Ok(format!(
                "joined conversation {} (epoch {})",
                hex::encode(group.group_id()),
                group.current_epoch()
            ))
        }
        // Commits travel as PublicMessage; the HPKE envelope already hides
        // them from the relay, so both wire formats are handled alike.
        WireFormat::PrivateMessage | WireFormat::PublicMessage => {
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
                        "roster" => {
                            let text = String::from_utf8_lossy(&ev.body);
                            let mut peers = Vec::new();
                            for line in text.lines() {
                                let r = parse_route(line)?;
                                // Own other devices are peers; only this
                                // device itself is left out.
                                if r.device_id != s.device.keys.device_id {
                                    peers.push(peer_from_route(&r));
                                }
                            }
                            let n = peers.len();
                            s.client
                                .conversation_save(&Conversation {
                                    group_id: gid,
                                    creator: false,
                                    peers,
                                })
                                .map_err(err("conversation"))?;
                            Ok(format!(
                                "roster: {n} peer route(s) learned inside the group"
                            ))
                        }
                        "manifest" => {
                            // A manifest is accepted only under the root
                            // this device already stored for that identity,
                            // and only if it advances the known sequence.
                            let claimed =
                                arveil_core::identity::manifest_identity_unverified(&ev.body);
                            let (body, new) = match claimed {
                                Some(id) if id != s.identity_id => s
                                    .client
                                    .peer_manifest_accept(&id, &ev.body)
                                    .map_err(err("manifest"))?,
                                _ => s
                                    .client
                                    .manifest_accept_own(&ev.body)
                                    .map_err(err("manifest"))?,
                            };
                            Ok(format!(
                                "manifest {} for {}: {} active, {} revoked{}",
                                body.manifest_sequence,
                                hex::encode(&body.identity_id[..4]),
                                body.active_credential_hashes.len(),
                                body.revoked_credential_hashes.len(),
                                if new { "" } else { " (already known)" }
                            ))
                        }
                        "text" => {
                            s.delivery
                                .record_event(&gid, delivery_id, "received", &ev.body)
                                .map_err(err("event"))?;
                            Ok(format!("message: {}", String::from_utf8_lossy(&ev.body)))
                        }
                        "file" => {
                            let d = FileDescriptor::decode(&ev.body).map_err(err("file"))?;
                            s.delivery
                                .record_event(&gid, delivery_id, "file-pending", &ev.body)
                                .map_err(err("event"))?;
                            Ok(format!(
                                "file: {} ({} bytes) announced; downloading after this pass",
                                d.safe_name(),
                                d.size
                            ))
                        }
                        other => Ok(format!("event of kind {other} ignored")),
                    }
                }
                ReceivedMessage::Commit(c) => Ok(format!(
                    "commit from leaf {} applied (epoch {})",
                    c.committer,
                    group.current_epoch()
                )),
                other => Ok(format!("mls message {other:?} processed")),
            }
        }
        other => Err(CliError(format!("unexpected MLS wire format {other:?}"))),
    }
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
        let mut conn = connect(&s, &b).await?;
        let published = publish_pending(&s, &mut conn).await?;
        if published > 0 {
            println!("published: {published} pending envelope(s)");
        }
        // Revocations first: a commit that removes a revoked leaf is only
        // acceptable once this device has verified the manifest that
        // revoked it.
        refresh_manifests(&s, &mut conn).await?;
        let cursor = s.delivery.cursor(&m.mailbox_id).map_err(err("cursor"))? as u64;
        let (items, _fetched_next) = match conn
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

        // Envelopes are processed in sequence order. The first one that
        // cannot be processed stops the pass: later ones may depend on it
        // (a roster after a commit), and the cursor only advances past what
        // was processed or deduplicated, so the rest is retried next time.
        let mut new = 0;
        let mut advanced_to = cursor;
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
                handle_mls(&s, &engine, msg, &item.delivery_id).map(Some)
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
                Err(e) => {
                    println!(
                        "deferred: delivery {} could not be processed yet ({e}); retrying next sync",
                        hex::encode(&item.delivery_id)
                    );
                    break;
                }
            }
            advanced_to = item.seq;
        }
        let next = advanced_to;
        download_pending(&s, &mut conn, data_dir).await?;
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

/// Ask the relay for the newest manifest of every identity in this
/// device's conversations, including its own. The in-group copy catches a
/// relay that hides versions; this catches a group that has not carried the
/// manifest yet. Both are verified under the root already stored.
async fn refresh_manifests(s: &Session, conn: &mut Connection) -> Result<(), CliError> {
    let mut identities: Vec<Vec<u8>> = vec![s.identity_id.clone()];
    for c in s.client.conversations().map_err(err("conversations"))? {
        for p in c.peers {
            if !identities.contains(&p.identity) {
                identities.push(p.identity);
            }
        }
    }
    for id in identities {
        let signed = match conn
            .request(Payload::ManifestGet {
                identity_id: id.clone(),
            })
            .await?
        {
            Payload::ManifestLatest { manifest } => manifest,
            other => return Err(CliError(format!("unexpected reply: {other:?}"))),
        };
        if signed.is_empty() {
            continue;
        }
        let accepted = if id == s.identity_id {
            s.client.manifest_accept_own(&signed)
        } else {
            s.client.peer_manifest_accept(&id, &signed)
        };
        match accepted {
            Ok((body, true)) => println!(
                "manifest {} for {} from the realm: {} revoked device(s)",
                body.manifest_sequence,
                hex::encode(&id[..4]),
                body.revoked_credential_hashes.len()
            ),
            Ok((_, false)) => {}
            // A relay that serves an older or forked manifest is reported,
            // never applied (I-08).
            Err(e) => println!("manifest for {} refused: {e}", hex::encode(&id[..4])),
        }
    }
    Ok(())
}

/// `arveil device revoke --data-dir D <bootstrap> <device-id-hex>`
///
/// Signs manifest N+1 without that device, publishes it to the realm (which
/// refuses the device's handshake and revokes its capabilities), sends it as
/// a `manifest` event into every conversation, and, where this device is the
/// committer, removes the revoked leaf in the same pass.
pub fn revoke(data_dir: &Path, bootstrap: &str, device_hex: &str) -> Result<(), CliError> {
    let b = Bootstrap::parse(bootstrap)?;
    let device_id = hex::decode(device_hex).map_err(err("device id"))?;
    let (s, engine) = session(data_dir)?;
    let (manifest, hash) = s.client.device_revoke(&device_id).map_err(err("revoke"))?;
    println!(
        "revoked: device {} (credential {})",
        hex::encode(&device_id),
        hex::encode(&hash[..4])
    );

    block_on(async {
        let mut conn = connect(&s, &b).await?;
        match conn
            .request(Payload::ManifestPut {
                manifest: manifest.clone(),
            })
            .await?
        {
            Payload::Ack => println!("published: the realm refuses that device from now on"),
            other => return Err(CliError(format!("unexpected reply: {other:?}"))),
        }

        for conv in s.client.conversations().map_err(err("conversations"))? {
            let mut group = engine.load_group(&conv.group_id).map_err(err("mls load"))?;
            let in_group = roster_device_ids(&group).contains(&device_id);
            let committer = i_am_committer(&s, &group);
            let event = manifest_message(&mut group, &manifest)?;
            let removal = if in_group && committer {
                let index = group
                    .roster()
                    .members()
                    .into_iter()
                    .find(|m| {
                        m.signing_identity
                            .credential
                            .as_basic()
                            .map(|c| c.identifier == device_id)
                            .unwrap_or(false)
                    })
                    .map(|m| m.index)
                    .ok_or_else(|| CliError("revoked device not found in the roster".into()))?;
                let commit = group
                    .commit_builder()
                    .remove_member(index)
                    .map_err(err("mls remove"))?
                    .build()
                    .map_err(err("mls commit"))?;
                group.apply_pending_commit().map_err(err("mls apply"))?;
                Some(commit.commit_message.to_bytes().map_err(err("commit"))?)
            } else {
                None
            };
            s.client
                .conn
                .unit_of_work(|_| {
                    group
                        .write_to_storage()
                        .map_err(|_| rusqlite::Error::InvalidQuery)?;
                    enqueue_for_all(&s, &conv.peers, None, &event)?;
                    if let Some(bytes) = &removal {
                        enqueue_for_all(&s, &conv.peers, None, bytes)?;
                    }
                    Ok::<_, rusqlite::Error>(())
                })
                .map_err(err("revoke unit"))?;
            println!(
                "conversation {}: manifest sent{}",
                hex::encode(&conv.group_id[..4]),
                match (&removal, in_group) {
                    (Some(_), _) => format!(", leaf removed (epoch {})", group.current_epoch()),
                    (None, true) => ", removal left to the committer".into(),
                    (None, false) => String::new(),
                }
            );
        }
        let n = publish_pending(&s, &mut conn).await?;
        println!("published: {n} envelope(s)");
        conn.close().await;
        Ok(())
    })?
}

/// `arveil chat history --data-dir D`
pub fn history(data_dir: &Path) -> Result<(), CliError> {
    let (s, _engine) = session(data_dir)?;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    for conv in s.client.conversations().map_err(err("conversations"))? {
        println!(
            "conversation {} ({}), peers: {}",
            hex::encode(&conv.group_id),
            if conv.creator { "creator" } else { "member" },
            conv.peers
                .iter()
                .map(|p| format!(
                    "{}/{}{}{}",
                    hex::encode(&p.identity[..4]),
                    hex::encode(&p.device_id[..4]),
                    if p.identity == s.identity_id {
                        " (own)"
                    } else {
                        ""
                    },
                    if p.routable() { "" } else { " (no route)" }
                ))
                .collect::<Vec<_>>()
                .join(", ")
        );
        for (event_id, kind, body) in s.delivery.events(&conv.group_id).map_err(err("events"))? {
            println!("  [{kind:>8}] {}", String::from_utf8_lossy(&body));
            if kind == "sent" {
                for (mailbox, state) in s
                    .delivery
                    .states_for_event(&event_id, now)
                    .map_err(err("states"))?
                {
                    println!(
                        "             -> mailbox {}: {state}",
                        hex::encode(&mailbox[..4])
                    );
                }
            }
        }
    }
    Ok(())
}

const BLOB_CHUNK: usize = 60 * 1024;

fn blob_expiry() -> u64 {
    std::env::var("ARVEIL_BLOB_TTL_SECS")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .map(|ttl| {
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0)
                + ttl
        })
        .unwrap_or(0)
}

/// `arveil chat send-file --data-dir D <bootstrap> <path>`
///
/// Encrypts the whole file with a fresh FileKey, uploads the ciphertext in
/// chunks, commits it with its hash, then sends the descriptor inside MLS
/// exactly like a text message (same send unit, same fan-out).
pub fn send_file(data_dir: &Path, bootstrap: &str, path: &Path) -> Result<(), CliError> {
    let b = Bootstrap::parse(bootstrap)?;
    let (s, engine) = session(data_dir)?;
    let conv = single_conversation(&s)?;
    let plaintext = std::fs::read(path).map_err(err("read file"))?;
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "file".into());
    let enc = attachments::encrypt(&plaintext).map_err(err("encrypt"))?;

    let (blob_id, read_capability, expiry) = block_on(async {
        let mut conn = connect(&s, &b).await?;
        let (blob_id, read_capability) = match conn
            .request(Payload::BlobUploadBegin {
                size: enc.ciphertext.len() as u64,
            })
            .await?
        {
            Payload::BlobUploadStarted {
                blob_id,
                read_capability,
            } => (blob_id, read_capability),
            other => return Err(CliError(format!("unexpected reply: {other:?}"))),
        };
        for (i, chunk) in enc.ciphertext.chunks(BLOB_CHUNK).enumerate() {
            match conn
                .request(Payload::BlobChunk {
                    blob_id: blob_id.clone(),
                    offset: (i * BLOB_CHUNK) as u64,
                    data: chunk.to_vec(),
                })
                .await?
            {
                Payload::Ack => {}
                other => return Err(CliError(format!("unexpected reply: {other:?}"))),
            }
        }
        let expiry = match conn
            .request(Payload::BlobCommit {
                blob_id: blob_id.clone(),
                ciphertext_hash: enc.ciphertext_hash.clone(),
                requested_expiry: blob_expiry(),
            })
            .await?
        {
            Payload::BlobCommitted { effective_expiry } => effective_expiry,
            other => return Err(CliError(format!("unexpected reply: {other:?}"))),
        };
        conn.close().await;
        Ok((blob_id, read_capability, expiry))
    })??;
    println!(
        "blob: {} uploaded ({} bytes of ciphertext, relay keeps it until {expiry})",
        hex::encode(&blob_id),
        enc.ciphertext.len()
    );

    let descriptor = FileDescriptor {
        version: attachments::VERSION,
        blob_id,
        read_capability,
        file_key: enc.file_key,
        nonce: enc.nonce,
        ciphertext_hash: enc.ciphertext_hash,
        size: plaintext.len() as u64,
        name: name.clone(),
        mime: "application/octet-stream".into(),
    };
    let body = descriptor.encode().map_err(err("descriptor"))?;
    let mut group = engine.load_group(&conv.group_id).map_err(err("mls load"))?;
    guard_revoked(&conv, &group)?;
    let event_id = random_delivery_id()?;
    let fan = s
        .client
        .conn
        .unit_of_work(|_| {
            let msg = group
                .encrypt_application_message(
                    &encode_event("file", &body).map_err(|_| rusqlite::Error::InvalidQuery)?,
                    Default::default(),
                )
                .map_err(|_| rusqlite::Error::InvalidQuery)?;
            group
                .write_to_storage()
                .map_err(|_| rusqlite::Error::InvalidQuery)?;
            s.delivery.record_event(
                &conv.group_id,
                &event_id,
                "sent-file",
                format!("{name} ({} bytes)", plaintext.len()).as_bytes(),
            )?;
            let bytes = msg.to_bytes().map_err(|_| rusqlite::Error::InvalidQuery)?;
            enqueue_for_all(&s, &conv.peers, Some(&event_id), &bytes)
        })
        .map_err(err("send unit"))?;
    println!(
        "committed: file descriptor stored locally, {} envelope(s) queued{}",
        fan.sent,
        fan.note()
    );
    let n = block_on(async {
        let mut conn = connect(&s, &b).await?;
        let n = publish_pending(&s, &mut conn).await?;
        conn.close().await;
        Ok::<_, CliError>(n)
    })??;
    println!("published: {n} envelope(s)");
    Ok(())
}

/// Download every announced file, verify hash and AEAD, write it under
/// `<data-dir>/downloads`, and record the outcome as an event. An expired
/// or unknown blob becomes a visible `file-unavailable` event, never a
/// silent skip.
async fn download_pending(
    s: &Session,
    conn: &mut Connection,
    data_dir: &Path,
) -> Result<(), CliError> {
    let pending = s
        .delivery
        .events_of_kind("file-pending")
        .map_err(err("events"))?;
    if pending.is_empty() {
        return Ok(());
    }
    let dir = data_dir.join("downloads");
    std::fs::create_dir_all(&dir).map_err(err("downloads dir"))?;
    for (event_id, _, body) in pending {
        let d = match FileDescriptor::decode(&body) {
            Ok(d) => d,
            Err(e) => {
                s.delivery
                    .update_event(
                        &event_id,
                        "file-unavailable",
                        format!("bad descriptor: {e}").as_bytes(),
                    )
                    .map_err(err("event"))?;
                continue;
            }
        };
        let mut ciphertext = Vec::new();
        let mut failure: Option<String> = None;
        loop {
            match conn
                .request(Payload::BlobFetch {
                    blob_id: d.blob_id.clone(),
                    read_capability: d.read_capability.clone(),
                    offset: ciphertext.len() as u64,
                    length: BLOB_CHUNK as u32,
                })
                .await
            {
                Ok(Payload::BlobData { total_size, data }) => {
                    if data.is_empty() {
                        break;
                    }
                    ciphertext.extend_from_slice(&data);
                    if ciphertext.len() as u64 >= total_size {
                        break;
                    }
                }
                Ok(other) => {
                    failure = Some(format!("unexpected reply {other:?}"));
                    break;
                }
                Err(e) => {
                    failure = Some(e.0);
                    break;
                }
            }
        }
        let outcome = match failure {
            Some(reason) => Err(reason),
            None => attachments::decrypt(&d, &ciphertext)
                .map_err(|e| e.to_string())
                .and_then(|plain| {
                    let target = dir.join(d.safe_name());
                    std::fs::write(&target, &plain)
                        .map(|_| target)
                        .map_err(|e| e.to_string())
                }),
        };
        match outcome {
            Ok(target) => {
                s.delivery
                    .update_event(
                        &event_id,
                        "received-file",
                        target.to_string_lossy().as_bytes(),
                    )
                    .map_err(err("event"))?;
                println!("file: {} saved to {}", d.safe_name(), target.display());
            }
            Err(reason) => {
                s.delivery
                    .update_event(
                        &event_id,
                        "file-unavailable",
                        format!("{} ({reason})", d.safe_name()).as_bytes(),
                    )
                    .map_err(err("event"))?;
                println!("file unavailable: {} ({reason})", d.safe_name());
            }
        }
    }
    Ok(())
}
