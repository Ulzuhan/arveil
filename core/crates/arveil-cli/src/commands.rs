//! Phase 0 commands: identity, enrollment, probe, status.

use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use arveil_core::channel::StaticKeypair;
use arveil_core::channel::codec::Payload;
use arveil_core::client::Client;
use arveil_core::mls::MlsIdentity;
use arveil_core::storage::SharedConn;

use crate::carrier::{Bootstrap, CliError, Connection, block_on, err};

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn open_client(data_dir: &Path) -> Result<Client, CliError> {
    std::fs::create_dir_all(data_dir).map_err(err("data dir"))?;
    let conn = SharedConn::open_file(&data_dir.join("client.db")).map_err(err("storage"))?;
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
        None => {
            let mls = MlsIdentity::generate("device").map_err(err("mls identity"))?;
            let public = mls.signing_identity.signature_key.to_vec();
            let secret = mls.secret.as_bytes().to_vec();
            c.device_new(secret, public, now()).map_err(err("device"))?
        }
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
        conn.close().await;
        Ok(())
    })?
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
        conn.close().await;
        println!("probe ok");
        Ok(())
    })?
}

/// `arveil status --data-dir D`
pub fn status(data_dir: &Path) -> Result<(), CliError> {
    let c = open_client(data_dir)?;
    match c.root().map_err(err("identity"))? {
        Some(root) => println!("identity: {}", hex::encode(root.identity_id())),
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
