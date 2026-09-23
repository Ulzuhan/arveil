//! Availability is a dated observation from the relay, not a delivery promise.
use arveil_core::channel::codec::Payload;
use arveil_core::client::{Client, KEY_PACKAGE_FLOOR, KEY_PACKAGE_TARGET, StoredDevice};

use crate::carrier::{Bootstrap, CliError, Connection};
use crate::onboarding::{client_error, now};
use crate::{ProfileConfig, StateChange, record_change};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KeyPackageLevel {
    Unknown,
    Empty,
    Low,
    Ready,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct KeyPackageSupply {
    pub available: Option<u32>,
    pub checked_at: Option<u64>,
    pub level: KeyPackageLevel,
    pub publication_pending: bool,
    pub target: u32,
}

pub fn snapshot(config: &ProfileConfig) -> Result<KeyPackageSupply, CliError> {
    let (client, device, _) = crate::enrolled(config)?;
    local(&client, &device)
}

fn local(client: &Client, device: &StoredDevice) -> Result<KeyPackageSupply, CliError> {
    let observation = client
        .key_package_observation(&device.keys.device_id)
        .map_err(client_error("key packages"))?;
    let available = observation.as_ref().map(|o| o.available);
    Ok(KeyPackageSupply {
        available,
        checked_at: observation.map(|o| o.checked_at),
        level: match available {
            None => KeyPackageLevel::Unknown,
            Some(0) => KeyPackageLevel::Empty,
            Some(n) if n <= KEY_PACKAGE_FLOOR => KeyPackageLevel::Low,
            Some(_) => KeyPackageLevel::Ready,
        },
        publication_pending: client
            .pending_key_packages(&device.keys.device_id)
            .map_err(client_error("key packages"))?
            .is_some(),
        target: KEY_PACKAGE_TARGET,
    })
}

pub async fn update(config: &ProfileConfig, replenish: bool) -> Result<KeyPackageSupply, CliError> {
    let (session, _) = crate::session(config)?;
    let bootstrap = Bootstrap {
        realm_id: session.realm.realm_id.clone(),
        signing_key: session.realm.signing_public,
        noise_public: session.realm.noise_public.clone(),
        url: session.realm.bootstrap_url.clone(),
    };
    let mut connection = crate::connect(config, &session, &bootstrap).await?;
    let result = maintain(&session.client, &session.device, &mut connection, replenish).await;
    connection.close().await;
    result
}

async fn observe(
    client: &Client,
    device: &StoredDevice,
    connection: &mut Connection,
) -> Result<u32, CliError> {
    let available = match connection.request(Payload::KeyPackagesStatus).await? {
        Payload::KeyPackagesAvailable { count } => count,
        _ => {
            return Err(CliError::Protocol(
                "unexpected key package status reply".into(),
            ));
        }
    };
    client
        .key_package_observe(&device.keys.device_id, available, now())
        .map_err(client_error("key packages"))?;
    Ok(available)
}

pub(super) async fn maintain(
    client: &Client,
    device: &StoredDevice,
    connection: &mut Connection,
    replenish: bool,
) -> Result<KeyPackageSupply, CliError> {
    let available = observe(client, device, connection).await?;
    if replenish
        && let Some(batch) = client
            .prepare_key_package_replenishment(device, available)
            .map_err(client_error("key packages"))?
    {
        let count = batch.packages.len();
        let key_packages = batch
            .packages
            .into_iter()
            .map(serde_bytes::ByteBuf::from)
            .collect();
        match connection
            .request(Payload::KeyPackagesPublish { key_packages })
            .await?
        {
            Payload::Ack => {
                client
                    .key_package_replenishment_acknowledged(&device.keys.device_id)
                    .map_err(client_error("key packages"))?;
                record_change(StateChange::KeyPackagesReplenished {
                    previous: batch.previous,
                    published: count,
                });
            }
            _ => {
                return Err(CliError::Protocol(
                    "unexpected key package publication reply".into(),
                ));
            }
        }
        // A concurrent claim can consume packages while publication runs.
        // Ask again instead of presenting `previous + published` as fact.
        observe(client, device, connection).await?;
    }
    local(client, device)
}
