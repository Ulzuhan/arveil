//! Activity notices from the relay (ADR-014).
//!
//! A device registers a watch key: a separate Noise key whose sessions may
//! only wait for notices. A platform service keeps one such session open
//! with the profile closed, and shows a generic notification when the relay
//! says that a mailbox of this device stopped being empty. The notice names
//! nothing; the profile still fetches, verifies and decrypts as usual.
//!
//! An open profile can wait the same way on a member session, with the
//! device's own transport key ([`member`]), instead of polling.
use std::fmt;
use std::path::{Path, PathBuf};
use std::time::Duration;

use arveil_core::channel::StaticKeypair;
use arveil_core::channel::codec::Payload;
use serde::{Deserialize, Serialize};

use crate::ProfileConfig;
use crate::carrier::{Bootstrap, CliError, Connection};

/// Version of [`WatchCredentials::to_bytes`].
const CREDENTIALS_VERSION: u8 = 1;
/// More endpoints than any realm signs, and longer URLs than any carrier needs.
const MAX_ENDPOINTS: usize = 8;
const MAX_URL: usize = 512;

/// What a session needs to wait for notices: which realm, where, and the
/// static key to open it with. For a platform service that key can only
/// watch; the platform keeps these credentials (on Android, encrypted under
/// a Keystore key), and they never enter the profile, its backups or its
/// exports.
#[derive(Clone, PartialEq, Eq)]
pub struct WatchCredentials {
    pub realm_id: Vec<u8>,
    pub realm_noise_public: Vec<u8>,
    /// Channel URLs in the order to try them.
    pub endpoints: Vec<String>,
    pub watch_private: Vec<u8>,
    pub watch_public: Vec<u8>,
    /// Extra certificate authority for a self-signed test proxy. Local
    /// configuration, never part of [`WatchCredentials::to_bytes`].
    pub tls_ca: Option<PathBuf>,
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

#[derive(Serialize, Deserialize)]
struct Wire {
    version: u8,
    #[serde(with = "serde_bytes")]
    realm_id: Vec<u8>,
    #[serde(with = "serde_bytes")]
    realm_noise_public: Vec<u8>,
    endpoints: Vec<String>,
    #[serde(with = "serde_bytes")]
    watch_private: Vec<u8>,
    #[serde(with = "serde_bytes")]
    watch_public: Vec<u8>,
}

impl WatchCredentials {
    fn keypair(&self) -> StaticKeypair {
        StaticKeypair {
            private: self.watch_private.clone(),
            public: self.watch_public.clone(),
        }
    }

    /// Deterministic CBOR for the platform to store and hand back.
    pub fn to_bytes(&self) -> Result<Vec<u8>, CliError> {
        arveil_core::signed::canonical(&Wire {
            version: CREDENTIALS_VERSION,
            realm_id: self.realm_id.clone(),
            realm_noise_public: self.realm_noise_public.clone(),
            endpoints: self.endpoints.clone(),
            watch_private: self.watch_private.clone(),
            watch_public: self.watch_public.clone(),
        })
        .map_err(|e| CliError::Internal(format!("watch credentials: {e}")))
    }

    /// Read what [`WatchCredentials::to_bytes`] wrote, refusing anything
    /// that is not exactly that shape.
    pub fn from_bytes(bytes: &[u8]) -> Result<Self, CliError> {
        let invalid = || CliError::Domain("invalid watch credentials".into());
        if bytes.len() > 8192 {
            return Err(invalid());
        }
        let wire: Wire = ciborium::from_reader(bytes).map_err(|_| invalid())?;
        let urls_ok = !wire.endpoints.is_empty()
            && wire.endpoints.len() <= MAX_ENDPOINTS
            && wire.endpoints.iter().all(|url| {
                url.len() <= MAX_URL && (url.starts_with("ws://") || url.starts_with("wss://"))
            });
        if wire.version != CREDENTIALS_VERSION
            || wire.realm_id.len() != 32
            || wire.realm_noise_public.len() != 32
            || wire.watch_private.len() != 32
            || wire.watch_public.len() != 32
            || !urls_ok
        {
            return Err(invalid());
        }
        Ok(Self {
            realm_id: wire.realm_id,
            realm_noise_public: wire.realm_noise_public,
            endpoints: wire.endpoints,
            watch_private: wire.watch_private,
            watch_public: wire.watch_public,
            tls_ca: None,
        })
    }
}

fn bootstrap_of(session: &crate::Session) -> Bootstrap {
    Bootstrap {
        realm_id: session.realm.realm_id.clone(),
        signing_key: session.realm.signing_public,
        noise_public: session.realm.noise_public.clone(),
        url: session.realm.bootstrap_url.clone(),
    }
}

/// Generate a watch key and register it for this device, replacing any
/// previous one. Returns the credentials for the platform to keep.
pub async fn register(config: &ProfileConfig) -> Result<WatchCredentials, CliError> {
    let (session, _) = crate::session(config)?;
    let bootstrap = bootstrap_of(&session);
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
            tls_ca: config.tls_ca().map(Path::to_path_buf),
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
    let bootstrap = bootstrap_of(&session);
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

/// Credentials for waiting on a member session with this device's own
/// transport key, as an open profile does. Nothing is registered and
/// nothing leaves the process.
pub fn member(config: &ProfileConfig) -> Result<WatchCredentials, CliError> {
    let (session, _) = crate::session(config)?;
    let bootstrap = bootstrap_of(&session);
    Ok(WatchCredentials {
        realm_id: bootstrap.realm_id.clone(),
        realm_noise_public: bootstrap.noise_public.clone(),
        endpoints: crate::endpoint_candidates(&session, &bootstrap),
        watch_private: session.device.keys.transport_noise.private.clone(),
        watch_public: session.device.keys.transport_noise.public.clone(),
        tls_ca: config.tls_ca().map(Path::to_path_buf),
    })
}

/// What a waiting session reports.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WatchEvent {
    /// Subscribed: from now on, new mail is announced. Mail already waiting
    /// is announced right after.
    Listening,
    /// A mailbox of this device stopped being empty.
    Activity,
    /// The session ended for a reason that is worth retrying; [`serve`]
    /// reconnects after a pause.
    Disconnected,
}

/// Why [`serve`] returned.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Ended {
    /// `stop` said so, or `on_event` returned false.
    Stopped,
    /// The realm refused these credentials; they need renewing.
    Refused,
}

const FIRST_PAUSE: Duration = Duration::from_secs(1);
const LONGEST_PAUSE: Duration = Duration::from_secs(60);
const STOP_CHECK: Duration = Duration::from_millis(250);

/// Wait for notices until stopped, reconnecting with a growing pause
/// (1 s doubling to 60 s, back to 1 s once subscribed) after any failure
/// worth retrying. Blocks the calling thread on a runtime of its own, so a
/// platform thread can own it. `stop` is checked a few times a second, also
/// while a session waits.
pub fn serve(
    credentials: &WatchCredentials,
    keepalive: Duration,
    stop: &(dyn Fn() -> bool + Sync),
    mut on_event: impl FnMut(WatchEvent) -> bool,
) -> Ended {
    let Ok(runtime) = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    else {
        return Ended::Stopped;
    };
    runtime.block_on(async {
        let stopped = async {
            while !stop() {
                tokio::time::sleep(STOP_CHECK).await;
            }
        };
        tokio::pin!(stopped);
        let mut pause = FIRST_PAUSE;
        loop {
            let mut keep = true;
            let result = tokio::select! {
                result = run(credentials, keepalive, |event| {
                    if event == WatchEvent::Listening {
                        pause = FIRST_PAUSE;
                    }
                    keep = on_event(event);
                    keep
                }) => result,
                () = &mut stopped => return Ended::Stopped,
            };
            match result {
                _ if !keep => return Ended::Stopped,
                Ok(()) => return Ended::Stopped,
                Err(error) if refused(&error) => return Ended::Refused,
                Err(_) => {}
            }
            if !on_event(WatchEvent::Disconnected) {
                return Ended::Stopped;
            }
            tokio::select! {
                () = tokio::time::sleep(pause) => {}
                () = &mut stopped => return Ended::Stopped,
            }
            pause = (pause * 2).min(LONGEST_PAUSE);
        }
    })
}

/// Open a session through the first endpoint that answers, subscribe, and
/// report to `on_event` until it returns false. Pings when `keepalive`
/// passes in silence. Any error ends the session; reconnecting, with a
/// backoff, is the caller's choice.
pub async fn run(
    credentials: &WatchCredentials,
    keepalive: Duration,
    mut on_event: impl FnMut(WatchEvent) -> bool,
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
            credentials.tls_ca.as_deref(),
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
    let mut event = WatchEvent::Listening;
    loop {
        if !on_event(event) {
            connection.close().await;
            return Ok(());
        }
        connection.next_wakeup(keepalive).await?;
        event = WatchEvent::Activity;
    }
}

/// Whether a failure means the credentials themselves were refused, so
/// reconnecting with them is pointless until they are renewed.
pub fn refused(error: &CliError) -> bool {
    match error {
        CliError::Relay { code, .. } => matches!(code, 401 | 403),
        // A watch key the realm no longer knows opens a provisional session,
        // whose MailboxWatch is refused; a revoked device's handshake is
        // closed as a policy violation before message 2.
        CliError::Transport(message) => {
            message.contains("handshake refused") || message.contains("Policy")
        }
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> WatchCredentials {
        WatchCredentials {
            realm_id: vec![1; 32],
            realm_noise_public: vec![2; 32],
            endpoints: vec!["ws://127.0.0.1:8447/v1/channel".into()],
            watch_private: vec![0xAB; 32],
            watch_public: vec![3; 32],
            tls_ca: None,
        }
    }

    #[test]
    fn debug_never_shows_the_private_key() {
        let shown = format!("{:?}", sample());
        assert!(!shown.contains(&hex::encode([0xAB; 32])));
        assert!(!shown.contains("171, 171"));
    }

    #[test]
    fn credentials_round_trip_and_refuse_other_shapes() {
        let bytes = sample().to_bytes().unwrap();
        assert_eq!(WatchCredentials::from_bytes(&bytes).unwrap(), sample());
        let mut tls = sample();
        tls.tls_ca = Some(PathBuf::from("/tmp/ca.pem"));
        assert_eq!(
            tls.to_bytes().unwrap(),
            bytes,
            "a local CA path is not exported"
        );

        for change in [
            |c: &mut WatchCredentials| c.watch_private.truncate(31),
            |c: &mut WatchCredentials| c.realm_id.push(0),
            |c: &mut WatchCredentials| c.endpoints.clear(),
            |c: &mut WatchCredentials| c.endpoints = vec!["https://example.org/".into()],
            |c: &mut WatchCredentials| c.endpoints = vec!["ws://x".into(); MAX_ENDPOINTS + 1],
        ] {
            let mut bad = sample();
            change(&mut bad);
            assert!(WatchCredentials::from_bytes(&bad.to_bytes().unwrap()).is_err());
        }
        assert!(WatchCredentials::from_bytes(b"not cbor").is_err());
        assert!(WatchCredentials::from_bytes(&vec![0; 9000]).is_err());
    }
}
