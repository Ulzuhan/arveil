//! Phase 0 commands: identity, enrollment, probe, status.

use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use arveil_core::channel::StaticKeypair;
use arveil_core::channel::codec::Payload;
use arveil_core::client::{Client, OwnMailbox, StoredDevice};
use arveil_core::delivery::Delivery;
use arveil_core::envelope::{self, EnvelopeContext};
use arveil_core::mls;
use arveil_core::storage::SharedConn;

/// Phase 0 CLI payload kind: plain text without MLS. The chat demo (M0.6)
/// replaces it with `envelope::KIND_MLS`.
const KIND_PLAIN_TEXT: u8 = 250;

use crate::carrier::{Bootstrap, CliError, Connection, block_on, err};

pub fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// The key that encrypts this device's database at rest, if the operator
/// set one. Arveil never stores it: losing it loses the local history.
pub fn db_key() -> Option<String> {
    std::env::var("ARVEIL_DB_KEY")
        .ok()
        .filter(|k| !k.is_empty())
}

pub fn open_client(data_dir: &Path) -> Result<Client, CliError> {
    std::fs::create_dir_all(data_dir).map_err(err("data dir"))?;
    let conn = SharedConn::open_file_keyed(&data_dir.join("client.db"), db_key().as_deref())
        .map_err(err("storage"))?;
    Client::open(conn).map_err(err("client"))
}

/// `arveil identity new --data-dir D`
pub fn identity_new(data_dir: &Path) -> Result<(), CliError> {
    let c = open_client(data_dir)?;
    let root = c.identity_new().map_err(err("identity"))?;
    println!("identity: {}", hex::encode(root.identity_id()));
    Ok(())
}

/// `arveil enroll --data-dir D <bootstrap> <invite-token-hex>`
///
/// Creates the device keys and credential under the local root, opens a
/// provisional channel with the device's Noise key, redeems the invite with
/// credential and first manifest, and stores the realm and its endpoint list.
pub fn enroll(data_dir: &Path, bootstrap: &str, invite_hex: &str) -> Result<(), CliError> {
    let b = Bootstrap::parse(bootstrap)?;
    let token = hex::decode(invite_hex).map_err(err("invite token"))?;
    let c = open_client(data_dir)?;
    if c.root().map_err(err("identity"))?.is_none() {
        let root = c.identity_new().map_err(err("identity"))?;
        println!("identity: {} (created)", hex::encode(root.identity_id()));
    }
    let (device, manifest) = match c.device().map_err(err("device"))? {
        Some(d) => {
            let m = c
                .latest_manifest()
                .map_err(err("manifest"))?
                .ok_or_else(|| CliError("device without manifest".into()))?;
            (d, m)
        }
        None => c.device_new(now()).map_err(err("device"))?,
    };
    c.realm_save(&b.realm_id, &b.signing_key, &b.noise_public, &b.url)
        .map_err(err("realm"))?;
    println!("device: {}", hex::encode(device.keys.device_id));

    block_on(async {
        let mut conn = Connection::open(
            &b.url,
            &b.realm_id,
            &b.noise_public,
            &device.keys.transport_noise,
        )
        .await?;
        match conn
            .request(Payload::InviteRedeem {
                token,
                credential: device.credential.clone(),
                manifest,
            })
            .await?
        {
            Payload::InviteRedeemed { identity_id } => {
                println!(
                    "enrolled: identity {} accepted by the realm",
                    hex::encode(identity_id)
                );
            }
            other => return Err(CliError(format!("unexpected reply: {other:?}"))),
        }
        match conn.request(Payload::EndpointListGet).await? {
            Payload::EndpointList { signed } => {
                let list = c
                    .realm_accept_endpoint_list(&b.realm_id, &signed)
                    .map_err(err("endpoint list"))?;
                println!("endpoint list: sequence {} stored", list.sequence);
            }
            other => return Err(CliError(format!("unexpected reply: {other:?}"))),
        }
        c.realm_mark_enrolled(&b.realm_id).map_err(err("realm"))?;
        finish_enrollment(&c, &mut conn, &device).await?;
        conn.close().await;
        Ok(())
    })?
}

/// After the realm accepted the device: a mailbox and a first batch of
/// KeyPackages right away, so the contact card can be printed.
pub async fn finish_enrollment(
    c: &Client,
    conn: &mut Connection,
    device: &arveil_core::client::StoredDevice,
) -> Result<(), CliError> {
    let m = match conn.request(Payload::MailboxCreate).await? {
        Payload::MailboxCreated {
            mailbox_id,
            read_capability,
            write_capability,
        } => {
            let m = OwnMailbox {
                mailbox_id,
                read_capability,
                write_capability,
            };
            c.mailbox_save(&m).map_err(err("mailbox"))?;
            m
        }
        other => return Err(CliError(format!("unexpected reply: {other:?}"))),
    };
    let engine = mls::open(c.conn.clone(), device.mls_identity());
    let mut key_packages = Vec::new();
    for _ in 0..5 {
        let kp = engine.key_package().map_err(err("key package"))?;
        key_packages.push(serde_bytes::ByteBuf::from(
            kp.to_bytes().map_err(err("key package"))?,
        ));
    }
    match conn
        .request(Payload::KeyPackagesPublish { key_packages })
        .await?
    {
        Payload::Ack => println!("key packages: 5 published"),
        other => return Err(CliError(format!("unexpected reply: {other:?}"))),
    }
    println!("route: {}", route_string(c, device, &m)?);
    Ok(())
}

/// `arveil probe [--data-dir D] <bootstrap>`: with a data dir, connect as
/// the enrolled device; otherwise with a throwaway key (provisional session).
pub fn probe(data_dir: Option<&Path>, bootstrap: &str) -> Result<(), CliError> {
    let b = Bootstrap::parse(bootstrap)?;
    let (device, label) = match data_dir {
        Some(dir) => {
            let c = open_client(dir)?;
            let d = c
                .device()
                .map_err(err("device"))?
                .ok_or_else(|| CliError("no enrolled device in this data dir".into()))?;
            (d.keys.transport_noise, "enrolled device")
        }
        None => (
            StaticKeypair::generate().map_err(err("keygen"))?,
            "throwaway key (provisional session)",
        ),
    };
    block_on(async {
        let mut conn = Connection::open(&b.url, &b.realm_id, &b.noise_public, &device).await?;
        println!(
            "channel: established as {label}; realm noise key {}",
            hex::encode(conn.channel.remote_static())
        );
        match conn.request(Payload::EndpointListGet).await? {
            Payload::EndpointList { signed } => {
                let list = arveil_core::channel::endpoints::verify(
                    &signed,
                    &b.signing_key,
                    &b.realm_id,
                    None,
                )
                .map_err(err("endpoint list"))?;
                if list.realm_noise_public_key != b.noise_public {
                    return Err(CliError(
                        "endpoint list advertises a different noise key than the bootstrap".into(),
                    ));
                }
                println!("endpoint list: sequence {}, signature valid", list.sequence);
                for e in &list.endpoints {
                    println!("  {:<8} priority {} {}", e.kind, e.priority, e.url);
                }
            }
            other => return Err(CliError(format!("unexpected reply: {other:?}"))),
        }
        match conn.request(Payload::Ping).await? {
            Payload::Pong => println!("ping: pong"),
            other => return Err(CliError(format!("expected pong, got {other:?}"))),
        }
        // A member session may publish; a provisional one must be refused.
        let manifest_put = conn
            .request(Payload::ManifestPut {
                manifest: vec![0xde, 0xad],
            })
            .await;
        match (data_dir.is_some(), manifest_put) {
            (true, Err(e)) if e.0.contains("(401)") => {
                println!("manifest_put: rejected as expected (garbage manifest)")
            }
            (false, Err(e)) if e.0.contains("(401)") => {
                println!("manifest_put: refused on provisional session, as expected")
            }
            (_, r) => return Err(CliError(format!("unexpected manifest_put outcome: {r:?}"))),
        }
        // Delivery frames: members need a valid capability; provisional
        // sessions are refused outright.
        let put = conn
            .request(Payload::EnvelopePut {
                mailbox_id: vec![0; 16],
                write_capability: vec![0; 32],
                delivery_id: vec![1; 16],
                requested_expiry: 0,
                hpke_enc: vec![0; 32],
                ciphertext: vec![0; 32],
            })
            .await;
        match (data_dir.is_some(), put) {
            (true, Err(e)) if e.0.contains("(403)") => {
                println!("envelope_put: rejected as expected (unknown capability)")
            }
            (false, Err(e)) if e.0.contains("(401)") => {
                println!("envelope_put: refused on provisional session, as expected")
            }
            (_, r) => return Err(CliError(format!("unexpected envelope_put outcome: {r:?}"))),
        }
        conn.close().await;
        println!("probe ok");
        Ok(())
    })?
}

/// `arveil status --data-dir D`
pub fn status(data_dir: &Path) -> Result<(), CliError> {
    let c = open_client(data_dir)?;
    match c.identity_id().map_err(err("identity"))? {
        Some(id) => println!(
            "identity: {} ({})",
            hex::encode(id),
            if c.root().map_err(err("identity"))?.is_some() {
                "root key on this device"
            } else {
                "linked device, no root key"
            }
        ),
        None => println!("identity: none"),
    }
    match c.device().map_err(err("device"))? {
        Some(d) => println!(
            "device:   {} (noise {})",
            hex::encode(d.keys.device_id),
            hex::encode(&d.keys.transport_noise.public)
        ),
        None => println!("device:   none"),
    }
    println!(
        "database: {}",
        if db_key().is_some() {
            "encrypted at rest with ARVEIL_DB_KEY (SQLCipher)"
        } else {
            "NOT encrypted at rest; set ARVEIL_DB_KEY to a 64-hex-character key"
        }
    );
    match c.realm().map_err(err("realm"))? {
        Some(r) => {
            println!(
                "realm:    {} enrolled={} url={}",
                hex::encode(&r.realm_id),
                r.enrolled,
                r.bootstrap_url
            );
            if let Some(list) = r.endpoint_list {
                for e in list.endpoints {
                    println!("  {:<8} priority {} {}", e.kind, e.priority, e.url);
                }
            }
        }
        None => println!("realm:    none"),
    }
    Ok(())
}

pub fn data_dir_arg(args: &[String]) -> (Option<PathBuf>, Vec<String>) {
    let mut dir = None;
    let mut rest = Vec::new();
    let mut i = 0;
    while i < args.len() {
        if args[i] == "--data-dir" && i + 1 < args.len() {
            dir = Some(PathBuf::from(&args[i + 1]));
            i += 2;
        } else {
            rest.push(args[i].clone());
            i += 1;
        }
    }
    (dir, rest)
}

/// `arveil-route:v1:<identity_id>:<device_id>:<credential_hash>:<root_public>:<mailbox_id>:<write_capability>:<hpke_public>`:
/// the contact card a peer needs to claim this device's KeyPackage, deliver
/// to it, and later verify manifests of its identity (PROTOCOL §4). Exchanged
/// out of band for the first contact; inside MLS-protected roster events
/// once a group exists.
pub fn route_string(c: &Client, d: &StoredDevice, m: &OwnMailbox) -> Result<String, CliError> {
    let identity_id = c
        .identity_id()
        .map_err(err("identity"))?
        .ok_or_else(|| CliError("no identity".into()))?;
    let root_public = c
        .root_public()
        .map_err(err("identity"))?
        .ok_or_else(|| CliError("no identity".into()))?;
    Ok(format!(
        "arveil-route:v1:{}:{}:{}:{}:{}:{}:{}",
        hex::encode(identity_id),
        hex::encode(d.keys.device_id),
        hex::encode(&d.credential_hash),
        hex::encode(root_public.as_bytes()),
        hex::encode(&m.mailbox_id),
        hex::encode(&m.write_capability),
        hex::encode(&d.keys.envelope_hpke.public)
    ))
}

pub struct Route {
    pub identity_id: Vec<u8>,
    pub device_id: Vec<u8>,
    pub credential_hash: Vec<u8>,
    pub root_public: Vec<u8>,
    pub mailbox_id: Vec<u8>,
    pub write_capability: Vec<u8>,
    pub hpke_public: Vec<u8>,
}

pub fn parse_route(s: &str) -> Result<Route, CliError> {
    let parts: Vec<&str> = s.split(':').collect();
    if parts.len() != 9 || parts[0] != "arveil-route" || parts[1] != "v1" {
        return Err(CliError("not an arveil-route:v1 string".into()));
    }
    let r = Route {
        identity_id: hex::decode(parts[2]).map_err(err("identity id"))?,
        device_id: hex::decode(parts[3]).map_err(err("device id"))?,
        credential_hash: hex::decode(parts[4]).map_err(err("credential hash"))?,
        root_public: hex::decode(parts[5]).map_err(err("root key"))?,
        mailbox_id: hex::decode(parts[6]).map_err(err("mailbox id"))?,
        write_capability: hex::decode(parts[7]).map_err(err("write capability"))?,
        hpke_public: hex::decode(parts[8]).map_err(err("hpke key"))?,
    };
    // The identity id must derive from the root key the route names.
    let pk: [u8; 32] = r
        .root_public
        .as_slice()
        .try_into()
        .map_err(|_| CliError("route: root key length".into()))?;
    let vk = ed25519_dalek::VerifyingKey::from_bytes(&pk).map_err(err("route: root key"))?;
    if arveil_core::identity::identity_id(&vk) != r.identity_id {
        return Err(CliError(
            "route: identity id does not derive from its root key".into(),
        ));
    }
    Ok(r)
}

pub fn enrolled(
    data_dir: &Path,
) -> Result<
    (
        Client,
        arveil_core::client::StoredDevice,
        arveil_core::client::StoredRealm,
    ),
    CliError,
> {
    let c = open_client(data_dir)?;
    let d = c
        .device()
        .map_err(err("device"))?
        .ok_or_else(|| CliError("no enrolled device in this data dir".into()))?;
    let r = c
        .realm()
        .map_err(err("realm"))?
        .filter(|r| r.enrolled)
        .ok_or_else(|| CliError("not enrolled in a realm".into()))?;
    Ok((c, d, r))
}

pub fn random_delivery_id() -> Result<Vec<u8>, CliError> {
    let mut id = [0u8; 16];
    getrandom::fill(&mut id).map_err(err("random"))?;
    Ok(id.to_vec())
}

/// `arveil mailbox create --data-dir D <bootstrap>`
pub fn mailbox_create(data_dir: &Path, bootstrap: &str) -> Result<(), CliError> {
    let b = Bootstrap::parse(bootstrap)?;
    let (c, d, _) = enrolled(data_dir)?;
    if let Some(m) = c.mailbox_own().map_err(err("mailbox"))? {
        println!("route: {}", route_string(&c, &d, &m)?);
        return Ok(());
    }
    block_on(async {
        let mut conn = Connection::open(
            &b.url,
            &b.realm_id,
            &b.noise_public,
            &d.keys.transport_noise,
        )
        .await?;
        match conn.request(Payload::MailboxCreate).await? {
            Payload::MailboxCreated {
                mailbox_id,
                read_capability,
                write_capability,
            } => {
                let m = OwnMailbox {
                    mailbox_id,
                    read_capability,
                    write_capability,
                };
                c.mailbox_save(&m).map_err(err("mailbox"))?;
                println!("mailbox: {} created", hex::encode(&m.mailbox_id));
                println!("route: {}", route_string(&c, &d, &m)?);
            }
            other => return Err(CliError(format!("unexpected reply: {other:?}"))),
        }
        conn.close().await;
        Ok(())
    })?
}

/// `arveil send --data-dir D <bootstrap> <route> <text>`: seal, enqueue in
/// the send unit of work, then publish everything pending.
pub fn send(data_dir: &Path, bootstrap: &str, route: &str, text: &str) -> Result<(), CliError> {
    let b = Bootstrap::parse(bootstrap)?;
    let r = parse_route(route)?;
    let (c, d, realm) = enrolled(data_dir)?;
    let delivery = Delivery::open(c.conn.clone()).map_err(err("delivery"))?;

    let delivery_id = random_delivery_id()?;
    let ctx = EnvelopeContext::new(&realm.realm_id, &r.mailbox_id, &delivery_id);
    let sealed = envelope::seal(&r.hpke_public, &ctx, KIND_PLAIN_TEXT, text.as_bytes())
        .map_err(err("seal"))?;
    c.conn
        .unit_of_work(|_| {
            delivery.record_event(&r.mailbox_id, &delivery_id, "sent", text.as_bytes())?;
            delivery.enqueue(
                &r.mailbox_id,
                &delivery_id,
                Some(&delivery_id),
                &sealed.enc,
                &sealed.ciphertext,
            )
        })
        .map_err(err("send unit"))?;
    println!("queued: delivery {}", hex::encode(&delivery_id));

    let pending = delivery.pending().map_err(err("outbox"))?;
    block_on(async {
        let mut conn = Connection::open(
            &b.url,
            &b.realm_id,
            &b.noise_public,
            &d.keys.transport_noise,
        )
        .await?;
        for row in pending {
            delivery.mark_attempt(row.id).map_err(err("outbox"))?;
            match conn
                .request(Payload::EnvelopePut {
                    mailbox_id: row.mailbox_id.clone(),
                    write_capability: r.write_capability.clone(),
                    delivery_id: row.delivery_id.clone(),
                    requested_expiry: 0,
                    hpke_enc: row.hpke_enc.clone(),
                    ciphertext: row.ciphertext.clone(),
                })
                .await?
            {
                Payload::EnvelopeAccepted { effective_expiry } => {
                    delivery
                        .mark_accepted(row.id, Some(effective_expiry as i64))
                        .map_err(err("outbox"))?;
                    println!(
                        "accepted: delivery {} (expires {effective_expiry})",
                        hex::encode(&row.delivery_id)
                    );
                }
                other => return Err(CliError(format!("unexpected reply: {other:?}"))),
            }
        }
        conn.close().await;
        Ok(())
    })?
}

/// `arveil fetch --data-dir D <bootstrap>`: page the own mailbox, run the
/// receive unit per envelope, then ACK what is durably stored.
pub fn fetch(data_dir: &Path, bootstrap: &str) -> Result<(), CliError> {
    let b = Bootstrap::parse(bootstrap)?;
    let (c, d, realm) = enrolled(data_dir)?;
    let m = c
        .mailbox_own()
        .map_err(err("mailbox"))?
        .ok_or_else(|| CliError("no mailbox; run `mailbox create` first".into()))?;
    let delivery = Delivery::open(c.conn.clone()).map_err(err("delivery"))?;

    block_on(async {
        let mut conn = Connection::open(
            &b.url,
            &b.realm_id,
            &b.noise_public,
            &d.keys.transport_noise,
        )
        .await?;
        let cursor = delivery.cursor(&m.mailbox_id).map_err(err("cursor"))? as u64;
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
        let mut received = 0;
        for item in &items {
            let ctx = EnvelopeContext::new(&realm.realm_id, &m.mailbox_id, &item.delivery_id);
            let outcome: Result<Option<Vec<u8>>, rusqlite::Error> = c.conn.unit_of_work(|_| {
                if !delivery.record_incoming(&m.mailbox_id, &item.delivery_id, item.seq as i64)? {
                    return Ok(None);
                }
                let inner = envelope::open(
                    &d.keys.envelope_hpke.private,
                    &ctx,
                    &envelope::Sealed {
                        enc: item.hpke_enc.clone(),
                        ciphertext: item.ciphertext.clone(),
                    },
                )
                .map_err(|_| rusqlite::Error::InvalidQuery)?;
                delivery.record_event(
                    &m.mailbox_id,
                    &item.delivery_id,
                    "received",
                    &inner.payload,
                )?;
                Ok(Some(inner.payload))
            });
            match outcome {
                Ok(Some(text)) => {
                    received += 1;
                    println!("message: {}", String::from_utf8_lossy(&text));
                }
                Ok(None) => println!(
                    "duplicate: delivery {} ignored",
                    hex::encode(&item.delivery_id)
                ),
                Err(_) => println!(
                    "undecryptable: delivery {} left unacked",
                    hex::encode(&item.delivery_id)
                ),
            }
        }
        let unacked = delivery.unacked(&m.mailbox_id).map_err(err("inbox"))?;
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
                Payload::Ack => delivery
                    .mark_acked(&m.mailbox_id, &unacked)
                    .map_err(err("inbox"))?,
                other => return Err(CliError(format!("unexpected reply: {other:?}"))),
            }
        }
        delivery
            .set_cursor(&m.mailbox_id, next as i64)
            .map_err(err("cursor"))?;
        println!(
            "fetched: {} envelope(s), {received} new, {} acked",
            items.len(),
            unacked.len()
        );
        conn.close().await;
        Ok(())
    })?
}
