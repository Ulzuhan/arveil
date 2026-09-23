//! Identity recovery through the same profile executor as enrollment.
use arveil_core::channel::codec::Payload;
use arveil_core::client::operation_digest;
use arveil_core::recovery::{self, IdentityKit, KIT_VERSION, Secret};

use crate::carrier::{Bootstrap, CliError, Connection};
use crate::onboarding::{accept_endpoint_list, client_error, finish_enrollment, now};
use crate::{ProfileConfig, open_client};

pub const MAX_KIT_BYTES: usize = 4 * 1024 * 1024;

#[derive(Clone, PartialEq, Eq)]
pub struct KitExport {
    pub encrypted: Vec<u8>,
    pub secret: String,
}
impl std::fmt::Debug for KitExport {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("KitExport([redacted])")
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct RecoveryRequest {
    pub bootstrap: String,
    pub encrypted: Vec<u8>,
    pub secret: String,
}
impl std::fmt::Debug for RecoveryRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("RecoveryRequest([redacted])")
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RecoveryResult {
    pub identity_id: Vec<u8>,
    pub rollback_warning: bool,
    pub previous_sequence: u64,
    pub kit_sequence: u64,
    pub route: String,
}

pub fn export(config: &ProfileConfig) -> Result<KitExport, CliError> {
    let client = open_client(config)?;
    if client
        .recovery_progress()
        .map_err(client_error("recovery"))?
        .is_some_and(|p| !p.complete)
    {
        return Err(CliError::Domain(
            "finish recovery before exporting a kit".into(),
        ));
    }
    let root = client
        .root()
        .map_err(client_error("identity"))?
        .ok_or_else(|| {
            CliError::Domain("only the administration device can export a kit".into())
        })?;
    let manifest = client
        .latest_manifest()
        .map_err(client_error("manifest"))?
        .ok_or_else(|| CliError::Domain("no manifest to export".into()))?;
    let state = client
        .manifest_state()
        .map_err(client_error("manifest"))?
        .ok_or_else(|| CliError::Domain("no manifest to export".into()))?;
    let kit = IdentityKit {
        version: KIT_VERSION,
        root_seed: root.signing.to_bytes().to_vec(),
        identity_id: root.identity_id(),
        manifest_sequence: state.sequence,
        latest_manifest: manifest,
        exported_at: now(),
    };
    let secret = Secret::generate();
    let encrypted = recovery::kit_seal(&kit, &secret)
        .map_err(|_| CliError::Domain("cannot encrypt identity kit".into()))?;
    Ok(KitExport {
        encrypted,
        secret: secret.to_string_once(),
    })
}

pub async fn restore(
    config: &ProfileConfig,
    request: RecoveryRequest,
) -> Result<RecoveryResult, CliError> {
    if request.encrypted.len() > MAX_KIT_BYTES {
        return Err(CliError::Domain("identity kit is too large".into()));
    }
    let bootstrap = Bootstrap::parse(request.bootstrap.trim())?;
    use tokio_tungstenite::tungstenite::client::IntoClientRequest;
    let url = bootstrap
        .url
        .as_str()
        .into_client_request()
        .map_err(|_| CliError::Domain("invalid relay URL".into()))?;
    if !matches!(url.uri().scheme_str(), Some("ws" | "wss")) {
        return Err(CliError::Domain("relay URL must use ws or wss".into()));
    }
    let secret = Secret::parse(&request.secret)
        .map_err(|_| CliError::Domain("invalid recovery secret".into()))?;
    let kit = recovery::kit_open(&request.encrypted, &secret)
        .map_err(|_| CliError::Domain("cannot decrypt identity kit".into()))?;
    let seed: [u8; 32] = kit
        .root_seed
        .as_slice()
        .try_into()
        .map_err(|_| CliError::Domain("invalid identity kit".into()))?;
    let root = arveil_core::identity::RootKey::from_seed(&seed);
    let (_, manifest) =
        arveil_core::identity::accept_manifest(&kit.latest_manifest, &root.public(), None)
            .map_err(|_| CliError::Domain("invalid kit manifest".into()))?;
    if root.identity_id() != kit.identity_id || manifest.sequence != kit.manifest_sequence {
        return Err(CliError::Domain("inconsistent identity kit".into()));
    }
    let binding = arveil_core::signed::canonical(&(
        &kit.root_seed,
        &kit.latest_manifest,
        request.bootstrap.trim(),
    ))
    .map_err(crate::domain_error("recovery request"))?;
    let digest = operation_digest(&binding);
    let client = open_client(config)?;
    if let Some(progress) = client
        .recovery_progress()
        .map_err(client_error("recovery"))?
    {
        if progress.request_digest != digest {
            return Err(CliError::Domain(
                "another recovery is already stored in this profile".into(),
            ));
        }
    } else {
        // Nothing is durable until all local preparation, including its
        // operation marker, commits. No network call runs inside this unit.
        let realm = arveil_core::client::StoredRealm {
            realm_id: bootstrap.realm_id,
            signing_public: bootstrap.signing_key,
            noise_public: bootstrap.noise_public,
            bootstrap_url: bootstrap.url,
            endpoint_list: None,
            enrolled: false,
        };
        client
            .recovery_prepare(&kit, &digest, &realm, now())
            .map_err(client_error("restore"))?;
    }
    Box::pin(resume(config)).await
}

pub async fn resume(config: &ProfileConfig) -> Result<RecoveryResult, CliError> {
    let client = open_client(config)?;
    let progress = client
        .recovery_progress()
        .map_err(client_error("recovery"))?
        .ok_or_else(|| CliError::Domain("no recovery to resume".into()))?;
    let identity_id = client
        .identity_id()
        .map_err(client_error("identity"))?
        .ok_or_else(|| CliError::Domain("recovery has no identity".into()))?;
    if progress.complete {
        let device = client
            .device()
            .map_err(client_error("device"))?
            .ok_or_else(|| CliError::Domain("recovery has no device".into()))?;
        let mailbox = client
            .mailbox_own()
            .map_err(client_error("mailbox"))?
            .ok_or_else(|| CliError::Domain("recovery has no mailbox".into()))?;
        return Ok(RecoveryResult {
            previous_sequence: progress
                .previous_sequence
                .ok_or_else(|| CliError::Domain("recovery has no receipt".into()))?,
            kit_sequence: progress.kit_sequence,
            route: crate::route_string(&client, &device, &mailbox)?,
            identity_id,
            rollback_warning: progress
                .previous_sequence
                .is_some_and(|n| n < progress.kit_sequence),
        });
    }
    let realm = client
        .realm()
        .map_err(client_error("realm"))?
        .ok_or_else(|| CliError::Domain("recovery has no realm".into()))?;
    let device = client
        .device()
        .map_err(client_error("device"))?
        .ok_or_else(|| CliError::Domain("recovery has no device".into()))?;
    let mut connection = Connection::open(
        &realm.bootstrap_url,
        &realm.realm_id,
        &realm.noise_public,
        &device.keys.transport_noise,
        config.tls_ca(),
    )
    .await?;
    let previous = if let Some(previous) = progress.previous_sequence {
        previous
    } else {
        let manifest = client
            .latest_manifest()
            .map_err(client_error("manifest"))?
            .ok_or_else(|| CliError::Domain("recovery has no manifest".into()))?;
        match connection
            .request(Payload::RecoverIdentity {
                credential: device.credential.clone(),
                manifest,
            })
            .await?
        {
            Payload::Recovered {
                identity_id: recovered,
                previous_sequence,
            } if recovered == identity_id => {
                client
                    .recovery_accepted(previous_sequence)
                    .map_err(client_error("recovery"))?;
                previous_sequence
            }
            _ => return Err(CliError::Protocol("unexpected recovery reply".into())),
        }
    };
    let bootstrap = Bootstrap {
        realm_id: realm.realm_id.clone(),
        signing_key: realm.signing_public,
        noise_public: realm.noise_public.clone(),
        url: realm.bootstrap_url.clone(),
    };
    accept_endpoint_list(&client, &bootstrap, &mut connection).await?;
    client
        .realm_mark_enrolled(&realm.realm_id)
        .map_err(client_error("realm"))?;
    let finish = finish_enrollment(&client, &mut connection, &device).await?;
    client
        .recovery_complete()
        .map_err(client_error("recovery"))?;
    connection.close().await;
    Ok(RecoveryResult {
        identity_id,
        rollback_warning: previous < progress.kit_sequence,
        previous_sequence: previous,
        kit_sequence: progress.kit_sequence,
        route: finish.route,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Application, ApplicationError};
    use arveil_core::identity::RootKey;

    fn directory(label: &str) -> std::path::PathBuf {
        let mut nonce = [0u8; 12];
        getrandom::fill(&mut nonce).unwrap();
        std::env::temp_dir().join(format!("arveil-recovery-{label}-{}", hex::encode(nonce)))
    }

    #[test]
    fn kit_is_private_and_failed_restore_resumes_same_identity_after_reopen() {
        let source = directory("source");
        let target = directory("target");
        let source_config = ProfileConfig::encrypted(&source, "ab".repeat(32)).unwrap();
        let admin = Application::open(source_config.clone()).unwrap();
        admin.create_identity().unwrap();
        open_client(&source_config)
            .unwrap()
            .device_new(now())
            .unwrap();
        let kit = admin.export_kit().unwrap();
        assert!(kit.encrypted.starts_with(b"age-encryption.org/v1"));
        assert!(!format!("{kit:?}").contains(&kit.secret));
        let realm = RootKey::generate().unwrap();
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        drop(listener);
        let bootstrap = format!(
            "arveil-bootstrap:v0:{}:{}:{}:ws://127.0.0.1:{port}/ws",
            "07".repeat(32),
            hex::encode(realm.public().as_bytes()),
            "08".repeat(32)
        );
        let config = ProfileConfig::encrypted(&target, "cd".repeat(32)).unwrap();
        let app = Application::open(config.clone()).unwrap();
        let request = RecoveryRequest {
            bootstrap,
            encrypted: kit.encrypted.clone(),
            secret: kit.secret.clone(),
        };
        assert!(!format!("{request:?}").contains(&kit.secret));
        let mut wrong = request.clone();
        wrong.secret = Secret::generate().to_string_once();
        assert!(matches!(
            app.restore_kit(wrong),
            Err(ApplicationError::Domain { .. })
        ));
        assert!(app.onboarding_status().unwrap().identity_id.is_none());
        let first = app.restore_kit(request.clone());
        assert!(
            matches!(first, Err(ApplicationError::Transport { .. })),
            "{first:?}"
        );
        let status = app.onboarding_status().unwrap();
        assert!(status.recovering);
        assert!(!status.ready);
        assert_eq!(
            status.identity_id,
            admin.onboarding_status().unwrap().identity_id
        );
        let device = open_client(&config)
            .unwrap()
            .device()
            .unwrap()
            .unwrap()
            .credential;
        assert!(app.export_kit().is_err());
        app.close();
        let reopened = Application::open(config.clone()).unwrap();
        assert!(reopened.onboarding_status().unwrap().recovering);
        assert!(matches!(
            reopened.resume_recovery(),
            Err(ApplicationError::Transport { .. })
        ));
        assert!(matches!(
            reopened.restore_kit(request.clone()),
            Err(ApplicationError::Transport { .. })
        ));
        assert_eq!(
            open_client(&config)
                .unwrap()
                .device()
                .unwrap()
                .unwrap()
                .credential,
            device
        );
        let mut changed = request;
        changed.bootstrap.push_str("/other");
        assert!(matches!(
            reopened.restore_kit(changed),
            Err(ApplicationError::Domain { .. })
        ));
        assert_eq!(
            open_client(&config)
                .unwrap()
                .device()
                .unwrap()
                .unwrap()
                .credential,
            device
        );
        reopened.close();
        admin.close();
        std::fs::remove_dir_all(source).unwrap();
        std::fs::remove_dir_all(target).unwrap();
    }
}
