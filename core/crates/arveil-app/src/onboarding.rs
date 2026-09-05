//! Identity creation, realm enrollment and interactive device linking.

use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use arveil_core::channel::codec::Payload;
use arveil_core::channel::noise::{Initiator, Responder, prologue};
use arveil_core::client::{
    Client, OwnMailbox, PairingCancellationStatus, PairingCompletionPhase, PairingSessionState,
    StoredDevice,
};
use arveil_core::identity::DevicePublicKeys;
use arveil_core::pairing::{
    self, PairedDeviceKeys, PairingCode, PairingGrant, SLOT_GRANT, SLOT_HANDSHAKE_1,
    SLOT_HANDSHAKE_2,
};
use serde::{Deserialize, Serialize};

use super::{
    CliError, Connection, PairingCancellation, StateChange, domain_error, enrolled, open_client,
    protocol_error, record_change, route_string,
};
use crate::carrier::Bootstrap;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Identity {
    pub identity_id: Vec<u8>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Enrollment {
    pub identity_id: Vec<u8>,
    pub device_id: Vec<u8>,
    pub endpoint_sequence: u64,
    pub mailbox_id: Vec<u8>,
    pub key_packages_published: usize,
    pub route: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeviceLinkRequest {
    pub device_id: Vec<u8>,
    pub request: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeviceLinkAuthorization {
    pub device_id: Vec<u8>,
    pub manifest_sequence: u64,
    pub grant: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LinkedDevice {
    pub identity_id: Vec<u8>,
    pub device_id: Vec<u8>,
    pub endpoint_sequence: u64,
    pub mailbox_id: Vec<u8>,
    pub key_packages_published: usize,
    pub route: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PairingSession {
    pub session_id: Vec<u8>,
    pub code: String,
    pub expires_at: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PairingVerification {
    pub session_id: Vec<u8>,
    pub verification_code: String,
    pub expires_at: Option<u64>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EnrollmentFinish {
    pub mailbox_id: Vec<u8>,
    pub key_packages_published: usize,
    pub route: String,
}

#[derive(Serialize, Deserialize)]
struct Grant {
    #[serde(with = "serde_bytes")]
    credential: Vec<u8>,
    #[serde(with = "serde_bytes")]
    manifest: Vec<u8>,
    #[serde(with = "serde_bytes")]
    root_public: Vec<u8>,
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0)
}

fn client_error(context: &str) -> impl FnOnce(arveil_core::client::ClientError) -> CliError + '_ {
    move |error| match error {
        arveil_core::client::ClientError::Sqlite(error) => {
            CliError::Storage(format!("{context}: {error}"))
        }
        error => CliError::Domain(format!("{context}: {error}")),
    }
}

fn unexpected(payload: Payload) -> CliError {
    CliError::Protocol(format!("unexpected reply: {payload:?}"))
}

fn request_string(public: &DevicePublicKeys) -> String {
    format!(
        "arveil-link-request:v0:{}:{}:{}:{}",
        hex::encode(&public.device_id),
        hex::encode(&public.mls_signature_public_key),
        hex::encode(&public.transport_noise_public_key),
        hex::encode(&public.envelope_hpke_public_key)
    )
}

fn parse_request(value: &str) -> Result<DevicePublicKeys, CliError> {
    let parts: Vec<&str> = value.split(':').collect();
    if parts.len() != 6 || parts[0] != "arveil-link-request" || parts[1] != "v0" {
        return Err(CliError::Domain(
            "not an arveil-link-request:v0 string".into(),
        ));
    }
    Ok(DevicePublicKeys {
        device_id: hex::decode(parts[2]).map_err(domain_error("device id"))?,
        mls_signature_public_key: hex::decode(parts[3]).map_err(domain_error("mls key"))?,
        transport_noise_public_key: hex::decode(parts[4]).map_err(domain_error("noise key"))?,
        envelope_hpke_public_key: hex::decode(parts[5]).map_err(domain_error("hpke key"))?,
    })
}

fn parse_grant(value: &str) -> Result<Grant, CliError> {
    let encoded = value
        .strip_prefix("arveil-link-grant:v0:")
        .ok_or_else(|| CliError::Domain("not an arveil-link-grant:v0 string".into()))?;
    let bytes = hex::decode(encoded).map_err(domain_error("grant"))?;
    ciborium::from_reader(bytes.as_slice()).map_err(domain_error("grant"))
}

fn pending_device(client: &Client) -> Result<StoredDevice, CliError> {
    match client.device().map_err(client_error("device"))? {
        Some(device)
            if device.credential.is_empty()
                && client
                    .identity_id()
                    .map_err(client_error("identity"))?
                    .is_none() =>
        {
            Ok(device)
        }
        Some(_) => Err(CliError::Domain(
            "device is already linked or enrolled".into(),
        )),
        None => client.device_pending_new().map_err(client_error("device")),
    }
}

pub async fn create_identity(data_dir: &std::path::Path) -> Result<Identity, CliError> {
    let client = open_client(data_dir)?;
    let root = client.identity_new().map_err(client_error("identity"))?;
    let identity = Identity {
        identity_id: root.identity_id(),
    };
    record_change(StateChange::IdentityCreated {
        identity_id: identity.identity_id.clone(),
        created_during_enrollment: false,
    });
    Ok(identity)
}

pub async fn enroll(
    data_dir: &std::path::Path,
    bootstrap: &str,
    invite: &str,
) -> Result<Enrollment, CliError> {
    let bootstrap = Bootstrap::parse(bootstrap)?;
    let token = hex::decode(invite).map_err(domain_error("invite token"))?;
    let client = open_client(data_dir)?;
    if client.root().map_err(client_error("identity"))?.is_none() {
        let root = client.identity_new().map_err(client_error("identity"))?;
        record_change(StateChange::IdentityCreated {
            identity_id: root.identity_id(),
            created_during_enrollment: true,
        });
    }
    let (device, manifest) = match client.device().map_err(client_error("device"))? {
        Some(device) => {
            let manifest = client
                .latest_manifest()
                .map_err(client_error("manifest"))?
                .ok_or_else(|| CliError::Domain("device without manifest".into()))?;
            (device, manifest)
        }
        None => client.device_new(now()).map_err(client_error("device"))?,
    };
    record_change(StateChange::DevicePrepared {
        device_id: device.keys.device_id.to_vec(),
    });
    client
        .realm_save(
            &bootstrap.realm_id,
            &bootstrap.signing_key,
            &bootstrap.noise_public,
            &bootstrap.url,
        )
        .map_err(client_error("realm"))?;

    let mut connection = Connection::open(
        &bootstrap.url,
        &bootstrap.realm_id,
        &bootstrap.noise_public,
        &device.keys.transport_noise,
    )
    .await?;
    let identity_id = match connection
        .request(Payload::InviteRedeem {
            token,
            credential: device.credential.clone(),
            manifest,
        })
        .await?
    {
        Payload::InviteRedeemed { identity_id } => identity_id,
        other => return Err(unexpected(other)),
    };
    record_change(StateChange::EnrollmentAccepted {
        identity_id: identity_id.clone(),
    });
    let endpoint_sequence = accept_endpoint_list(&client, &bootstrap, &mut connection).await?;
    client
        .realm_mark_enrolled(&bootstrap.realm_id)
        .map_err(client_error("realm"))?;
    let finish = finish_enrollment(&client, &mut connection, &device).await?;
    record_finish(&finish);
    connection.close().await;
    Ok(Enrollment {
        identity_id,
        device_id: device.keys.device_id.to_vec(),
        endpoint_sequence,
        mailbox_id: finish.mailbox_id,
        key_packages_published: finish.key_packages_published,
        route: finish.route,
    })
}

pub async fn create_link_request(
    data_dir: &std::path::Path,
) -> Result<DeviceLinkRequest, CliError> {
    let client = open_client(data_dir)?;
    let device = pending_device(&client)?;
    let request = request_string(&device.keys.public());
    let result = DeviceLinkRequest {
        device_id: device.keys.device_id.to_vec(),
        request: request.clone(),
    };
    record_change(StateChange::LinkRequestCreated {
        device_id: result.device_id.clone(),
        request,
    });
    Ok(result)
}

pub async fn authorize_link(
    data_dir: &std::path::Path,
    bootstrap: &str,
    request: &str,
) -> Result<DeviceLinkAuthorization, CliError> {
    let bootstrap = Bootstrap::parse(bootstrap)?;
    let public = parse_request(request)?;
    let (client, admin, _) = enrolled(data_dir)?;
    let (credential, manifest) = client
        .device_authorize(&public, now())
        .map_err(client_error("authorize"))?;
    let sequence = client
        .manifest_state()
        .map_err(client_error("manifest"))?
        .map(|manifest| manifest.sequence)
        .unwrap_or(0);
    record_change(StateChange::DeviceAuthorizationSigned {
        device_id: public.device_id.clone(),
        manifest_sequence: sequence,
    });
    let root_public = client
        .root_public()
        .map_err(client_error("identity"))?
        .ok_or_else(|| CliError::Domain("no identity".into()))?
        .as_bytes()
        .to_vec();
    let mut connection = Connection::open(
        &bootstrap.url,
        &bootstrap.realm_id,
        &bootstrap.noise_public,
        &admin.keys.transport_noise,
    )
    .await?;
    publish_authorization(&mut connection, &credential, &manifest, sequence).await?;
    connection.close().await;
    let encoded = arveil_core::signed::canonical(&Grant {
        credential,
        manifest,
        root_public,
    })
    .map_err(protocol_error("grant"))?;
    let grant = format!("arveil-link-grant:v0:{}", hex::encode(encoded));
    record_change(StateChange::LinkGrantCreated {
        grant: grant.clone(),
    });
    Ok(DeviceLinkAuthorization {
        device_id: public.device_id,
        manifest_sequence: sequence,
        grant,
    })
}

pub async fn complete_link(
    data_dir: &std::path::Path,
    bootstrap: &str,
    grant: &str,
) -> Result<LinkedDevice, CliError> {
    let grant = parse_grant(grant)?;
    let bootstrap = Bootstrap::parse(bootstrap)?;
    let client = open_client(data_dir)?;
    let phase = client
        .link_completion_begin(&grant.credential, &grant.manifest, &grant.root_public)
        .map_err(client_error("link"))?;
    if phase == PairingCompletionPhase::Complete {
        return Err(CliError::Domain(
            "device is already linked or enrolled".into(),
        ));
    }
    let completion = LinkCompletion::DirectGrant;
    record_completion_change(completion, phase);
    complete_device_link(
        &bootstrap,
        &client,
        completion,
        LinkGrantRef {
            credential: &grant.credential,
            manifest: &grant.manifest,
            root_public: &grant.root_public,
        },
        phase,
    )
    .await
}

pub async fn begin_pairing(
    data_dir: &std::path::Path,
    bootstrap: &str,
) -> Result<PairingSession, CliError> {
    let bootstrap = Bootstrap::parse(bootstrap)?;
    let client = open_client(data_dir)?;
    let device = pending_device(&client)?;
    let mut connection = Connection::open(
        &bootstrap.url,
        &bootstrap.realm_id,
        &bootstrap.noise_public,
        &device.keys.transport_noise,
    )
    .await?;
    let (session_id, capability, expires_at) = match connection.request(Payload::PairBegin).await? {
        Payload::PairStarted {
            pair_id,
            capability,
            expires_at,
        } => (pair_id, capability, expires_at),
        other => return Err(unexpected(other)),
    };
    connection.close().await;
    let code = PairingCode {
        realm_id: bootstrap.realm_id,
        pair_id: session_id.clone(),
        capability,
        static_public: device.keys.transport_noise.public.clone(),
    }
    .to_string_code();
    client
        .pairing_session_start(&session_id, &code, expires_at)
        .map_err(client_error("pairing"))?;
    record_change(StateChange::PairingStarted {
        session_id: session_id.clone(),
        device_id: device.keys.device_id.to_vec(),
        code: code.clone(),
        expires_at,
    });
    Ok(PairingSession {
        session_id,
        code,
        expires_at,
    })
}

pub async fn await_pairing(
    data_dir: &std::path::Path,
    bootstrap: &str,
    session: PairingSession,
) -> Result<PairingVerification, CliError> {
    let bootstrap = Bootstrap::parse(bootstrap)?;
    let client = open_client(data_dir)?;
    let stored = exact_session(&client, &session.session_id)?;
    if stored.code != session.code || stored.expires_at != session.expires_at {
        return Err(CliError::Domain(
            "pairing session details do not match the stored session".into(),
        ));
    }
    ensure_not_expired(&client, &stored)?;
    let code = PairingCode::parse(&session.code).map_err(domain_error("code"))?;
    code.check_realm(&bootstrap.realm_id)
        .map_err(domain_error("code"))?;
    if code.pair_id != session.session_id {
        return Err(CliError::Domain(
            "pairing code does not identify this session".into(),
        ));
    }
    let device = pending_device(&client)?;
    if code.static_public != device.keys.transport_noise.public {
        return Err(CliError::Domain(
            "pairing session does not name this device".into(),
        ));
    }
    let public = device.keys.public();
    let mut connection = Connection::open(
        &bootstrap.url,
        &bootstrap.realm_id,
        &bootstrap.noise_public,
        &device.keys.transport_noise,
    )
    .await?;
    let deadline = pairing_deadline(session.expires_at)?;
    let message_1 = wait_for_local_slot(
        &mut connection,
        &client,
        &code,
        SLOT_HANDSHAKE_1,
        "the other device",
        deadline,
        &session.session_id,
    )
    .await?;
    let mut responder =
        Responder::new(&device.keys.transport_noise, &prologue(&bootstrap.realm_id))
            .map_err(protocol_error("pairing handshake"))?;
    responder
        .read_message_1(&message_1)
        .map_err(protocol_error("pairing handshake"))?;
    let keys = arveil_core::signed::canonical(&PairedDeviceKeys::from(&public))
        .map_err(protocol_error("device keys"))?;
    let (message_2, mut transport) = responder
        .write_message_2_payload(&keys)
        .map_err(protocol_error("pairing handshake"))?;
    put_slot(&mut connection, &code, SLOT_HANDSHAKE_2, message_2).await?;
    let sealed = wait_for_local_slot(
        &mut connection,
        &client,
        &code,
        SLOT_GRANT,
        "the signed grant",
        deadline,
        &session.session_id,
    )
    .await?;
    let plain = transport
        .open(&sealed)
        .map_err(protocol_error("pairing channel"))?;
    let grant: PairingGrant =
        ciborium::from_reader(plain.as_slice()).map_err(protocol_error("grant"))?;
    let verification_code = pairing::short_authentication_string(transport.handshake_hash());
    if !client
        .pairing_session_ready(
            &session.session_id,
            &verification_code,
            &grant.credential,
            &grant.manifest,
            &grant.root_public,
        )
        .map_err(client_error("pairing"))?
    {
        return Err(CliError::Domain("pairing session was cancelled".into()));
    }
    connection.close().await;
    let verification = PairingVerification {
        session_id: session.session_id,
        verification_code,
        expires_at: Some(session.expires_at),
    };
    record_change(StateChange::PairingVerificationReady {
        session_id: verification.session_id.clone(),
        verification_code: verification.verification_code.clone(),
        expires_at: verification.expires_at,
        confirmation_required: true,
    });
    Ok(verification)
}

pub async fn approve_pairing(
    data_dir: &std::path::Path,
    bootstrap: &str,
    code: &str,
) -> Result<PairingVerification, CliError> {
    let bootstrap = Bootstrap::parse(bootstrap)?;
    let code = PairingCode::parse(code).map_err(domain_error("code"))?;
    code.check_realm(&bootstrap.realm_id)
        .map_err(domain_error("code"))?;
    let (client, admin, _) = enrolled(data_dir)?;
    let mut connection = Connection::open(
        &bootstrap.url,
        &bootstrap.realm_id,
        &bootstrap.noise_public,
        &admin.keys.transport_noise,
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
        Instant::now() + pair_timeout(),
        None,
    )
    .await?;
    let (payload, mut transport) = initiator
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
    record_change(StateChange::PairingVerificationReady {
        session_id: code.pair_id.clone(),
        verification_code: verification_code.clone(),
        expires_at: None,
        confirmation_required: false,
    });
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
    let grant = arveil_core::signed::canonical(&PairingGrant {
        credential,
        manifest,
        root_public,
    })
    .map_err(protocol_error("grant"))?;
    let sealed = transport
        .seal(&grant)
        .map_err(protocol_error("pairing channel"))?;
    put_slot(&mut connection, &code, SLOT_GRANT, sealed).await?;
    record_change(StateChange::PairingGrantSent {
        session_id: code.pair_id.clone(),
        verification_code: verification_code.clone(),
    });
    connection.close().await;
    Ok(PairingVerification {
        session_id: code.pair_id,
        verification_code,
        expires_at: None,
    })
}

pub async fn confirm_pairing(
    data_dir: &std::path::Path,
    bootstrap: &str,
    session_id: &[u8],
    verification_code: &str,
) -> Result<LinkedDevice, CliError> {
    let client = open_client(data_dir)?;
    let session = exact_session(&client, session_id)?;
    let expected = session
        .sas
        .as_deref()
        .ok_or_else(|| CliError::Domain("pairing has not reached verification yet".into()))?;
    let given = normalize_verification_code(verification_code);
    if given != normalize_verification_code(expected) {
        return Err(CliError::Domain(format!(
            "this device shows {expected}, not {given}: the two screens are not talking to each other, so nothing was applied. Start a new pairing."
        )));
    }
    if client
        .pairing_completion_phase(session_id)
        .map_err(client_error("pairing"))?
        .is_none()
    {
        ensure_not_expired(&client, &session)?;
    }
    let bootstrap = Bootstrap::parse(bootstrap)?;
    PairingCode::parse(&session.code)
        .map_err(domain_error("code"))?
        .check_realm(&bootstrap.realm_id)
        .map_err(domain_error("code"))?;
    let phase = client
        .pairing_completion_begin(session_id)
        .map_err(client_error("pairing"))?
        .ok_or_else(|| CliError::Domain("pairing grant is incomplete or was cancelled".into()))?;
    record_change(StateChange::PairingCompletionChanged {
        session_id: session_id.to_vec(),
        phase,
    });
    let grant = LinkGrantRef {
        credential: session
            .credential
            .as_deref()
            .ok_or_else(|| CliError::Domain("pairing grant is incomplete".into()))?,
        manifest: session
            .manifest
            .as_deref()
            .ok_or_else(|| CliError::Domain("pairing grant is incomplete".into()))?,
        root_public: session
            .root_public
            .as_deref()
            .ok_or_else(|| CliError::Domain("pairing grant is incomplete".into()))?,
    };
    complete_device_link(
        &bootstrap,
        &client,
        LinkCompletion::Pairing(&session.session_id),
        grant,
        phase,
    )
    .await
}

pub async fn cancel_pairing(
    data_dir: &std::path::Path,
    session_id: &[u8],
) -> Result<PairingCancellation, CliError> {
    let client = open_client(data_dir)?;
    match client
        .pairing_session_cancel(session_id)
        .map_err(client_error("pairing"))?
    {
        PairingCancellationStatus::Cancelled => {
            record_change(StateChange::PairingCancelled {
                session_id: session_id.to_vec(),
            });
            Ok(PairingCancellation::Cancelled)
        }
        PairingCancellationStatus::AlreadyCommitted => {
            record_change(StateChange::PairingCancellationRejected {
                session_id: session_id.to_vec(),
                reason: PairingCancellation::AlreadyCommitted,
            });
            Ok(PairingCancellation::AlreadyCommitted)
        }
        PairingCancellationStatus::Missing => Err(CliError::Domain(format!(
            "no pairing session {} is waiting on this device",
            hex::encode(session_id)
        ))),
    }
}

pub fn pending_pairing(
    data_dir: &std::path::Path,
) -> Result<Option<PairingVerification>, CliError> {
    let client = open_client(data_dir)?;
    let Some(session) = client
        .latest_pairing_session()
        .map_err(client_error("pairing"))?
    else {
        return Ok(None);
    };
    Ok(session.sas.map(|verification_code| PairingVerification {
        session_id: session.session_id,
        verification_code,
        expires_at: Some(session.expires_at),
    }))
}

#[derive(Clone, Copy)]
struct LinkGrantRef<'a> {
    credential: &'a [u8],
    manifest: &'a [u8],
    root_public: &'a [u8],
}

#[derive(Clone, Copy)]
enum LinkCompletion<'a> {
    Pairing(&'a [u8]),
    DirectGrant,
}

async fn complete_device_link(
    bootstrap: &Bootstrap,
    client: &Client,
    completion: LinkCompletion<'_>,
    grant: LinkGrantRef<'_>,
    mut phase: PairingCompletionPhase,
) -> Result<LinkedDevice, CliError> {
    let identity_id = if phase < PairingCompletionPhase::LocalApplied {
        let identity_id = match client.device_link_complete_idempotent(
            grant.credential,
            grant.manifest,
            grant.root_public,
            now(),
        ) {
            Ok(identity_id) => identity_id,
            Err(error) => {
                if matches!(completion, LinkCompletion::DirectGrant) {
                    client
                        .link_completion_abort_if_unapplied()
                        .map_err(client_error("link completion"))?;
                }
                return Err(client_error("link")(error));
            }
        };
        let device = client
            .device()
            .map_err(client_error("device"))?
            .ok_or_else(|| CliError::Domain("no device".into()))?;
        record_change(StateChange::DeviceLinked {
            device_id: device.keys.device_id.to_vec(),
            identity_id: identity_id.clone(),
        });
        phase = advance_completion(client, completion, PairingCompletionPhase::LocalApplied)?;
        identity_id
    } else {
        client
            .identity_id()
            .map_err(client_error("identity"))?
            .ok_or_else(|| CliError::Domain("committed pairing has no identity".into()))?
    };
    let device = client
        .device()
        .map_err(client_error("device"))?
        .ok_or_else(|| CliError::Domain("no device".into()))?;

    if phase < PairingCompletionPhase::RealmSaved {
        client
            .realm_save(
                &bootstrap.realm_id,
                &bootstrap.signing_key,
                &bootstrap.noise_public,
                &bootstrap.url,
            )
            .map_err(client_error("realm"))?;
        phase = advance_completion(client, completion, PairingCompletionPhase::RealmSaved)?;
    }

    if phase == PairingCompletionPhase::Complete {
        return linked_device_from_local(client, &device, identity_id, 0);
    }

    let mut connection = Connection::open(
        &bootstrap.url,
        &bootstrap.realm_id,
        &bootstrap.noise_public,
        &device.keys.transport_noise,
    )
    .await?;

    let endpoint_sequence = if phase < PairingCompletionPhase::EndpointStored {
        let sequence = accept_endpoint_list(client, bootstrap, &mut connection).await?;
        phase = advance_completion(client, completion, PairingCompletionPhase::EndpointStored)?;
        sequence
    } else {
        stored_endpoint_sequence(client)?
    };

    if phase < PairingCompletionPhase::RealmEnrolled {
        client
            .realm_mark_enrolled(&bootstrap.realm_id)
            .map_err(client_error("realm"))?;
        phase = advance_completion(client, completion, PairingCompletionPhase::RealmEnrolled)?;
    }

    let mailbox = if phase < PairingCompletionPhase::MailboxStored {
        let mailbox = match client.mailbox_own().map_err(client_error("mailbox"))? {
            Some(mailbox) => mailbox,
            None => create_mailbox(client, &mut connection).await?,
        };
        record_change(StateChange::MailboxCreated {
            mailbox_id: mailbox.mailbox_id.clone(),
        });
        phase = advance_completion(client, completion, PairingCompletionPhase::MailboxStored)?;
        mailbox
    } else {
        client
            .mailbox_own()
            .map_err(client_error("mailbox"))?
            .ok_or_else(|| CliError::Domain("completed pairing has no mailbox".into()))?
    };

    let mut published = 0usize;
    if phase < PairingCompletionPhase::KeyPackagesPublished {
        let available = match connection.request(Payload::KeyPackagesStatus).await? {
            Payload::KeyPackagesAvailable { count } => count,
            other => return Err(unexpected(other)),
        };
        published = if available == 0 {
            publish_initial_key_packages(client, &device, &mut connection).await?
        } else {
            available as usize
        };
        record_change(StateChange::KeyPackagesPublished { count: published });
        advance_completion(
            client,
            completion,
            PairingCompletionPhase::KeyPackagesPublished,
        )?;
    }

    let route = route_string(client, &device, &mailbox)?;
    record_change(StateChange::RouteAvailable {
        route: route.clone(),
    });
    let completed = advance_completion(client, completion, PairingCompletionPhase::Complete)?;
    debug_assert_eq!(completed, PairingCompletionPhase::Complete);
    connection.close().await;
    Ok(LinkedDevice {
        identity_id,
        device_id: device.keys.device_id.to_vec(),
        endpoint_sequence,
        mailbox_id: mailbox.mailbox_id,
        key_packages_published: published,
        route,
    })
}

fn advance_completion(
    client: &Client,
    completion: LinkCompletion<'_>,
    phase: PairingCompletionPhase,
) -> Result<PairingCompletionPhase, CliError> {
    let advanced = match completion {
        LinkCompletion::Pairing(session_id) => client
            .pairing_completion_advance(session_id, phase)
            .map_err(client_error("pairing"))?,
        LinkCompletion::DirectGrant => client
            .link_completion_advance(phase)
            .map_err(client_error("link"))?,
    };
    if !advanced {
        return Err(CliError::Domain("link completion state disappeared".into()));
    }
    record_completion_change(completion, phase);
    Ok(phase)
}

fn record_completion_change(completion: LinkCompletion<'_>, phase: PairingCompletionPhase) {
    match completion {
        LinkCompletion::Pairing(session_id) => {
            record_change(StateChange::PairingCompletionChanged {
                session_id: session_id.to_vec(),
                phase,
            });
        }
        LinkCompletion::DirectGrant => {
            record_change(StateChange::LinkCompletionChanged { phase });
        }
    }
}

fn stored_endpoint_sequence(client: &Client) -> Result<u64, CliError> {
    client
        .realm()
        .map_err(client_error("realm"))?
        .and_then(|realm| realm.endpoint_list.map(|list| list.sequence))
        .ok_or_else(|| CliError::Domain("completed pairing has no endpoint list".into()))
}

fn linked_device_from_local(
    client: &Client,
    device: &StoredDevice,
    identity_id: Vec<u8>,
    key_packages_published: usize,
) -> Result<LinkedDevice, CliError> {
    let mailbox = client
        .mailbox_own()
        .map_err(client_error("mailbox"))?
        .ok_or_else(|| CliError::Domain("completed pairing has no mailbox".into()))?;
    Ok(LinkedDevice {
        identity_id,
        device_id: device.keys.device_id.to_vec(),
        endpoint_sequence: stored_endpoint_sequence(client)?,
        mailbox_id: mailbox.mailbox_id.clone(),
        key_packages_published,
        route: route_string(client, device, &mailbox)?,
    })
}

async fn accept_endpoint_list(
    client: &Client,
    bootstrap: &Bootstrap,
    connection: &mut Connection,
) -> Result<u64, CliError> {
    let sequence = match connection.request(Payload::EndpointListGet).await? {
        Payload::EndpointList { signed } => {
            client
                .realm_accept_endpoint_list(&bootstrap.realm_id, &signed)
                .map_err(client_error("endpoint list"))?
                .sequence
        }
        other => return Err(unexpected(other)),
    };
    record_change(StateChange::EnrollmentEndpointListStored { sequence });
    Ok(sequence)
}

/// Create the mailbox and publish the first KeyPackage batch after a device
/// has been accepted. Recovery keeps using this primitive until its own
/// application service is extracted.
pub async fn finish_enrollment(
    client: &Client,
    connection: &mut Connection,
    device: &StoredDevice,
) -> Result<EnrollmentFinish, CliError> {
    let mailbox = create_mailbox(client, connection).await?;
    let key_packages_published = publish_initial_key_packages(client, device, connection).await?;
    Ok(EnrollmentFinish {
        mailbox_id: mailbox.mailbox_id.clone(),
        key_packages_published,
        route: route_string(client, device, &mailbox)?,
    })
}

async fn create_mailbox(
    client: &Client,
    connection: &mut Connection,
) -> Result<OwnMailbox, CliError> {
    match connection.request(Payload::MailboxCreate).await? {
        Payload::MailboxCreated {
            mailbox_id,
            read_capability,
            write_capability,
        } => {
            let mailbox = OwnMailbox {
                mailbox_id,
                read_capability,
                write_capability,
            };
            client
                .mailbox_save(&mailbox)
                .map_err(client_error("mailbox"))?;
            Ok(mailbox)
        }
        other => Err(unexpected(other)),
    }
}

async fn publish_initial_key_packages(
    client: &Client,
    device: &StoredDevice,
    connection: &mut Connection,
) -> Result<usize, CliError> {
    let engine = client.mls_engine(device.mls_identity());
    let mut key_packages = Vec::new();
    for _ in 0..5 {
        let key_package = engine
            .key_package()
            .map_err(protocol_error("key package"))?;
        key_packages.push(serde_bytes::ByteBuf::from(
            key_package
                .to_bytes()
                .map_err(protocol_error("key package"))?,
        ));
    }
    match connection
        .request(Payload::KeyPackagesPublish { key_packages })
        .await?
    {
        Payload::Ack => {}
        other => return Err(unexpected(other)),
    }
    Ok(5)
}

fn record_finish(finish: &EnrollmentFinish) {
    record_change(StateChange::MailboxCreated {
        mailbox_id: finish.mailbox_id.clone(),
    });
    record_change(StateChange::KeyPackagesPublished {
        count: finish.key_packages_published,
    });
    record_change(StateChange::RouteAvailable {
        route: finish.route.clone(),
    });
}

async fn publish_authorization(
    connection: &mut Connection,
    credential: &[u8],
    manifest: &[u8],
    sequence: u64,
) -> Result<(), CliError> {
    match connection
        .request(Payload::ManifestPut {
            manifest: manifest.to_vec(),
        })
        .await?
    {
        Payload::Ack => record_change(StateChange::ManifestPublished { sequence }),
        other => return Err(unexpected(other)),
    }
    match connection
        .request(Payload::CredentialPut {
            credential: credential.to_vec(),
        })
        .await?
    {
        Payload::Ack => record_change(StateChange::CredentialPublished),
        other => return Err(unexpected(other)),
    }
    Ok(())
}

fn pair_timeout() -> Duration {
    let seconds = std::env::var("ARVEIL_PAIR_TIMEOUT_SECS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or(90);
    Duration::from_secs(seconds)
}

fn pairing_deadline(expires_at: u64) -> Result<Instant, CliError> {
    let remaining = expires_at.saturating_sub(now());
    if remaining == 0 {
        return Err(CliError::Domain("pairing session expired".into()));
    }
    Ok(Instant::now() + pair_timeout().min(Duration::from_secs(remaining)))
}

async fn wait_for_slot(
    connection: &mut Connection,
    code: &PairingCode,
    slot: &str,
    what: &str,
    deadline: Instant,
    local_session: Option<(&Client, &[u8])>,
) -> Result<Vec<u8>, CliError> {
    loop {
        match connection
            .request(Payload::PairGet {
                pair_id: code.pair_id.clone(),
                capability: code.capability.clone(),
                slot: slot.to_string(),
            })
            .await?
        {
            Payload::PairFetched { data } if !data.is_empty() => return Ok(data),
            Payload::PairFetched { .. } => {}
            other => return Err(unexpected(other)),
        }
        if let Some((client, session_id)) = local_session
            && client
                .pairing_session(session_id)
                .map_err(client_error("pairing"))?
                .is_none()
        {
            return Err(CliError::Domain("pairing session was cancelled".into()));
        }
        if Instant::now() >= deadline {
            return Err(CliError::Domain(format!(
                "gave up waiting for {what}; the pairing expired or the other device never answered"
            )));
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
}

async fn wait_for_local_slot(
    connection: &mut Connection,
    client: &Client,
    code: &PairingCode,
    slot: &str,
    what: &str,
    deadline: Instant,
    session_id: &[u8],
) -> Result<Vec<u8>, CliError> {
    match wait_for_slot(
        connection,
        code,
        slot,
        what,
        deadline,
        Some((client, session_id)),
    )
    .await
    {
        Ok(data) => Ok(data),
        Err(error) if Instant::now() >= deadline || error.relay_code() == Some(410) => {
            expire_session(client, session_id)?;
            Err(CliError::Domain(format!(
                "pairing session {} expired: {error}",
                hex::encode(session_id)
            )))
        }
        Err(error) => Err(error),
    }
}

async fn put_slot(
    connection: &mut Connection,
    code: &PairingCode,
    slot: &str,
    data: Vec<u8>,
) -> Result<(), CliError> {
    match connection
        .request(Payload::PairPut {
            pair_id: code.pair_id.clone(),
            capability: code.capability.clone(),
            slot: slot.to_string(),
            data,
        })
        .await?
    {
        Payload::Ack => Ok(()),
        other => Err(unexpected(other)),
    }
}

fn exact_session(client: &Client, session_id: &[u8]) -> Result<PairingSessionState, CliError> {
    client
        .pairing_session(session_id)
        .map_err(client_error("pairing"))?
        .ok_or_else(|| {
            CliError::Domain(format!(
                "no pairing session {} is waiting on this device",
                hex::encode(session_id)
            ))
        })
}

fn ensure_not_expired(client: &Client, session: &PairingSessionState) -> Result<(), CliError> {
    if now() < session.expires_at {
        return Ok(());
    }
    expire_session(client, &session.session_id)?;
    Err(CliError::Domain(format!(
        "pairing session {} expired",
        hex::encode(&session.session_id)
    )))
}

fn expire_session(client: &Client, session_id: &[u8]) -> Result<(), CliError> {
    client
        .pairing_session_clear(session_id)
        .map_err(client_error("pairing"))?;
    record_change(StateChange::PairingExpired {
        session_id: session_id.to_vec(),
    });
    Ok(())
}

fn normalize_verification_code(value: &str) -> String {
    value.chars().filter(char::is_ascii_digit).collect()
}
