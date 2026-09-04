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

// ---------------------------------------------------------------------------
// M3.1: pairing over a live channel
// ---------------------------------------------------------------------------

use arveil_core::channel::noise::{Initiator, Responder, prologue};
use arveil_core::pairing::{
    self, PairedDeviceKeys, PairingCode, PairingGrant, SLOT_GRANT, SLOT_HANDSHAKE_1,
    SLOT_HANDSHAKE_2,
};

/// How long a device waits for the other side before giving up.
fn pair_timeout() -> std::time::Duration {
    let secs = std::env::var("ARVEIL_PAIR_TIMEOUT_SECS")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(90);
    std::time::Duration::from_secs(secs)
}

/// Poll one rendezvous slot until it holds something, or give up.
async fn wait_for_slot(
    conn: &mut Connection,
    code: &PairingCode,
    slot: &str,
    what: &str,
) -> Result<Vec<u8>, CliError> {
    let deadline = std::time::Instant::now() + pair_timeout();
    loop {
        match conn
            .request(Payload::PairGet {
                pair_id: code.pair_id.clone(),
                capability: code.capability.clone(),
                slot: slot.to_string(),
            })
            .await?
        {
            Payload::PairFetched { data } if !data.is_empty() => return Ok(data),
            Payload::PairFetched { .. } => {}
            other => return Err(CliError(format!("unexpected reply: {other:?}"))),
        }
        if std::time::Instant::now() >= deadline {
            return Err(CliError(format!(
                "gave up waiting for {what}; the other device never answered"
            )));
        }
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    }
}

async fn put_slot(
    conn: &mut Connection,
    code: &PairingCode,
    slot: &str,
    data: Vec<u8>,
) -> Result<(), CliError> {
    match conn
        .request(Payload::PairPut {
            pair_id: code.pair_id.clone(),
            capability: code.capability.clone(),
            slot: slot.to_string(),
            data,
        })
        .await?
    {
        Payload::Ack => Ok(()),
        other => Err(CliError(format!("unexpected reply: {other:?}"))),
    }
}

/// `arveil device pair --data-dir NEW <bootstrap>`
///
/// Opens a rendezvous, prints the code the user carries to the other device,
/// answers the handshake, receives the grant and stores it pending. Nothing
/// is applied until `device pair-confirm` is run with the number both
/// devices show.
pub fn pair(data_dir: &Path, bootstrap: &str) -> Result<(), CliError> {
    let b = Bootstrap::parse(bootstrap)?;
    let c = open_client(data_dir)?;
    let device = c.device_pending_new().map_err(err("device"))?;
    let public = device.keys.public();

    block_on(async {
        let mut conn = Connection::open(
            &b.url,
            &b.realm_id,
            &b.noise_public,
            &device.keys.transport_noise,
        )
        .await?;
        let (pair_id, capability, expires_at) = match conn.request(Payload::PairBegin).await? {
            Payload::PairStarted {
                pair_id,
                capability,
                expires_at,
            } => (pair_id, capability, expires_at),
            other => return Err(CliError(format!("unexpected reply: {other:?}"))),
        };
        let code = PairingCode {
            realm_id: b.realm_id.clone(),
            pair_id,
            capability,
            static_public: device.keys.transport_noise.public.clone(),
        };
        println!(
            "device: {} (keys generated, not yet linked)",
            hex::encode(device.keys.device_id)
        );
        println!("code: {}", code.to_string_code());
        println!(
            "waiting: show that code on the administration device (it expires at {expires_at})"
        );

        let msg1 = wait_for_slot(&mut conn, &code, SLOT_HANDSHAKE_1, "the other device").await?;
        let mut responder = Responder::new(&device.keys.transport_noise, &prologue(&b.realm_id))
            .map_err(err("pairing handshake"))?;
        responder
            .read_message_1(&msg1)
            .map_err(err("pairing handshake"))?;
        let keys = arveil_core::signed::canonical(&PairedDeviceKeys::from(&public))
            .map_err(err("device keys"))?;
        let (msg2, mut transport) = responder
            .write_message_2_payload(&keys)
            .map_err(err("pairing handshake"))?;
        put_slot(&mut conn, &code, SLOT_HANDSHAKE_2, msg2).await?;

        let sealed = wait_for_slot(&mut conn, &code, SLOT_GRANT, "the signed grant").await?;
        let plain = transport.open(&sealed).map_err(err("pairing channel"))?;
        let grant: PairingGrant = ciborium::from_reader(plain.as_slice()).map_err(err("grant"))?;
        let sas = pairing::short_authentication_string(transport.handshake_hash());
        c.pairing_pending_save(&sas, &grant.credential, &grant.manifest, &grant.root_public)
            .map_err(err("pairing"))?;
        println!("verification code: {sas}");
        println!(
            "confirm with `arveil device pair-confirm --data-dir <dir> <bootstrap> {sas}` only if \
             the administration device shows the same number"
        );
        conn.close().await;
        Ok::<_, CliError>(())
    })?
}

/// `arveil device pair-approve --data-dir ADMIN <bootstrap> <code>`
pub fn pair_approve(data_dir: &Path, bootstrap: &str, code: &str) -> Result<(), CliError> {
    let b = Bootstrap::parse(bootstrap)?;
    let code = PairingCode::parse(code).map_err(err("code"))?;
    code.check_realm(&b.realm_id).map_err(err("code"))?;
    let (c, admin, _realm) = crate::commands::enrolled(data_dir)?;

    block_on(async {
        let mut conn = Connection::open(
            &b.url,
            &b.realm_id,
            &b.noise_public,
            &admin.keys.transport_noise,
        )
        .await?;
        let mut initiator = Initiator::new(
            &admin.keys.transport_noise,
            &code.static_public,
            &prologue(&b.realm_id),
        )
        .map_err(err("pairing handshake"))?;
        let msg1 = initiator
            .write_message_1()
            .map_err(err("pairing handshake"))?;
        match put_slot(&mut conn, &code, SLOT_HANDSHAKE_1, msg1).await {
            Ok(()) => {}
            Err(e) if e.0.contains("(409)") => {
                return Err(CliError(format!(
                    "{e}. Someone else already answered this code: abandon it and start a new \
                     pairing on the other device"
                )));
            }
            Err(e) => return Err(e),
        }
        let msg2 = wait_for_slot(&mut conn, &code, SLOT_HANDSHAKE_2, "the new device").await?;
        let (payload, mut transport) = initiator
            .read_message_2_payload(&msg2)
            .map_err(err("pairing handshake"))?;
        let keys: PairedDeviceKeys =
            ciborium::from_reader(payload.as_slice()).map_err(err("device keys"))?;
        // The credential must bind the very key this handshake authenticated.
        if keys.transport_noise_public_key != code.static_public {
            return Err(CliError(
                "the new device asked to sign a transport key other than the one it paired with"
                    .into(),
            ));
        }
        let sas = pairing::short_authentication_string(transport.handshake_hash());
        println!("verification code: {sas}");

        let public = arveil_core::identity::DevicePublicKeys::from(&keys);
        let (credential, manifest) = c
            .device_authorize(&public, now())
            .map_err(err("authorize"))?;
        let seq = c
            .manifest_state()
            .map_err(err("manifest"))?
            .map(|m| m.sequence)
            .unwrap_or(0);
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
        let root_public = c
            .root_public()
            .map_err(err("identity"))?
            .ok_or_else(|| CliError("no identity".into()))?
            .as_bytes()
            .to_vec();
        let grant = arveil_core::signed::canonical(&PairingGrant {
            credential,
            manifest,
            root_public,
        })
        .map_err(err("grant"))?;
        let sealed = transport.seal(&grant).map_err(err("pairing channel"))?;
        put_slot(&mut conn, &code, SLOT_GRANT, sealed).await?;
        println!(
            "sent: the grant is on its way; the other device must show {sas} before it applies it"
        );
        conn.close().await;
        Ok::<_, CliError>(())
    })?
}

/// `arveil device pair-confirm --data-dir NEW <bootstrap> <verification-code>`
pub fn pair_confirm(data_dir: &Path, bootstrap: &str, sas: &str) -> Result<(), CliError> {
    let b = Bootstrap::parse(bootstrap)?;
    let c = open_client(data_dir)?;
    let pending = c
        .pairing_pending()
        .map_err(err("pairing"))?
        .ok_or_else(|| CliError("no pairing is waiting on this device".into()))?;
    let given = sas.trim().replace(' ', "");
    if given != pending.sas {
        return Err(CliError(format!(
            "this device shows {}, not {given}: the two screens are not talking to each other, \
             so nothing was applied. Start a new pairing.",
            pending.sas
        )));
    }
    let identity_id = c
        .device_link_complete(
            &pending.credential,
            &pending.manifest,
            &pending.root_public,
            now(),
        )
        .map_err(err("link"))?;
    c.pairing_pending_clear().map_err(err("pairing"))?;
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
