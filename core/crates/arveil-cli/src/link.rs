//! Phase 2 (M2.1) device linking without the root leaving the
//! administration device (PROTOCOL §8, ADR-005).
//!
//! ```text
//! new device    : device request            -> arveil-link-request:v0:...
//! admin device  : device authorize <request> -> signs credential + manifest N+1,
//!                                              publishes both, prints a grant
//! new device    : device link <grant>       -> verifies it names its own keys,
//!                                              enrolls as a member, prints its route
//! ```
//!
//! The request carries public keys only; the grant carries signed public
//! objects only. Copying them over a channel the user trusts stands in for
//! the pairing protocol until Phase 3.

use std::path::Path;

use arveil_core::channel::codec::Payload;
use arveil_core::identity::DevicePublicKeys;
use serde::{Deserialize, Serialize};

use crate::carrier::{Bootstrap, CliError, Connection, block_on, err};
use crate::commands::{finish_enrollment, now, open_client};

#[derive(Serialize, Deserialize)]
struct Grant {
    #[serde(with = "serde_bytes")]
    credential: Vec<u8>,
    #[serde(with = "serde_bytes")]
    manifest: Vec<u8>,
    #[serde(with = "serde_bytes")]
    root_public: Vec<u8>,
}

fn request_string(p: &DevicePublicKeys) -> String {
    format!(
        "arveil-link-request:v0:{}:{}:{}:{}",
        hex::encode(&p.device_id),
        hex::encode(&p.mls_signature_public_key),
        hex::encode(&p.transport_noise_public_key),
        hex::encode(&p.envelope_hpke_public_key)
    )
}

fn parse_request(s: &str) -> Result<DevicePublicKeys, CliError> {
    let parts: Vec<&str> = s.split(':').collect();
    if parts.len() != 6 || parts[0] != "arveil-link-request" || parts[1] != "v0" {
        return Err(CliError("not an arveil-link-request:v0 string".into()));
    }
    Ok(DevicePublicKeys {
        device_id: hex::decode(parts[2]).map_err(err("device id"))?,
        mls_signature_public_key: hex::decode(parts[3]).map_err(err("mls key"))?,
        transport_noise_public_key: hex::decode(parts[4]).map_err(err("noise key"))?,
        envelope_hpke_public_key: hex::decode(parts[5]).map_err(err("hpke key"))?,
    })
}

fn parse_grant(s: &str) -> Result<Grant, CliError> {
    let rest = s
        .strip_prefix("arveil-link-grant:v0:")
        .ok_or_else(|| CliError("not an arveil-link-grant:v0 string".into()))?;
    let bytes = hex::decode(rest).map_err(err("grant"))?;
    ciborium::from_reader(bytes.as_slice()).map_err(err("grant"))
}

/// `arveil device request --data-dir NEW`
pub fn request(data_dir: &Path) -> Result<(), CliError> {
    let c = open_client(data_dir)?;
    let d = c.device_pending_new().map_err(err("device"))?;
    println!(
        "device: {} (keys generated, not yet linked)",
        hex::encode(d.keys.device_id)
    );
    println!("request: {}", request_string(&d.keys.public()));
    Ok(())
}

/// `arveil device authorize --data-dir ADMIN <bootstrap> <link-request>`
pub fn authorize(data_dir: &Path, bootstrap: &str, request: &str) -> Result<(), CliError> {
    let b = Bootstrap::parse(bootstrap)?;
    let public = parse_request(request)?;
    let (c, admin, _realm) = crate::commands::enrolled(data_dir)?;
    let (credential, manifest) = c
        .device_authorize(&public, now())
        .map_err(err("authorize"))?;
    let seq = c
        .manifest_state()
        .map_err(err("manifest"))?
        .map(|m| m.sequence)
        .unwrap_or(0);
    println!(
        "signed: credential for device {} and manifest {seq}",
        hex::encode(&public.device_id)
    );
    let root_public = c
        .root_public()
        .map_err(err("identity"))?
        .ok_or_else(|| CliError("no identity".into()))?
        .as_bytes()
        .to_vec();
    block_on(async {
        let mut conn = Connection::open(
            &b.url,
            &b.realm_id,
            &b.noise_public,
            &admin.keys.transport_noise,
        )
        .await?;
        // Manifest first: the relay accepts a credential only once the newest
        // manifest lists it active, so a linked device is never a surprise.
        match conn
            .request(Payload::ManifestPut {
                manifest: manifest.clone(),
            })
            .await?
        {
            Payload::Ack => println!("published: manifest {seq}"),
            other => return Err(CliError(format!("unexpected reply: {other:?}"))),
        }
        match conn
            .request(Payload::CredentialPut {
                credential: credential.clone(),
            })
            .await?
        {
            Payload::Ack => println!("published: credential registered by the relay"),
            other => return Err(CliError(format!("unexpected reply: {other:?}"))),
        }
        conn.close().await;
        Ok::<_, CliError>(())
    })??;
    let grant = arveil_core::signed::canonical(&Grant {
        credential,
        manifest,
        root_public,
    })
    .map_err(err("grant"))?;
    println!("grant: arveil-link-grant:v0:{}", hex::encode(grant));
    Ok(())
}

/// `arveil device link --data-dir NEW <bootstrap> <link-grant>`
pub fn link(data_dir: &Path, bootstrap: &str, grant: &str) -> Result<(), CliError> {
    let b = Bootstrap::parse(bootstrap)?;
    let g = parse_grant(grant)?;
    let c = open_client(data_dir)?;
    let identity_id = c
        .device_link_complete(&g.credential, &g.manifest, &g.root_public, now())
        .map_err(err("link"))?;
    let device = c
        .device()
        .map_err(err("device"))?
        .ok_or_else(|| CliError("no device".into()))?;
    println!(
        "linked: device {} now belongs to identity {}",
        hex::encode(device.keys.device_id),
        hex::encode(&identity_id)
    );
    c.realm_save(&b.realm_id, &b.signing_key, &b.noise_public, &b.url)
        .map_err(err("realm"))?;
    block_on(async {
        // A member handshake from the first byte: the relay already knows
        // this Noise key from the administration device's credential_put.
        let mut conn = Connection::open(
            &b.url,
            &b.realm_id,
            &b.noise_public,
            &device.keys.transport_noise,
        )
        .await?;
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
        Ok::<_, CliError>(())
    })?
}
