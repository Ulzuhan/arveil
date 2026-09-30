//! Linking a device the other way round (ADR-012 §3).
//!
//! The device that holds the root opens the rendezvous from its member
//! session and shows a `link` card: the realm, the rendezvous and a one-time
//! X25519 key of its own. The new device reads the card (camera, link or
//! paste), becomes the Noise `IK` initiator towards that key and states its
//! keys in message 1. Both screens then show the same number, and nothing is
//! signed until the person confirms on the screen that authorizes:
//!
//! ```text
//! root device : pair_begin, one-time key            -> shows the link card
//! new device  : IK message 1 {keys, description}    -> slot a
//! root device : IK message 2                        -> slot b   both show the number
//! person      : confirms on the root device ("Link Pixel 8?")
//! root device : sealed LinkAnswer (grant or refusal) -> slot c
//! new device  : applies the grant at once if it scanned the card, or after
//!               the person confirms the number if the card crossed another app
//! ```
//!
//! The realm cannot answer on its own behalf: the one-time key never reaches
//! it, and message 1 cannot be built without it. Someone who photographs the
//! card and answers first takes the write-once slot; the real new device then
//! fails visibly and the root device shows a device the person does not
//! recognise, which they decline.
//!
//! The same confirmation now also gates the older flow, where the new device
//! shows an `arveil-pair:v1` code: the root device answers, shows the number,
//! and signs only when the person confirms.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

use arveil_core::channel::StaticKeypair;
use arveil_core::channel::noise::Transport;
use arveil_core::pairing::{LinkAnswer, LinkHello, MAX_DESCRIPTION_BYTES};

use super::*;
use crate::links::{Card, DEFAULT_LINK_BASE, Realm};

/// What the device that holds the root shows.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LinkOffer {
    pub pair_id: Vec<u8>,
    pub link: String,
    pub expires_at: u64,
}

/// A new device asking to be linked, waiting for the person's answer.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LinkRequest {
    pub pair_id: Vec<u8>,
    pub verification_code: String,
    pub device_id: Vec<u8>,
    /// How the new device describes itself ("Pixel 8 · Android 15"). Shown,
    /// never trusted.
    pub description: Option<String>,
    pub expires_at: Option<u64>,
}

/// How a link ended on the new device.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum JoinOutcome {
    /// The card was scanned from the other screen: linked already.
    Linked(LinkedDevice),
    /// The card crossed another app: the person confirms the number first.
    ConfirmationRequired(PairingVerification),
}

enum Pending {
    Offered {
        code: PairingCode,
        responder: StaticKeypair,
        expires_at: u64,
    },
    Requested {
        code: PairingCode,
        transport: Box<Transport>,
        keys: PairedDeviceKeys,
        /// The older flow: its new device expects a bare grant and knows no
        /// refusal.
        legacy: bool,
        expires_at: Option<u64>,
    },
}

type PendingKey = (PathBuf, Vec<u8>);

/// Links waiting on this process, per profile and rendezvous. They live only
/// as long as the app does: a link interrupted by closing the app is started
/// again, and the new device sees it stop.
fn pending() -> &'static Mutex<HashMap<PendingKey, Pending>> {
    static PENDING: OnceLock<Mutex<HashMap<PendingKey, Pending>>> = OnceLock::new();
    PENDING.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Offers withdrawn while their wait was running: when the new device
/// answers anyway, it is told no at once instead of waiting for expiry.
fn withdrawn() -> &'static Mutex<std::collections::HashSet<PendingKey>> {
    static WITHDRAWN: OnceLock<Mutex<std::collections::HashSet<PendingKey>>> = OnceLock::new();
    WITHDRAWN.get_or_init(|| Mutex::new(std::collections::HashSet::new()))
}

fn key(config: &ProfileConfig, pair_id: &[u8]) -> PendingKey {
    (config.dir().to_path_buf(), pair_id.to_vec())
}

fn take(config: &ProfileConfig, pair_id: &[u8]) -> Option<Pending> {
    pending()
        .lock()
        .expect("pending links")
        .remove(&key(config, pair_id))
}

fn put(config: &ProfileConfig, pair_id: &[u8], value: Pending) {
    pending()
        .lock()
        .expect("pending links")
        .insert(key(config, pair_id), value);
}

/// Only the device that holds the root signs credentials.
fn administrator(config: &ProfileConfig) -> Result<(Client, StoredDevice, Bootstrap), CliError> {
    let (client, device, realm) = enrolled(config)?;
    if client.root().map_err(client_error("identity"))?.is_none() {
        return Err(CliError::Domain(
            "only the device that holds the identity's root can link another device".into(),
        ));
    }
    let bootstrap = Bootstrap::parse(&format!(
        "arveil-bootstrap:v0:{}:{}:{}:{}",
        hex::encode(&realm.realm_id),
        hex::encode(realm.signing_public.as_bytes()),
        hex::encode(&realm.noise_public),
        realm.preferred_endpoint_url(),
    ))?;
    Ok((client, device, bootstrap))
}

/// Open a rendezvous and describe it as a `link` card.
pub async fn offer_link(config: &ProfileConfig) -> Result<LinkOffer, CliError> {
    let (client, admin, mut bootstrap) = administrator(config)?;
    let mut connection = Connection::open(
        &bootstrap.url,
        &bootstrap.realm_id,
        &bootstrap.noise_public,
        &admin.keys.transport_noise,
        config.tls_ca(),
    )
    .await?;
    // A member can still have the tailnet bootstrap it first enrolled with.
    // Refresh the authenticated route list before putting a route in a card
    // that must be usable on a different device/network.
    match connection.request(Payload::EndpointListGet).await? {
        Payload::EndpointList { signed } => {
            client
                .realm_accept_endpoint_list(&bootstrap.realm_id, &signed)
                .map_err(client_error("link endpoints"))?;
            let realm = client
                .realm()
                .map_err(client_error("realm"))?
                .ok_or_else(|| CliError::Domain("no enrolled realm".into()))?;
            bootstrap.url = realm.preferred_endpoint_url().to_owned();
            bootstrap.noise_public = realm.noise_public;
        }
        other => return Err(unexpected(other)),
    }
    let (pair_id, capability, expires_at) = match connection.request(Payload::PairBegin).await? {
        Payload::PairStarted {
            pair_id,
            capability,
            expires_at,
        } => (pair_id, capability, expires_at),
        other => return Err(unexpected(other)),
    };
    connection.close().await;
    let responder = StaticKeypair::generate().map_err(protocol_error("pairing key"))?;
    let card = Card::Link {
        realm: Realm {
            signing_key: bootstrap.signing_key,
            noise_public: bootstrap.noise_public.clone(),
            url: bootstrap.url.clone(),
        },
        pair_id: pair_id.clone(),
        capability: capability.clone(),
        responder_key: responder.public.clone(),
        expires_at,
    };
    let link = card
        .link(DEFAULT_LINK_BASE)
        .map_err(|e| CliError::Domain(format!("link: {e}")))?;
    put(
        config,
        &pair_id,
        Pending::Offered {
            code: PairingCode {
                realm_id: bootstrap.realm_id.clone(),
                pair_id: pair_id.clone(),
                capability,
                static_public: responder.public.clone(),
            },
            responder,
            expires_at,
        },
    );
    record_change(StateChange::LinkOffered {
        pair_id: pair_id.clone(),
        expires_at,
    });
    Ok(LinkOffer {
        pair_id,
        link,
        expires_at,
    })
}

/// Wait for a new device to answer an offer, answer its handshake and show
/// the number. Nothing is signed here.
pub async fn await_link_request(
    config: &ProfileConfig,
    pair_id: &[u8],
) -> Result<LinkRequest, CliError> {
    let Some(Pending::Offered {
        code,
        responder,
        expires_at,
    }) = take(config, pair_id)
    else {
        return Err(CliError::Domain(
            "this link is no longer offered; show a new code".into(),
        ));
    };
    let (_client, admin, bootstrap) = administrator(config)?;
    let mut connection = Connection::open(
        &bootstrap.url,
        &bootstrap.realm_id,
        &bootstrap.noise_public,
        &admin.keys.transport_noise,
        config.tls_ca(),
    )
    .await?;
    let deadline = pairing_deadline(config, expires_at)?;
    let message_1 = match wait_for_slot(
        &mut connection,
        &code,
        SLOT_HANDSHAKE_1,
        "the new device",
        deadline,
        None,
    )
    .await
    {
        Ok(message) => message,
        Err(error) => {
            // Still offered if only this wait stopped (the app went to the
            // background); gone if the rendezvous itself is.
            if error.relay_code() != Some(410) && now() < expires_at {
                put(
                    config,
                    pair_id,
                    Pending::Offered {
                        code,
                        responder,
                        expires_at,
                    },
                );
            }
            return Err(error);
        }
    };
    let mut handshake = Responder::new(&responder, &prologue(&bootstrap.realm_id))
        .map_err(protocol_error("pairing handshake"))?;
    let (remote, said) = handshake
        .read_message_1_payload(&message_1)
        .map_err(protocol_error("pairing handshake"))?;
    let hello: LinkHello =
        ciborium::from_reader(said.as_slice()).map_err(protocol_error("device keys"))?;
    if hello.keys.transport_noise_public_key != remote {
        return Err(CliError::Domain(
            "the device that answered asked to sign a transport key other than its own; nothing was signed".into(),
        ));
    }
    let (message_2, mut transport) = handshake
        .write_message_2()
        .map_err(protocol_error("pairing handshake"))?;
    put_slot(&mut connection, &code, SLOT_HANDSHAKE_2, message_2).await?;
    if withdrawn()
        .lock()
        .expect("withdrawn links")
        .remove(&key(config, pair_id))
    {
        let refusal = arveil_core::signed::canonical(&LinkAnswer::Declined)
            .map_err(protocol_error("refusal"))?;
        let sealed = transport
            .seal(&refusal)
            .map_err(protocol_error("pairing channel"))?;
        put_slot(&mut connection, &code, SLOT_GRANT, sealed).await?;
        connection.close().await;
        return Err(CliError::Domain(
            "the code was closed before a device answered; nothing was signed".into(),
        ));
    }
    connection.close().await;
    let verification_code = pairing::short_authentication_string(transport.handshake_hash());
    let request = LinkRequest {
        pair_id: pair_id.to_vec(),
        verification_code: verification_code.clone(),
        device_id: hello.keys.device_id.clone(),
        description: hello.description.as_deref().and_then(description),
        expires_at: Some(expires_at),
    };
    put(
        config,
        pair_id,
        Pending::Requested {
            code,
            transport: Box::new(transport),
            keys: hello.keys,
            legacy: false,
            expires_at: Some(expires_at),
        },
    );
    record_change(StateChange::LinkRequested {
        pair_id: pair_id.to_vec(),
        verification_code,
        device_id: request.device_id.clone(),
    });
    Ok(request)
}

/// Answer a device older than ADR-012 that showed an `arveil-pair:v1` code:
/// the same handshake as before, but the number is shown and nothing is
/// signed until [`answer_link`] confirms it.
pub(super) async fn request_from_code(
    config: &ProfileConfig,
    code: &str,
) -> Result<LinkRequest, CliError> {
    let code = PairingCode::parse(code).map_err(domain_error("code"))?;
    let (_client, admin, bootstrap) = administrator(config)?;
    code.check_realm(&bootstrap.realm_id)
        .map_err(domain_error("code"))?;
    let mut connection = Connection::open(
        &bootstrap.url,
        &bootstrap.realm_id,
        &bootstrap.noise_public,
        &admin.keys.transport_noise,
        config.tls_ca(),
    )
    .await?;
    let mut initiator = Initiator::new(
        &admin.keys.transport_noise,
        &code.static_public,
        &prologue(&bootstrap.realm_id),
    )
    .map_err(protocol_error("pairing handshake"))?;
    let message_1 = initiator
        .write_message_1()
        .map_err(protocol_error("pairing handshake"))?;
    match put_slot(&mut connection, &code, SLOT_HANDSHAKE_1, message_1).await {
        Ok(()) => {}
        Err(error) if error.relay_code() == Some(409) => {
            return Err(CliError::Domain(format!(
                "{error}. Someone else already answered this code: abandon it and start a new pairing on the other device"
            )));
        }
        Err(error) => return Err(error),
    }
    let message_2 = wait_for_slot(
        &mut connection,
        &code,
        SLOT_HANDSHAKE_2,
        "the new device",
        Instant::now() + pair_timeout(config),
        None,
    )
    .await?;
    connection.close().await;
    let (payload, transport) = initiator
        .read_message_2_payload(&message_2)
        .map_err(protocol_error("pairing handshake"))?;
    let keys: PairedDeviceKeys =
        ciborium::from_reader(payload.as_slice()).map_err(protocol_error("device keys"))?;
    if keys.transport_noise_public_key != code.static_public {
        return Err(CliError::Domain(
            "the new device asked to sign a transport key other than the one it paired with".into(),
        ));
    }
    let verification_code = pairing::short_authentication_string(transport.handshake_hash());
    let pair_id = code.pair_id.clone();
    let request = LinkRequest {
        pair_id: pair_id.clone(),
        verification_code: verification_code.clone(),
        device_id: keys.device_id.clone(),
        description: None,
        expires_at: None,
    };
    put(
        config,
        &pair_id,
        Pending::Requested {
            code,
            transport: Box::new(transport),
            keys,
            legacy: true,
            expires_at: None,
        },
    );
    record_change(StateChange::LinkRequested {
        pair_id,
        verification_code,
        device_id: request.device_id.clone(),
    });
    Ok(request)
}

/// The person's answer on the device that holds the root. Only a yes signs
/// the credential and manifest N+1, publishes them and seals the grant.
pub async fn answer_link(
    config: &ProfileConfig,
    pair_id: &[u8],
    approve: bool,
) -> Result<(), CliError> {
    let pending = take(config, pair_id);
    let Some(Pending::Requested {
        code,
        mut transport,
        keys,
        legacy,
        expires_at,
    }) = pending
    else {
        if !approve {
            // Nobody asked yet, or the wait for an answer is running: declining
            // withdraws the offer, and a device that answers later is told no.
            if pending.is_none() {
                withdrawn()
                    .lock()
                    .expect("withdrawn links")
                    .insert(key(config, pair_id));
            }
            record_change(StateChange::LinkAnswered {
                pair_id: pair_id.to_vec(),
                approved: false,
            });
            return Ok(());
        }
        return Err(CliError::Domain(
            "no device is waiting for this answer; show a new code".into(),
        ));
    };
    if approve && expires_at.is_some_and(|at| now() >= at) {
        return Err(CliError::Domain(
            "the link expired before it was confirmed; nothing was signed. Show a new code".into(),
        ));
    }
    let (client, admin, bootstrap) = administrator(config)?;
    let mut connection = Connection::open(
        &bootstrap.url,
        &bootstrap.realm_id,
        &bootstrap.noise_public,
        &admin.keys.transport_noise,
        config.tls_ca(),
    )
    .await?;
    let sealed = if approve {
        let public = DevicePublicKeys::from(&keys);
        let (credential, manifest) = client
            .device_authorize(&public, now())
            .map_err(client_error("authorize"))?;
        let sequence = client
            .manifest_state()
            .map_err(client_error("manifest"))?
            .map(|manifest| manifest.sequence)
            .unwrap_or(0);
        record_change(StateChange::DeviceAuthorizationSigned {
            device_id: public.device_id,
            manifest_sequence: sequence,
        });
        publish_authorization(&mut connection, &credential, &manifest, sequence).await?;
        let root_public = client
            .root_public()
            .map_err(client_error("identity"))?
            .ok_or_else(|| CliError::Domain("no identity".into()))?
            .as_bytes()
            .to_vec();
        let grant = PairingGrant {
            credential,
            manifest,
            root_public,
        };
        let plain = if legacy {
            arveil_core::signed::canonical(&grant)
        } else {
            arveil_core::signed::canonical(&LinkAnswer::Granted(grant))
        }
        .map_err(protocol_error("grant"))?;
        Some(
            transport
                .seal(&plain)
                .map_err(protocol_error("pairing channel"))?,
        )
    } else if legacy {
        // A device older than the refusal keeps waiting until its code
        // expires; nothing tells it more than silence.
        None
    } else {
        let plain = arveil_core::signed::canonical(&LinkAnswer::Declined)
            .map_err(protocol_error("refusal"))?;
        Some(
            transport
                .seal(&plain)
                .map_err(protocol_error("pairing channel"))?,
        )
    };
    if let Some(sealed) = sealed {
        put_slot(&mut connection, &code, SLOT_GRANT, sealed).await?;
    }
    connection.close().await;
    if approve {
        record_change(StateChange::PairingGrantSent {
            session_id: pair_id.to_vec(),
            verification_code: pairing::short_authentication_string(transport.handshake_hash()),
        });
    }
    record_change(StateChange::LinkAnswered {
        pair_id: pair_id.to_vec(),
        approved: approve,
    });
    Ok(())
}

/// A self-description a new device may give: trimmed, bounded, printable.
pub fn description(text: &str) -> Option<String> {
    let text = text.trim();
    if text.is_empty() || text.len() > MAX_DESCRIPTION_BYTES || text.chars().any(char::is_control) {
        return None;
    }
    Some(text.to_string())
}

/// The realm id a pairing session names, whether its code is an older
/// `arveil-pair:v1` code or a link card.
pub(super) fn session_realm(code: &str) -> Result<Vec<u8>, CliError> {
    if code.starts_with(arveil_core::pairing::CODE_PREFIX) {
        return Ok(PairingCode::parse(code)
            .map_err(domain_error("code"))?
            .realm_id);
    }
    match Card::find(code) {
        Ok(card @ Card::Link { .. }) => Ok(card.realm().realm_id()),
        _ => Err(CliError::Domain(
            "the pairing session names no realm".into(),
        )),
    }
}

/// Whether a pairing session is a link this device answered (ADR-012), as
/// opposed to a code it showed.
pub fn is_link_session(code: &str) -> bool {
    !code.starts_with(arveil_core::pairing::CODE_PREFIX)
}

/// The new device's side: read a `link` card, state this device's keys to
/// the device that showed it, and wait for its answer.
pub async fn join_link(
    config: &ProfileConfig,
    text: &str,
    self_description: Option<&str>,
    scanned: bool,
) -> Result<JoinOutcome, CliError> {
    let card = Card::find(text).map_err(|e| CliError::Domain(format!("link: {e}")))?;
    let Card::Link {
        realm,
        pair_id,
        capability,
        responder_key,
        expires_at,
    } = &card
    else {
        return Err(CliError::Domain(format!(
            "this is a {} code, not a code to link a device",
            card.kind()
        )));
    };
    if now() >= *expires_at {
        return Err(CliError::Domain(
            "this code expired; show a new one on the other device".into(),
        ));
    }
    let client = open_client(config)?;
    let device = pending_device(&client)?;
    if let Some(session) = client
        .latest_pairing_session()
        .map_err(client_error("pairing"))?
    {
        let committing = client
            .pairing_completion_phase(&session.session_id)
            .map_err(client_error("pairing"))?
            .is_some();
        if committing || (session.sas.is_some() && now() < session.expires_at) {
            return Err(CliError::Domain(
                "cancel or complete the existing pairing first".into(),
            ));
        }
        client
            .pairing_session_clear(&session.session_id)
            .map_err(client_error("pairing"))?;
    }
    let realm_id = realm.realm_id();
    client
        .realm_save(
            &realm_id,
            &realm.signing_key,
            &realm.noise_public,
            &realm.url,
        )
        .map_err(client_error("realm"))?;
    let session_text = card
        .link(DEFAULT_LINK_BASE)
        .map_err(|e| CliError::Domain(format!("link: {e}")))?;
    let code = PairingCode {
        realm_id: realm_id.clone(),
        pair_id: pair_id.clone(),
        capability: capability.clone(),
        static_public: responder_key.clone(),
    };
    let mut connection = Connection::open(
        &realm.url,
        &realm_id,
        &realm.noise_public,
        &device.keys.transport_noise,
        config.tls_ca(),
    )
    .await?;
    client
        .pairing_session_start(pair_id, &session_text, *expires_at)
        .map_err(client_error("pairing"))?;
    record_change(StateChange::PairingStarted {
        session_id: pair_id.clone(),
        device_id: device.keys.device_id.to_vec(),
        code: session_text,
        expires_at: *expires_at,
    });
    let hello = LinkHello {
        keys: PairedDeviceKeys::from(&device.keys.public()),
        description: self_description.and_then(description),
    };
    let mut initiator = Initiator::new(
        &device.keys.transport_noise,
        responder_key,
        &prologue(&realm_id),
    )
    .map_err(protocol_error("pairing handshake"))?;
    let message_1 = initiator
        .write_message_1_payload(
            &arveil_core::signed::canonical(&hello).map_err(protocol_error("device keys"))?,
        )
        .map_err(protocol_error("pairing handshake"))?;
    match put_slot(&mut connection, &code, SLOT_HANDSHAKE_1, message_1).await {
        Ok(()) => {}
        Err(error) if matches!(error.relay_code(), Some(409) | Some(410)) => {
            client
                .pairing_session_clear(pair_id)
                .map_err(client_error("pairing"))?;
            return Err(CliError::Domain(if error.relay_code() == Some(409) {
                "another device already answered this code. If it was not yours, decline it on the other device; then show a new code".into()
            } else {
                "this code expired; show a new one on the other device".into()
            }));
        }
        Err(error) => return Err(error),
    }
    let deadline = pairing_deadline(config, *expires_at)?;
    let message_2 = wait_for_local_slot(
        &mut connection,
        &client,
        &code,
        SLOT_HANDSHAKE_2,
        "the other device",
        deadline,
        pair_id,
    )
    .await?;
    let mut transport = initiator
        .read_message_2(&message_2)
        .map_err(protocol_error("pairing handshake"))?;
    let verification_code = pairing::short_authentication_string(transport.handshake_hash());
    record_change(StateChange::PairingVerificationReady {
        session_id: pair_id.clone(),
        verification_code: verification_code.clone(),
        expires_at: Some(*expires_at),
        confirmation_required: !scanned,
    });
    let sealed = wait_for_local_slot(
        &mut connection,
        &client,
        &code,
        SLOT_GRANT,
        "the answer on the other device",
        deadline,
        pair_id,
    )
    .await?;
    connection.close().await;
    let plain = transport
        .open(&sealed)
        .map_err(protocol_error("pairing channel"))?;
    let grant = match ciborium::from_reader(plain.as_slice()).map_err(protocol_error("answer"))? {
        LinkAnswer::Granted(grant) => grant,
        LinkAnswer::Declined => {
            client
                .pairing_session_clear(pair_id)
                .map_err(client_error("pairing"))?;
            record_change(StateChange::PairingCancelled {
                session_id: pair_id.clone(),
            });
            return Err(CliError::Domain(
                "the other device declined this link; nothing was applied".into(),
            ));
        }
    };
    if !client
        .pairing_session_ready(
            pair_id,
            &verification_code,
            &grant.credential,
            &grant.manifest,
            &grant.root_public,
        )
        .map_err(client_error("pairing"))?
    {
        return Err(CliError::Domain("pairing session was cancelled".into()));
    }
    if scanned {
        // The card came from the other screen through the camera, so the key
        // it names was authenticated by sight and IK bound it (ADR-012 §3).
        return Box::pin(confirm_pairing(
            config,
            &realm.bootstrap(),
            pair_id,
            &verification_code,
        ))
        .await
        .map(JoinOutcome::Linked);
    }
    let verification = PairingVerification {
        session_id: pair_id.clone(),
        verification_code,
        expires_at: Some(*expires_at),
    };
    Ok(JoinOutcome::ConfirmationRequired(verification))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn linking_uses_the_verified_current_route_instead_of_an_old_tailnet_bootstrap() {
        use arveil_core::channel::endpoints::{self, Endpoint, RealmEndpointList};
        use arveil_core::storage::SharedConn;
        let signing = ed25519_dalek::SigningKey::from_bytes(&[9; 32]);
        let realm_id = endpoints::realm_id(&signing.verifying_key());
        let client = Client::open(SharedConn::open_in_memory().unwrap()).unwrap();
        let private_url = "ws://192.0.2.1:8447/v1/channel";
        let public_url = "wss://relay.example.org/v1/channel";
        client
            .realm_save(&realm_id, &signing.verifying_key(), &[8; 32], private_url)
            .unwrap();
        assert_eq!(
            client.realm().unwrap().unwrap().preferred_endpoint_url(),
            private_url
        );
        let list = RealmEndpointList {
            version: 1,
            realm_id: realm_id.clone(),
            sequence: 2,
            realm_noise_public_key: vec![8; 32],
            endpoints: vec![
                Endpoint {
                    kind: "tailnet".into(),
                    url: private_url.into(),
                    priority: 20,
                },
                Endpoint {
                    kind: "admin".into(),
                    url: "http://127.0.0.1/admin".into(),
                    priority: 0,
                },
                Endpoint {
                    kind: "public".into(),
                    url: public_url.into(),
                    priority: 1,
                },
            ],
        };
        let signed = arveil_core::signed::sign_value(endpoints::CONTEXT, &list, &signing).unwrap();
        client
            .realm_accept_endpoint_list(&realm_id, &signed)
            .unwrap();
        let realm = client.realm().unwrap().unwrap();
        assert_eq!(realm.bootstrap_url, private_url, "enrollment is preserved");
        assert_eq!(realm.preferred_endpoint_url(), public_url);
        let mut hostile = list;
        hostile.sequence = 3;
        hostile.endpoints[2].url = "wss://untrusted.example.org".into();
        let bad = arveil_core::signed::sign_value(
            endpoints::CONTEXT,
            &hostile,
            &ed25519_dalek::SigningKey::from_bytes(&[10; 32]),
        )
        .unwrap();
        assert!(client.realm_accept_endpoint_list(&realm_id, &bad).is_err());
        assert_eq!(
            client.realm().unwrap().unwrap().preferred_endpoint_url(),
            public_url
        );
    }

    #[test]
    fn a_self_description_is_trimmed_bounded_and_printable() {
        assert_eq!(
            description("  Pixel 8 · Android 15 "),
            Some("Pixel 8 · Android 15".into())
        );
        assert_eq!(description(""), None);
        assert_eq!(description("a\nb"), None);
        assert_eq!(description(&"x".repeat(MAX_DESCRIPTION_BYTES + 1)), None);
    }

    #[test]
    fn a_session_names_its_realm_whether_it_showed_a_code_or_answered_a_link() {
        let realm = Realm {
            signing_key: ed25519_dalek::SigningKey::from_bytes(&[9; 32]).verifying_key(),
            noise_public: vec![8; 32],
            url: "wss://relay.example.org/v1/channel".into(),
        };
        let link = Card::Link {
            realm: realm.clone(),
            pair_id: vec![1; 16],
            capability: vec![2; 32],
            responder_key: vec![3; 32],
            expires_at: 1,
        }
        .link(DEFAULT_LINK_BASE)
        .unwrap();
        assert!(is_link_session(&link));
        assert_eq!(session_realm(&link).unwrap(), realm.realm_id());
        let code = PairingCode {
            realm_id: vec![7; 32],
            pair_id: vec![1; 16],
            capability: vec![2; 32],
            static_public: vec![3; 32],
        }
        .to_string_code();
        assert!(!is_link_session(&code));
        assert_eq!(session_realm(&code).unwrap(), vec![7; 32]);
        assert!(session_realm("nonsense").is_err());
    }
}
