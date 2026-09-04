//! `arveil probe`: WebSocket carrier + Noise channel against a live relay.

use std::fmt;

use arveil_core::channel::codec::{Frame, Payload};
use arveil_core::channel::endpoints;
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
pub struct ProbeError(String);

impl fmt::Display for ProbeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for ProbeError {}

fn err<E: fmt::Display>(context: &str) -> impl FnOnce(E) -> ProbeError + '_ {
    move |e| ProbeError(format!("{context}: {e}"))
}

impl Bootstrap {
    pub fn parse(s: &str) -> Result<Self, ProbeError> {
        let parts: Vec<&str> = s.splitn(6, ':').collect();
        if parts.len() != 6 || parts[0] != "arveil-bootstrap" || parts[1] != "v0" {
            return Err(ProbeError("not an arveil-bootstrap:v0 string".into()));
        }
        let realm_id = hex::decode(parts[2]).map_err(err("realm id"))?;
        let signing: [u8; 32] = hex::decode(parts[3])
            .map_err(err("signing key"))?
            .try_into()
            .map_err(|_| ProbeError("signing key must be 32 bytes".into()))?;
        let signing_key = VerifyingKey::from_bytes(&signing).map_err(err("signing key"))?;
        let noise_public = hex::decode(parts[4]).map_err(err("noise key"))?;
        if noise_public.len() != 32 {
            return Err(ProbeError("noise key must be 32 bytes".into()));
        }
        Ok(Self {
            realm_id,
            signing_key,
            noise_public,
            url: parts[5].to_string(),
        })
    }
}

pub fn run(bootstrap: &str) -> Result<(), ProbeError> {
    let b = Bootstrap::parse(bootstrap)?;
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(err("runtime"))?
        .block_on(probe(&b))
}

async fn probe(b: &Bootstrap) -> Result<(), ProbeError> {
    let (mut ws, _) = tokio_tungstenite::connect_async(&b.url)
        .await
        .map_err(err("connect"))?;

    // Handshake: message 1 out, message 2 in.
    let device = StaticKeypair::generate().map_err(err("keygen"))?;
    let mut init =
        Initiator::new(&device, &b.noise_public, &prologue(&b.realm_id)).map_err(err("noise"))?;
    let m1 = init.write_message_1().map_err(err("noise"))?;
    ws.send(Message::Binary(m1.into()))
        .await
        .map_err(err("send m1"))?;
    let m2 = next_binary(&mut ws).await?;
    let transport = init
        .read_message_2(&m2)
        .map_err(err("handshake refused (wrong realm key or prologue?)"))?;
    let mut channel = Channel::new(transport);
    println!(
        "channel: established with realm noise key {}",
        hex::encode(channel.remote_static())
    );

    // Endpoint list, verified against the bootstrap signing key.
    let reply = request(
        &mut ws,
        &mut channel,
        Frame {
            id: 1,
            payload: Payload::EndpointListGet,
        },
    )
    .await?;
    let signed = match reply.payload {
        Payload::EndpointList { signed } => signed,
        other => return Err(ProbeError(format!("unexpected reply: {other:?}"))),
    };
    let list = endpoints::verify(&signed, &b.signing_key, &b.realm_id, None)
        .map_err(err("endpoint list"))?;
    if list.realm_noise_public_key != b.noise_public {
        return Err(ProbeError(
            "endpoint list advertises a different noise key than the bootstrap".into(),
        ));
    }
    println!("endpoint list: sequence {}, signature valid", list.sequence);
    for e in &list.endpoints {
        println!("  {:<8} priority {} {}", e.kind, e.priority, e.url);
    }

    // Liveness.
    let pong = request(
        &mut ws,
        &mut channel,
        Frame {
            id: 2,
            payload: Payload::Ping,
        },
    )
    .await?;
    if pong.payload != Payload::Pong || pong.id != 2 {
        return Err(ProbeError(format!("expected pong, got {pong:?}")));
    }
    println!("ping: pong");
    let _ = ws.close(None).await;
    println!("probe ok");
    Ok(())
}

type Ws =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

async fn next_binary(ws: &mut Ws) -> Result<Vec<u8>, ProbeError> {
    loop {
        match ws.next().await {
            Some(Ok(Message::Binary(b))) => return Ok(b.to_vec()),
            Some(Ok(Message::Ping(_) | Message::Pong(_))) => continue,
            Some(Ok(Message::Text(_))) => return Err(ProbeError("text frame on channel".into())),
            Some(Ok(Message::Close(c))) => return Err(ProbeError(format!("closed: {c:?}"))),
            Some(Ok(Message::Frame(_))) => continue,
            Some(Err(e)) => return Err(ProbeError(format!("websocket: {e}"))),
            None => return Err(ProbeError("connection ended".into())),
        }
    }
}

async fn request(ws: &mut Ws, ch: &mut Channel, frame: Frame) -> Result<Frame, ProbeError> {
    for m in ch.seal(&frame).map_err(err("seal"))? {
        ws.send(Message::Binary(m.into()))
            .await
            .map_err(err("send"))?;
    }
    loop {
        let m = next_binary(ws).await?;
        if let Some(f) = ch.open(&m).map_err(err("open"))? {
            if f.id != frame.id {
                return Err(ProbeError(format!(
                    "reply id {} for request {}",
                    f.id, frame.id
                )));
            }
            return Ok(f);
        }
    }
}
