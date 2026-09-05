//! WebSocket carrier for the application layer: connect, run the Noise handshake with a
//! given device static key, and exchange frames.

use std::fmt;
use std::future::Future;
use std::time::Duration;

use arveil_core::channel::codec::{Frame, Payload};
use arveil_core::channel::{Channel, Initiator, StaticKeypair, prologue};
use ed25519_dalek::VerifyingKey;
use futures_util::{SinkExt, StreamExt};
use tokio_tungstenite::tungstenite::Message;

/// Parsed `arveil-bootstrap:v0:<realm_id>:<signing_pub>:<noise_pub>:<url>`.
pub struct Bootstrap {
    pub realm_id: Vec<u8>,
    pub signing_key: VerifyingKey,
    pub noise_public: Vec<u8>,
    pub url: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FailureKind {
    Transport,
    Storage,
    Protocol,
    Domain,
    FileSystem,
    Internal,
}

#[derive(Debug)]
pub enum CliError {
    Transport(String),
    Storage(String),
    Protocol(String),
    Relay { code: u16, message: String },
    Domain(String),
    FileSystem(String),
    Internal(String),
    Interrupted { exit_code: u8, message: String },
}

#[allow(non_snake_case)]
pub fn CliError(message: String) -> CliError {
    CliError::Internal(message)
}

impl CliError {
    pub fn kind(&self) -> FailureKind {
        match self {
            Self::Transport(_) => FailureKind::Transport,
            Self::Storage(_) => FailureKind::Storage,
            Self::Protocol(_) => FailureKind::Protocol,
            Self::Relay {
                code: 401 | 403 | 410,
                ..
            } => FailureKind::Domain,
            Self::Relay { .. } => FailureKind::Protocol,
            Self::Domain(_) => FailureKind::Domain,
            Self::FileSystem(_) => FailureKind::FileSystem,
            Self::Internal(_) => FailureKind::Internal,
            Self::Interrupted { .. } => FailureKind::Internal,
        }
    }

    pub fn message(&self) -> &str {
        match self {
            Self::Transport(message)
            | Self::Storage(message)
            | Self::Protocol(message)
            | Self::Domain(message)
            | Self::FileSystem(message)
            | Self::Internal(message) => message,
            Self::Relay { message, .. } => message,
            Self::Interrupted { message, .. } => message,
        }
    }

    pub fn relay_code(&self) -> Option<u16> {
        match self {
            Self::Relay { code, .. } => Some(*code),
            _ => None,
        }
    }
}

impl fmt::Display for CliError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Relay { code, message } => write!(f, "relay refused ({code}): {message}"),
            _ => f.write_str(self.message()),
        }
    }
}

impl std::error::Error for CliError {}

impl From<rusqlite::Error> for CliError {
    fn from(e: rusqlite::Error) -> Self {
        CliError::Storage(format!("sqlite: {e}"))
    }
}

pub fn err<E: fmt::Display>(context: &str) -> impl FnOnce(E) -> CliError + '_ {
    move |e| CliError::Internal(format!("{context}: {e}"))
}

fn transport<E: fmt::Display>(context: &str) -> impl FnOnce(E) -> CliError + '_ {
    move |error| CliError::Transport(format!("{context}: {error}"))
}

fn domain<E: fmt::Display>(context: &str) -> impl FnOnce(E) -> CliError + '_ {
    move |error| CliError::Domain(format!("{context}: {error}"))
}

fn filesystem<E: fmt::Display>(context: &str) -> impl FnOnce(E) -> CliError + '_ {
    move |error| CliError::FileSystem(format!("{context}: {error}"))
}

impl Bootstrap {
    pub fn parse(s: &str) -> Result<Self, CliError> {
        let parts: Vec<&str> = s.splitn(6, ':').collect();
        if parts.len() != 6 || parts[0] != "arveil-bootstrap" || parts[1] != "v0" {
            return Err(CliError::Domain("not an arveil-bootstrap:v0 string".into()));
        }
        let realm_id = hex::decode(parts[2]).map_err(domain("realm id"))?;
        let signing: [u8; 32] = hex::decode(parts[3])
            .map_err(domain("signing key"))?
            .try_into()
            .map_err(|_| CliError::Domain("signing key must be 32 bytes".into()))?;
        let signing_key = VerifyingKey::from_bytes(&signing).map_err(domain("signing key"))?;
        let noise_public = hex::decode(parts[4]).map_err(domain("noise key"))?;
        if noise_public.len() != 32 {
            return Err(CliError::Domain("noise key must be 32 bytes".into()));
        }
        Ok(Self {
            realm_id,
            signing_key,
            noise_public,
            url: parts[5].to_string(),
        })
    }
}

type Ws =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

/// An open channel over a WebSocket.
pub struct Connection {
    ws: Option<Ws>,
    channel: Option<Channel>,
    next_id: u64,
    request_timeout: Duration,
}

#[derive(Clone, Copy)]
struct TransportTimeouts {
    connect: Duration,
    handshake: Duration,
    request: Duration,
    close: Duration,
}

impl Default for TransportTimeouts {
    fn default() -> Self {
        Self {
            connect: Duration::from_secs(10),
            handshake: Duration::from_secs(10),
            request: Duration::from_secs(30),
            close: Duration::from_secs(2),
        }
    }
}

fn timed_out(phase: &str, after: Duration) -> CliError {
    CliError::Transport(format!(
        "{phase} timed out after {} ms; operation cancelled",
        after.as_millis()
    ))
}

async fn bounded<T>(
    phase: &str,
    after: Duration,
    future: impl Future<Output = T>,
) -> Result<T, CliError> {
    tokio::time::timeout(after, future)
        .await
        .map_err(|_| timed_out(phase, after))
}

impl Connection {
    /// Connect to `url` and complete the handshake as `device` against a
    /// realm identified by `realm_id` and `realm_noise_public`.
    pub async fn open(
        url: &str,
        realm_id: &[u8],
        realm_noise_public: &[u8],
        device: &StaticKeypair,
        tls_ca: Option<&std::path::Path>,
    ) -> Result<Self, CliError> {
        Self::open_with_timeouts(
            url,
            realm_id,
            realm_noise_public,
            device,
            tls_ca,
            TransportTimeouts::default(),
        )
        .await
    }

    async fn open_with_timeouts(
        url: &str,
        realm_id: &[u8],
        realm_noise_public: &[u8],
        device: &StaticKeypair,
        tls_ca: Option<&std::path::Path>,
        timeouts: TransportTimeouts,
    ) -> Result<Self, CliError> {
        let (mut ws, _) = bounded(
            "connection",
            timeouts.connect,
            tokio_tungstenite::connect_async_tls_with_config(
                url,
                None,
                false,
                Some(tls_connector(tls_ca)?),
            ),
        )
        .await?
        .map_err(transport("connect"))?;
        let mut init = Initiator::new(device, realm_noise_public, &prologue(realm_id))
            .map_err(transport("noise"))?;
        let m1 = init.write_message_1().map_err(transport("noise"))?;
        let transport = bounded("handshake", timeouts.handshake, async {
            ws.send(Message::Binary(m1.into()))
                .await
                .map_err(transport("send m1"))?;
            let m2 = next_binary(&mut ws).await?;
            init.read_message_2(&m2).map_err(transport(
                "handshake refused (wrong realm key, prologue, or revoked device?)",
            ))
        })
        .await??;
        Ok(Self {
            ws: Some(ws),
            channel: Some(Channel::new(transport)),
            next_id: 1,
            request_timeout: timeouts.request,
        })
    }

    /// Send a payload and wait for the reply with the same id.
    pub async fn request(&mut self, payload: Payload) -> Result<Payload, CliError> {
        if self.ws.is_none() || self.channel.is_none() {
            return Err(CliError::Transport(
                "connection invalidated; reconnect required".into(),
            ));
        }
        let timeout = self.request_timeout;
        match tokio::time::timeout(timeout, self.request_inner(payload)).await {
            Ok(result) => result,
            Err(_) => {
                // Cancelling a write/read future can leave both WebSocket
                // framing and the Noise nonce out of sync. Drop both sides
                // of the carrier so no late reply reaches another request.
                self.ws.take();
                self.channel.take();
                Err(timed_out("request", timeout))
            }
        }
    }

    async fn request_inner(&mut self, payload: Payload) -> Result<Payload, CliError> {
        let id = self.next_id;
        self.next_id += 1;
        let frame = Frame { id, payload };
        let messages = self
            .channel
            .as_mut()
            .expect("request checked the channel")
            .seal(&frame)
            .map_err(transport("seal"))?;
        for m in messages {
            self.ws
                .as_mut()
                .expect("request checked the socket")
                .send(Message::Binary(m.into()))
                .await
                .map_err(transport("send"))?;
        }
        loop {
            let m = next_binary(self.ws.as_mut().expect("request checked the socket")).await?;
            if let Some(f) = self
                .channel
                .as_mut()
                .expect("request checked the channel")
                .open(&m)
                .map_err(transport("open"))?
            {
                if f.id != id {
                    return Err(CliError::Protocol(format!(
                        "reply id {} for request {id}",
                        f.id
                    )));
                }
                return match f.payload {
                    Payload::Error { code, message } => Err(CliError::Relay { code, message }),
                    p => Ok(p),
                };
            }
        }
    }

    pub fn remote_static(&self) -> Result<&[u8], CliError> {
        self.channel
            .as_ref()
            .map(|channel| channel.remote_static())
            .ok_or_else(|| CliError::Transport("connection invalidated; reconnect required".into()))
    }

    pub async fn close(mut self) {
        if let Some(mut ws) = self.ws.take() {
            let _ = bounded(
                "connection close",
                TransportTimeouts::default().close,
                ws.close(None),
            )
            .await;
        }
    }
}

/// TLS is the carrier's concern (ADR-008): WebPKI roots, plus the extra PEM
/// certificate authority the profile configuration names, which is how a
/// self-signed proxy is trusted in a test.
fn tls_connector(
    tls_ca: Option<&std::path::Path>,
) -> Result<tokio_tungstenite::Connector, CliError> {
    let mut roots =
        rustls::RootCertStore::from_iter(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    if let Some(path) = tls_ca {
        let pem = std::fs::read(path).map_err(filesystem("profile TLS certificate authority"))?;
        for cert in rustls_pemfile::certs(&mut pem.as_slice()) {
            let cert = cert.map_err(domain("profile TLS certificate authority"))?;
            roots
                .add(cert)
                .map_err(domain("profile TLS certificate authority"))?;
        }
    }
    let config = rustls::ClientConfig::builder()
        .with_root_certificates(roots)
        .with_no_client_auth();
    Ok(tokio_tungstenite::Connector::Rustls(std::sync::Arc::new(
        config,
    )))
}

async fn next_binary(ws: &mut Ws) -> Result<Vec<u8>, CliError> {
    loop {
        match ws.next().await {
            Some(Ok(Message::Binary(b))) => return Ok(b.to_vec()),
            Some(Ok(Message::Ping(_) | Message::Pong(_) | Message::Frame(_))) => continue,
            Some(Ok(Message::Text(_))) => {
                return Err(CliError::Protocol("text frame on channel".into()));
            }
            Some(Ok(Message::Close(c))) => {
                return Err(CliError::Transport(format!("closed: {c:?}")));
            }
            Some(Err(e)) => return Err(CliError::Transport(format!("websocket: {e}"))),
            None => return Err(CliError::Transport("connection ended".into())),
        }
    }
}

pub fn block_on<F: std::future::Future>(f: F) -> Result<F::Output, CliError> {
    Ok(tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(err("runtime"))?
        .block_on(f))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn late_response_cannot_contaminate_a_second_request() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let realm_id = vec![0; 32];
        let device = StaticKeypair::generate().unwrap();
        let realm = StaticKeypair::generate().unwrap();
        let server_realm = realm.clone();
        let server_realm_id = realm_id.clone();
        let silent_peer = tokio::spawn(async move {
            let (socket, _) = listener.accept().await.unwrap();
            let mut websocket = tokio_tungstenite::accept_async(socket).await.unwrap();
            let m1 = match websocket.next().await.unwrap().unwrap() {
                Message::Binary(bytes) => bytes,
                other => panic!("expected Noise message 1, got {other:?}"),
            };
            let mut responder = arveil_core::channel::Responder::new(
                &server_realm,
                &arveil_core::channel::prologue(&server_realm_id),
            )
            .unwrap();
            responder.read_message_1(&m1).unwrap();
            let (m2, transport) = responder.write_message_2().unwrap();
            websocket.send(Message::Binary(m2.into())).await.unwrap();
            let mut channel = Channel::new(transport);
            let request = loop {
                let bytes = match websocket.next().await.unwrap().unwrap() {
                    Message::Binary(bytes) => bytes,
                    _ => continue,
                };
                if let Some(request) = channel.open(&bytes).unwrap() {
                    break request;
                }
            };
            tokio::time::sleep(Duration::from_millis(200)).await;
            let late = Frame {
                id: request.id,
                payload: Payload::Pong,
            };
            for bytes in channel.seal(&late).unwrap() {
                if websocket.send(Message::Binary(bytes.into())).await.is_err() {
                    break;
                }
            }
        });
        let short = Duration::from_millis(100);
        let mut connection = Connection::open_with_timeouts(
            &format!("ws://{address}"),
            &realm_id,
            &realm.public,
            &device,
            None,
            TransportTimeouts {
                connect: Duration::from_secs(1),
                handshake: Duration::from_secs(1),
                request: short,
                close: short,
            },
        )
        .await
        .unwrap();
        let result = connection.request(Payload::Ping).await;
        let error = match result {
            Ok(_) => panic!("a silent peer must hit the deadline"),
            Err(error) => error,
        };
        assert!(matches!(error, CliError::Transport(_)));
        assert!(error.to_string().contains("timed out"));
        assert!(error.to_string().contains("cancelled"));
        let second = connection.request(Payload::Ping).await.unwrap_err();
        assert!(second.to_string().contains("reconnect required"));
        silent_peer.await.unwrap();
    }
}
