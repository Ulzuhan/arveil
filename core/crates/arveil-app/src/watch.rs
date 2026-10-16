//! Activity notices from the relay (ADR-014).
//!
//! A device registers a watch key: a separate Noise key whose sessions may
//! only wait for notices. A platform service keeps one such session open
//! with the profile closed, and shows a generic notification when the relay
//! says that a mailbox of this device stopped being empty. The notice names
//! nothing; the profile still fetches, verifies and decrypts as usual.
use std::fmt;
use std::path::Path;
use std::time::Duration;

use arveil_core::channel::StaticKeypair;
use arveil_core::channel::codec::Payload;

use crate::ProfileConfig;
use crate::carrier::{Bootstrap, CliError, Connection};

/// What a platform service needs to wait for notices with the profile
/// closed: which realm, where, and a key that can only watch. The platform
/// keeps it (on Android, encrypted under a Keystore key); it never enters
/// the profile, its backups or its exports.
#[derive(Clone, PartialEq, Eq)]
pub struct WatchCredentials {
    pub realm_id: Vec<u8>,
    pub realm_noise_public: Vec<u8>,
    /// Channel URLs in the order to try them.
    pub endpoints: Vec<String>,
    pub watch_private: Vec<u8>,
    pub watch_public: Vec<u8>,
}

impl fmt::Debug for WatchCredentials {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("WatchCredentials")
            .field("realm_id", &hex::encode(&self.realm_id))
            .field("endpoints", &self.endpoints)
            .field("watch_public", &hex::encode(&self.watch_public))
            .finish_non_exhaustive()
    }
}

impl WatchCredentials {
    fn keypair(&self) -> StaticKeypair {
        StaticKeypair {
            private: self.watch_private.clone(),
            public: self.watch_public.clone(),
        }
    }
}

/// Generate a watch key and register it for this device, replacing any
/// previous one. Returns the credentials for the platform to keep.
pub async fn register(config: &ProfileConfig) -> Result<WatchCredentials, CliError> {
    let (session, _) = crate::session(config)?;
    let bootstrap = Bootstrap {
        realm_id: session.realm.realm_id.clone(),
        signing_key: session.realm.signing_public,
        noise_public: session.realm.noise_public.clone(),
        url: session.realm.bootstrap_url.clone(),
    };
    let key =
        StaticKeypair::generate().map_err(|e| CliError::Internal(format!("watch key: {e}")))?;
    let mut connection = crate::connect(config, &session, &bootstrap).await?;
    let result = connection
        .request(Payload::WatchKeySet {
            key: key.public.clone(),
        })
        .await;
    connection.close().await;
    match result? {
        Payload::Ack => Ok(WatchCredentials {
            realm_id: bootstrap.realm_id.clone(),
            realm_noise_public: bootstrap.noise_public.clone(),
            endpoints: crate::endpoint_candidates(&session, &bootstrap),
            watch_private: key.private,
            watch_public: key.public,
        }),
        other => Err(CliError::Protocol(format!(
            "unexpected reply to WatchKeySet: {other:?}"
        ))),
    }
}

/// Remove this device's watch key from the realm, which also ends any
/// session waiting with it.
pub async fn clear(config: &ProfileConfig) -> Result<(), CliError> {
    let (session, _) = crate::session(config)?;
    let bootstrap = Bootstrap {
        realm_id: session.realm.realm_id.clone(),
        signing_key: session.realm.signing_public,
        noise_public: session.realm.noise_public.clone(),
        url: session.realm.bootstrap_url.clone(),
    };
    let mut connection = crate::connect(config, &session, &bootstrap).await?;
    let result = connection
        .request(Payload::WatchKeySet { key: Vec::new() })
        .await;
    connection.close().await;
    match result? {
        Payload::Ack => Ok(()),
        other => Err(CliError::Protocol(format!(
            "unexpected reply to WatchKeySet: {other:?}"
        ))),
    }
}

/// Open a watch session through the first endpoint that answers, subscribe,
/// and call `on_wakeup` for every notice until it returns false. Pings when
/// `keepalive` passes in silence. Any error ends the session; reconnecting,
/// with a backoff, is the caller's choice.
pub async fn run(
    credentials: &WatchCredentials,
    tls_ca: Option<&Path>,
    keepalive: Duration,
    mut on_wakeup: impl FnMut() -> bool,
) -> Result<(), CliError> {
    let key = credentials.keypair();
    let mut last = CliError::Transport("no endpoints".into());
    let mut connection = None;
    for url in &credentials.endpoints {
        match Connection::open(
            url,
            &credentials.realm_id,
            &credentials.realm_noise_public,
            &key,
            tls_ca,
        )
        .await
        {
            Ok(c) => {
                connection = Some(c);
                break;
            }
            Err(e) => last = e,
        }
    }
    let Some(mut connection) = connection else {
        return Err(last);
    };
    connection.pad_frames();
    connection.watch().await?;
    loop {
        connection.next_wakeup(keepalive).await?;
        if !on_wakeup() {
            connection.close().await;
            return Ok(());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn debug_never_shows_the_private_key() {
        let credentials = WatchCredentials {
            realm_id: vec![1; 32],
            realm_noise_public: vec![2; 32],
            endpoints: vec!["ws://127.0.0.1:8447/v1/channel".into()],
            watch_private: vec![0xAB; 32],
            watch_public: vec![3; 32],
        };
        let shown = format!("{credentials:?}");
        assert!(!shown.contains(&hex::encode([0xAB; 32])));
        assert!(!shown.contains("171, 171"));
    }
}
