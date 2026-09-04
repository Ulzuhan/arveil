//! WebSocket carrier for the CLI: connect, run the Noise handshake with a
//! given device static key, and exchange frames.

use std::fmt;

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

#[derive(Debug)]
pub struct CliError(pub String);

impl fmt::Display for CliError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for CliError {}

impl From<rusqlite::Error> for CliError {
    fn from(e: rusqlite::Error) -> Self {
        CliError(format!("sqlite: {e}"))
    }
}

pub fn err<E: fmt::Display>(context: &str) -> impl FnOnce(E) -> CliError + '_ {
    move |e| CliError(format!("{context}: {e}"))
}

impl Bootstrap {
    pub fn parse(s: &str) -> Result<Self, CliError> {
        let parts: Vec<&str> = s.splitn(6, ':').collect();
        if parts.len() != 6 || parts[0] != "arveil-bootstrap" || parts[1] != "v0" {
            return Err(CliError("not an arveil-bootstrap:v0 string".into()));
        }
        let realm_id = hex::decode(parts[2]).map_err(err("realm id"))?;
        let signing: [u8; 32] = hex::decode(parts[3])
            .map_err(err("signing key"))?
            .try_into()
            .map_err(|_| CliError("signing key must be 32 bytes".into()))?;
        let signing_key = VerifyingKey::from_bytes(&signing).map_err(err("signing key"))?;
        let noise_public = hex::decode(parts[4]).map_err(err("noise key"))?;
        if noise_public.len() != 32 {
            return Err(CliError("noise key must be 32 bytes".into()));
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
    ws: Ws,
    pub channel: Channel,
    next_id: u64,
}

impl Connection {
    /// Connect to `url` and complete the handshake as `device` against a
    /// realm identified by `realm_id` and `realm_noise_public`.
    pub async fn open(
        url: &str,
        realm_id: &[u8],
        realm_noise_public: &[u8],
        device: &StaticKeypair,
    ) -> Result<Self, CliError> {
        let (mut ws, _) = tokio_tungstenite::connect_async_tls_with_config(
            url,
            None,
            false,
            Some(tls_connector()?),
        )
        .await
        .map_err(err("connect"))?;
        let mut init = Initiator::new(device, realm_noise_public, &prologue(realm_id))
            .map_err(err("noise"))?;
        let m1 = init.write_message_1().map_err(err("noise"))?;
        ws.send(Message::Binary(m1.into()))
            .await
            .map_err(err("send m1"))?;
        let m2 = next_binary(&mut ws).await?;
        let transport = init.read_message_2(&m2).map_err(err(
            "handshake refused (wrong realm key, prologue, or revoked device?)",
        ))?;
        Ok(Self {
            ws,
            channel: Channel::new(transport),
            next_id: 1,
        })
    }

    /// Send a payload and wait for the reply with the same id.
    pub async fn request(&mut self, payload: Payload) -> Result<Payload, CliError> {
        let id = self.next_id;
        self.next_id += 1;
        let frame = Frame { id, payload };
        for m in self.channel.seal(&frame).map_err(err("seal"))? {
            self.ws
                .send(Message::Binary(m.into()))
                .await
                .map_err(err("send"))?;
        }
        loop {
            let m = next_binary(&mut self.ws).await?;
            if let Some(f) = self.channel.open(&m).map_err(err("open"))? {
                if f.id != id {
                    return Err(CliError(format!("reply id {} for request {id}", f.id)));
                }
                return match f.payload {
                    Payload::Error { code, message } => {
                        Err(CliError(format!("relay refused ({code}): {message}")))
                    }
                    p => Ok(p),
                };
            }
        }
    }

    pub async fn close(mut self) {
        let _ = self.ws.close(None).await;
    }
}

/// TLS is the carrier's concern (ADR-008): WebPKI roots, plus an extra CA
/// from `ARVEIL_TLS_CA` (PEM) for self-signed test proxies.
fn tls_connector() -> Result<tokio_tungstenite::Connector, CliError> {
    let mut roots =
        rustls::RootCertStore::from_iter(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    if let Ok(path) = std::env::var("ARVEIL_TLS_CA") {
        let pem = std::fs::read(&path).map_err(err("ARVEIL_TLS_CA"))?;
        for cert in rustls_pemfile::certs(&mut pem.as_slice()) {
            let cert = cert.map_err(err("ARVEIL_TLS_CA"))?;
            roots.add(cert).map_err(err("ARVEIL_TLS_CA"))?;
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
            Some(Ok(Message::Text(_))) => return Err(CliError("text frame on channel".into())),
            Some(Ok(Message::Close(c))) => return Err(CliError(format!("closed: {c:?}"))),
            Some(Err(e)) => return Err(CliError(format!("websocket: {e}"))),
            None => return Err(CliError("connection ended".into())),
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
