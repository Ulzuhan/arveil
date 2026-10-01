//! One payload for joining a realm, linking a device and adding a contact
//! (ADR-012 §1).
//!
//! A payload is the deterministic CBOR map `{version, kind, …}` encoded as
//! base64url without padding. The same payload travels three ways: as a QR
//! code of the whole link, as the link `https://<base>/<kind>#<payload>`, or
//! pasted, link or bare payload alike. The secret sits in the URL fragment,
//! which browsers never send to a server, and the client never fetches the
//! link: it only reads it here.
//!
//! Every payload names the realm it belongs to by its signing key, its Noise
//! key and one endpoint URL. The realm id is computed from the signing key,
//! never copied.

use arveil_core::channel::endpoints;
use data_encoding::BASE64URL_NOPAD;
use ed25519_dalek::VerifyingKey;
use serde::{Deserialize, Serialize};

/// Where links point unless a relay configures another page.
pub const DEFAULT_LINK_BASE: &str = "https://arveil.kaicorplabs.com";
/// Payloads above this size are refused before they are parsed.
pub const MAX_PAYLOAD_BYTES: usize = 600;
/// A pasted text longer than this cannot hold a payload of the size above.
const MAX_TEXT_CHARS: usize = 2048;
/// A pasted message searched for a card.
const MAX_MESSAGE_BYTES: usize = 16 * 1024;
pub const VERSION: u8 = 1;
pub const INVITATION_VERSION: u8 = 2;
/// A self-description is shown, never trusted, and kept short: 64 bytes of
/// UTF-8, so the largest card still fits [`MAX_PAYLOAD_BYTES`].
pub const MAX_NAME_BYTES: usize = 64;
const MAX_URL_CHARS: usize = 128;

#[derive(Debug, PartialEq, Eq, thiserror::Error)]
pub enum LinkError {
    #[error("not an Arveil link or code")]
    NotALink,
    #[error("the code is larger than any Arveil code")]
    TooLarge,
    #[error("the code is damaged: {0}")]
    Damaged(&'static str),
    #[error("this code was made by a newer version of Arveil")]
    NewerVersion,
    #[error("the message holds two different Arveil codes")]
    Ambiguous,
    #[error("the link says {path} but carries a {kind} code")]
    KindMismatch { path: String, kind: &'static str },
}

/// The realm a payload belongs to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Realm {
    pub signing_key: VerifyingKey,
    pub noise_public: Vec<u8>,
    pub url: String,
}

impl Realm {
    pub fn realm_id(&self) -> Vec<u8> {
        endpoints::realm_id(&self.signing_key)
    }

    /// The string the rest of the client already understands.
    pub fn bootstrap(&self) -> String {
        format!(
            "arveil-bootstrap:v0:{}:{}:{}:{}",
            hex::encode(self.realm_id()),
            hex::encode(self.signing_key.as_bytes()),
            hex::encode(&self.noise_public),
            self.url
        )
    }

    /// From a bootstrap string, recomputing the realm id: a string whose id
    /// does not derive from its key describes no realm.
    pub fn from_bootstrap(bootstrap: &str) -> Result<Self, LinkError> {
        let b = crate::carrier::Bootstrap::parse(bootstrap)
            .map_err(|_| LinkError::Damaged("server details"))?;
        if b.realm_id != endpoints::realm_id(&b.signing_key) {
            return Err(LinkError::Damaged("realm id"));
        }
        Ok(Self {
            signing_key: b.signing_key,
            noise_public: b.noise_public,
            url: b.url,
        })
    }
}

/// The device a contact card names, as a route does.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CardRoute {
    pub device_id: Vec<u8>,
    pub credential_hash: Vec<u8>,
    pub root_public: Vec<u8>,
    pub mailbox_id: Vec<u8>,
    pub write_capability: Vec<u8>,
    pub hpke_public: Vec<u8>,
}

impl CardRoute {
    /// The `arveil-route:v1` string, whose identity id derives from the
    /// root key.
    pub fn route(&self) -> Result<String, LinkError> {
        let root = root_key(&self.root_public)?;
        Ok(format!(
            "arveil-route:v1:{}:{}:{}:{}:{}:{}:{}",
            hex::encode(arveil_core::identity::identity_id(&root)),
            hex::encode(&self.device_id),
            hex::encode(&self.credential_hash),
            hex::encode(&self.root_public),
            hex::encode(&self.mailbox_id),
            hex::encode(&self.write_capability),
            hex::encode(&self.hpke_public)
        ))
    }

    pub fn from_route(route: &crate::Route) -> Self {
        Self {
            device_id: route.device_id.clone(),
            credential_hash: route.credential_hash.clone(),
            root_public: route.root_public.clone(),
            mailbox_id: route.mailbox_id.clone(),
            write_capability: route.write_capability.clone(),
            hpke_public: route.hpke_public.clone(),
        }
    }
}

/// What a payload carries.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Card {
    /// A personal invitation combines admission and the inviter contact.
    Invitation {
        realm: Realm,
        invitation: Vec<u8>,
        expires_at: u64,
        route: CardRoute,
        secret: Vec<u8>,
        name: Option<String>,
    },
    /// Join a realm with a single-use invitation (§2).
    Join { realm: Realm, invitation: Vec<u8> },
    /// Link a device to the identity whose device shows this (§3). The new
    /// device answers the rendezvous as the Noise `IK` initiator towards
    /// `responder_key`, a one-time key of the device that holds the root.
    Link {
        realm: Realm,
        pair_id: Vec<u8>,
        capability: Vec<u8>,
        responder_key: Vec<u8>,
        /// When the relay forgets the rendezvous (Unix seconds).
        expires_at: u64,
    },
    /// Talk to a person (§4). `secret` tells the person who shows the card
    /// that a conversation came from it; `name` is how they describe
    /// themselves, shown but never trusted.
    Contact {
        realm: Realm,
        route: CardRoute,
        secret: Vec<u8>,
        name: Option<String>,
    },
}

/// The wire map. Fields that a kind does not use are absent; fields a newer
/// version adds are ignored by this one.
// Positional contact fields avoid enlarging the existing 600-byte QR bound.
type PackedContact = (
    serde_bytes::ByteBuf,
    serde_bytes::ByteBuf,
    serde_bytes::ByteBuf,
    serde_bytes::ByteBuf,
    serde_bytes::ByteBuf,
    serde_bytes::ByteBuf,
    serde_bytes::ByteBuf,
    Option<String>,
);

#[derive(Default, Serialize, Deserialize)]
struct Wire {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    contact: Option<PackedContact>,
    version: u8,
    kind: String,
    #[serde(with = "serde_bytes")]
    realm_signing_key: Vec<u8>,
    #[serde(with = "serde_bytes")]
    realm_noise_key: Vec<u8>,
    url: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    invitation: Option<serde_bytes::ByteBuf>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pair_id: Option<serde_bytes::ByteBuf>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    capability: Option<serde_bytes::ByteBuf>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    responder_key: Option<serde_bytes::ByteBuf>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    expires_at: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    device_id: Option<serde_bytes::ByteBuf>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    credential_hash: Option<serde_bytes::ByteBuf>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    root_key: Option<serde_bytes::ByteBuf>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    mailbox_id: Option<serde_bytes::ByteBuf>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    write_capability: Option<serde_bytes::ByteBuf>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    hpke_key: Option<serde_bytes::ByteBuf>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    secret: Option<serde_bytes::ByteBuf>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    name: Option<String>,
}

fn bytes(v: &[u8]) -> Option<serde_bytes::ByteBuf> {
    Some(serde_bytes::ByteBuf::from(v.to_vec()))
}

fn field(
    v: Option<serde_bytes::ByteBuf>,
    len: usize,
    name: &'static str,
) -> Result<Vec<u8>, LinkError> {
    match v {
        Some(b) if b.len() == len => Ok(b.into_vec()),
        _ => Err(LinkError::Damaged(name)),
    }
}

fn root_key(bytes: &[u8]) -> Result<VerifyingKey, LinkError> {
    let b: [u8; 32] = bytes
        .try_into()
        .map_err(|_| LinkError::Damaged("root key"))?;
    VerifyingKey::from_bytes(&b).map_err(|_| LinkError::Damaged("root key"))
}

/// A name a person may give themselves: trimmed, bounded, printable.
pub fn clean_name(name: &str) -> Option<String> {
    let name = name.trim();
    if name.is_empty() || name.len() > MAX_NAME_BYTES || name.chars().any(char::is_control) {
        return None;
    }
    Some(name.to_string())
}

impl Card {
    pub fn kind(&self) -> &'static str {
        match self {
            Card::Join { .. } | Card::Invitation { .. } => "join",
            Card::Link { .. } => "link",
            Card::Contact { .. } => "contact",
        }
    }

    pub fn realm(&self) -> &Realm {
        match self {
            Card::Join { realm, .. }
            | Card::Invitation { realm, .. }
            | Card::Link { realm, .. }
            | Card::Contact { realm, .. } => realm,
        }
    }

    /// The bare payload: base64url of the deterministic CBOR map.
    pub fn payload(&self) -> Result<String, LinkError> {
        let realm = self.realm();
        let mut w = Wire {
            version: VERSION,
            kind: self.kind().into(),
            realm_signing_key: realm.signing_key.as_bytes().to_vec(),
            realm_noise_key: realm.noise_public.clone(),
            url: realm.url.clone(),
            ..Wire::default()
        };
        match self {
            Card::Invitation {
                invitation,
                expires_at,
                route,
                secret,
                name,
                ..
            } => {
                w.version = INVITATION_VERSION;
                w.invitation = bytes(invitation);
                w.expires_at = Some(*expires_at);
                w.contact = Some((
                    route.device_id.clone().into(),
                    route.credential_hash.clone().into(),
                    route.root_public.clone().into(),
                    route.mailbox_id.clone().into(),
                    route.write_capability.clone().into(),
                    route.hpke_public.clone().into(),
                    secret.clone().into(),
                    name.as_deref().and_then(clean_name),
                ));
            }
            Card::Join { invitation, .. } => w.invitation = bytes(invitation),
            Card::Link {
                pair_id,
                capability,
                responder_key,
                expires_at,
                ..
            } => {
                w.pair_id = bytes(pair_id);
                w.capability = bytes(capability);
                w.responder_key = bytes(responder_key);
                w.expires_at = Some(*expires_at);
            }
            Card::Contact {
                route,
                secret,
                name,
                ..
            } => {
                w.device_id = bytes(&route.device_id);
                w.credential_hash = bytes(&route.credential_hash);
                w.root_key = bytes(&route.root_public);
                w.mailbox_id = bytes(&route.mailbox_id);
                w.write_capability = bytes(&route.write_capability);
                w.hpke_key = bytes(&route.hpke_public);
                w.secret = bytes(secret);
                w.name = name.as_deref().and_then(clean_name);
            }
        }
        let cbor =
            arveil_core::signed::canonical(&w).map_err(|_| LinkError::Damaged("encoding"))?;
        if cbor.len() > MAX_PAYLOAD_BYTES {
            return Err(LinkError::TooLarge);
        }
        if matches!(self, Card::Invitation { .. }) {
            Self::decode(&cbor)?;
        }
        Ok(BASE64URL_NOPAD.encode(&cbor))
    }

    /// The link a QR code shows and a share sheet sends.
    pub fn link(&self, base: &str) -> Result<String, LinkError> {
        Ok(format!(
            "{}/{}#{}",
            base.trim_end_matches('/'),
            self.kind(),
            self.payload()?
        ))
    }

    /// Read a link, an `arveil:` URL or a bare payload, as pasted or
    /// scanned. Surrounding text is not searched: a link is one token.
    pub fn parse(text: &str) -> Result<Self, LinkError> {
        let text = text.trim();
        if text.is_empty() {
            return Err(LinkError::NotALink);
        }
        if text.chars().count() > MAX_TEXT_CHARS {
            return Err(LinkError::TooLarge);
        }
        if text.contains(char::is_whitespace) {
            return Err(LinkError::NotALink);
        }
        let (path, payload) = match text.rsplit_once('#') {
            Some((before, after)) => (Some(link_kind(before)?), after),
            None => (None, text),
        };
        if payload.len() > MAX_PAYLOAD_BYTES.div_ceil(3) * 4 {
            return Err(LinkError::TooLarge);
        }
        let cbor = BASE64URL_NOPAD
            .decode(payload.as_bytes())
            .map_err(|_| LinkError::NotALink)?;
        let card = Self::decode(&cbor)?;
        if let Some(path) = path
            && path != card.kind()
        {
            return Err(LinkError::KindMismatch {
                path,
                kind: card.kind(),
            });
        }
        Ok(card)
    }

    /// The card in a pasted message: the whole text if it is one, else the
    /// one link or payload among its words (a message usually says more
    /// than the link). Two different cards in one message are not guessed
    /// between.
    pub fn find(text: &str) -> Result<Self, LinkError> {
        if text.len() > MAX_MESSAGE_BYTES {
            return Err(LinkError::TooLarge);
        }
        let whole = Card::parse(text);
        if whole.is_ok() {
            return whole;
        }
        let mut found: Option<Card> = None;
        for word in text.split_whitespace() {
            let word = word.trim_matches(|c: char| "<>()[]{}\"'«».,;:!¡?¿".contains(c));
            if let Ok(card) = Card::parse(word) {
                match &found {
                    Some(f) if f != &card => return Err(LinkError::Ambiguous),
                    _ => found = Some(card),
                }
            }
        }
        match found {
            Some(card) => Ok(card),
            // Say why the text itself failed when it was a single token.
            None if !text.trim().contains(char::is_whitespace) => whole,
            None => Err(LinkError::NotALink),
        }
    }

    fn decode(cbor: &[u8]) -> Result<Self, LinkError> {
        if cbor.len() > MAX_PAYLOAD_BYTES {
            return Err(LinkError::TooLarge);
        }
        let w: Wire = ciborium::from_reader(cbor).map_err(|_| LinkError::NotALink)?;
        if w.version > INVITATION_VERSION {
            return Err(LinkError::NewerVersion);
        }
        if w.version != VERSION && w.version != INVITATION_VERSION {
            return Err(LinkError::Damaged("version"));
        }
        let signing: [u8; 32] = w
            .realm_signing_key
            .as_slice()
            .try_into()
            .map_err(|_| LinkError::Damaged("server key"))?;
        let realm = Realm {
            signing_key: VerifyingKey::from_bytes(&signing)
                .map_err(|_| LinkError::Damaged("server key"))?,
            noise_public: if w.realm_noise_key.len() == 32 {
                w.realm_noise_key
            } else {
                return Err(LinkError::Damaged("server key"));
            },
            url: valid_url(w.url)?,
        };
        if w.version == INVITATION_VERSION {
            if w.kind != "join" {
                return Err(LinkError::Damaged("invitation kind"));
            }
            let (device, credential, root, mailbox, write, hpke, secret, name) =
                w.contact.ok_or(LinkError::Damaged("inviter contact"))?;
            let route = CardRoute {
                device_id: field(Some(device), 16, "device")?,
                credential_hash: field(Some(credential), 32, "credential")?,
                root_public: field(Some(root), 32, "root key")?,
                mailbox_id: field(Some(mailbox), 16, "mailbox")?,
                write_capability: field(Some(write), 32, "mailbox")?,
                hpke_public: field(Some(hpke), 32, "device key")?,
            };
            root_key(&route.root_public)?;
            let expires_at = w
                .expires_at
                .filter(|n| *n > 0 && *n <= i64::MAX as u64)
                .ok_or(LinkError::Damaged("expiry"))?;
            return Ok(Card::Invitation {
                realm,
                invitation: field(w.invitation, 32, "invitation")?,
                expires_at,
                route,
                secret: field(Some(secret), 16, "secret")?,
                name: name.as_deref().and_then(clean_name),
            });
        }
        if w.contact.is_some() {
            return Err(LinkError::Damaged("invitation version"));
        }
        match w.kind.as_str() {
            "join" => Ok(Card::Join {
                realm,
                invitation: field(w.invitation, 32, "invitation")?,
            }),
            "link" => Ok(Card::Link {
                realm,
                pair_id: field(w.pair_id, 16, "pairing")?,
                capability: field(w.capability, 32, "pairing")?,
                responder_key: field(w.responder_key, 32, "pairing key")?,
                expires_at: w.expires_at.ok_or(LinkError::Damaged("pairing"))?,
            }),
            "contact" => {
                let route = CardRoute {
                    device_id: field(w.device_id, 16, "device")?,
                    credential_hash: field(w.credential_hash, 32, "credential")?,
                    root_public: field(w.root_key, 32, "root key")?,
                    mailbox_id: field(w.mailbox_id, 16, "mailbox")?,
                    write_capability: field(w.write_capability, 32, "mailbox")?,
                    hpke_public: field(w.hpke_key, 32, "device key")?,
                };
                root_key(&route.root_public)?;
                Ok(Card::Contact {
                    realm,
                    route,
                    secret: field(w.secret, 16, "secret")?,
                    name: w.name.as_deref().and_then(clean_name),
                })
            }
            _ => Err(LinkError::NewerVersion),
        }
    }
}

fn valid_url(url: String) -> Result<String, LinkError> {
    if url.len() > MAX_URL_CHARS
        || !(url.starts_with("wss://") || url.starts_with("ws://"))
        || url.chars().any(|c| c.is_whitespace() || c.is_control())
    {
        return Err(LinkError::Damaged("server address"));
    }
    Ok(url)
}

/// The kind a link's path names: the last path segment of an https link,
/// or what follows `arveil:` (with or without `//`).
fn link_kind(before_fragment: &str) -> Result<String, LinkError> {
    let rest = if let Some(rest) = before_fragment.strip_prefix("https://") {
        rest.split_once('/').map(|(_, path)| path).unwrap_or("")
    } else if let Some(rest) = before_fragment.strip_prefix("arveil:") {
        rest.trim_start_matches('/')
    } else {
        return Err(LinkError::NotALink);
    };
    let kind = rest
        .split('?')
        .next()
        .unwrap_or("")
        .trim_end_matches('/')
        .rsplit('/')
        .next()
        .unwrap_or("");
    match kind {
        "join" | "link" | "contact" => Ok(kind.to_string()),
        _ => Err(LinkError::NotALink),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn realm() -> Realm {
        Realm {
            signing_key: ed25519_dalek::SigningKey::from_bytes(&[9; 32]).verifying_key(),
            noise_public: vec![8; 32],
            url: "wss://relay.example.org/v1/channel".into(),
        }
    }

    fn contact(name: Option<&str>) -> Card {
        Card::Contact {
            realm: realm(),
            route: CardRoute {
                device_id: vec![1; 16],
                credential_hash: vec![2; 32],
                root_public: ed25519_dalek::SigningKey::from_bytes(&[3; 32])
                    .verifying_key()
                    .as_bytes()
                    .to_vec(),
                mailbox_id: vec![4; 16],
                write_capability: vec![5; 32],
                hpke_public: vec![6; 32],
            },
            secret: vec![7; 16],
            name: name.map(str::to_string),
        }
    }

    fn cards() -> Vec<Card> {
        vec![
            Card::Join {
                realm: realm(),
                invitation: vec![1; 32],
            },
            Card::Link {
                realm: realm(),
                pair_id: vec![2; 16],
                capability: vec![3; 32],
                responder_key: vec![4; 32],
                expires_at: 1_800_000_000,
            },
            contact(Some("Ana")),
            contact(None),
        ]
    }

    #[test]
    fn personal_invitation_fits_existing_qr_bound_and_preserves_version() {
        let Card::Contact {
            mut realm,
            route,
            secret,
            ..
        } = contact(None)
        else {
            unreachable!()
        };
        realm.url = format!("wss://{}", "r".repeat(MAX_URL_CHARS - 6));
        let card = Card::Invitation {
            realm,
            route,
            secret,
            invitation: vec![9; 32],
            expires_at: i64::MAX as u64,
            name: Some("ñ".repeat(32)),
        };
        let payload = card.payload().unwrap();
        let raw = BASE64URL_NOPAD.decode(payload.as_bytes()).unwrap();
        assert!(raw.len() <= MAX_PAYLOAD_BYTES, "{}", raw.len());
        assert_eq!(
            Card::parse(&card.link(DEFAULT_LINK_BASE).unwrap()).unwrap(),
            card
        );
        let link = card.link(DEFAULT_LINK_BASE).unwrap();
        let qr = crate::qr::encode(&link).unwrap();
        let width = qr.width as usize;
        let side = (width + 8) * 4;
        let mut luma = vec![255; side * side];
        for y in 0..width {
            for x in 0..width {
                if qr.dark[y * width + x] {
                    for dy in 0..4 {
                        for dx in 0..4 {
                            luma[((y + 4) * 4 + dy) * side + (x + 4) * 4 + dx] = 0;
                        }
                    }
                }
            }
        }
        assert_eq!(
            crate::qr::decode(side as u32, side as u32, side as u32, &luma),
            vec![link]
        );
        let mut wire: Wire = ciborium::from_reader(raw.as_slice()).unwrap();
        assert_eq!(wire.version, 2); // v1 sees a newer version before redemption.
        wire.version = 1;
        let downgraded = arveil_core::signed::canonical(&wire).unwrap();
        assert!(Card::decode(&downgraded).is_err());
        wire.version = 2;
        wire.contact = None;
        assert!(Card::decode(&arveil_core::signed::canonical(&wire).unwrap()).is_err());
    }

    #[test]
    fn every_kind_reads_back_from_a_link_an_arveil_url_and_a_bare_payload() {
        for card in cards() {
            let payload = card.payload().unwrap();
            let link = card.link(DEFAULT_LINK_BASE).unwrap();
            assert_eq!(
                link,
                format!("https://arveil.kaicorplabs.com/{}#{payload}", card.kind())
            );
            for text in [
                link.clone(),
                format!("  {link}\n"),
                format!("arveil://{}#{payload}", card.kind()),
                format!("arveil:{}#{payload}", card.kind()),
                format!("https://other.example/es/{}/#{payload}", card.kind()),
                payload.clone(),
            ] {
                assert_eq!(Card::parse(&text).unwrap(), card, "{text}");
            }
        }
    }

    #[test]
    fn the_realm_id_is_computed_and_the_bootstrap_rebuilt() {
        let r = realm();
        assert_eq!(
            hex::encode(r.realm_id()),
            "c3d1bd7c0aa5300cecc6bc13e253e49fe06d9bcb8c2e676edb42b7baf77bb346"
        );
        assert_eq!(Realm::from_bootstrap(&r.bootstrap()).unwrap(), r);
        let copied_wrong = r.bootstrap().replacen("c3d1", "0000", 1);
        assert_eq!(
            Realm::from_bootstrap(&copied_wrong),
            Err(LinkError::Damaged("realm id"))
        );
    }

    #[test]
    fn the_largest_card_fits_the_limit_and_a_larger_one_is_refused_unread() {
        let long = "x".repeat(MAX_NAME_BYTES);
        let mut card = contact(Some(&long));
        if let Card::Contact { realm, .. } = &mut card {
            realm.url = format!("wss://{}", "r".repeat(MAX_URL_CHARS - 6));
        }
        let payload = card.payload().unwrap();
        let size = BASE64URL_NOPAD.decode(payload.as_bytes()).unwrap().len();
        assert!(size <= MAX_PAYLOAD_BYTES, "{size}");
        let too_long = "A".repeat(MAX_PAYLOAD_BYTES.div_ceil(3) * 4 + 4);
        assert_eq!(Card::parse(&too_long), Err(LinkError::TooLarge));
        assert_eq!(Card::parse(&"A".repeat(5000)), Err(LinkError::TooLarge));
    }

    #[test]
    fn damaged_foreign_and_mismatched_links_are_refused() {
        let join = &cards()[0];
        let payload = join.payload().unwrap();
        assert!(matches!(
            Card::parse(&format!("https://arveil.kaicorplabs.com/contact#{payload}")),
            Err(LinkError::KindMismatch { .. })
        ));
        for text in [
            "hello",
            "https://example.org/join",
            "https://example.org/other#AAAA",
            "arveil-bootstrap:v0:aa:bb:cc:ws://x",
            "ftp://example.org/join#AAAA",
        ] {
            assert!(Card::parse(text).is_err(), "{text}");
        }
        // A truncated payload is damaged, not something else.
        assert!(Card::parse(&payload[..payload.len() - 8]).is_err());
    }

    #[test]
    fn a_name_is_trimmed_bounded_and_printable() {
        assert_eq!(clean_name("  Ana  "), Some("Ana".into()));
        assert_eq!(clean_name(""), None);
        assert_eq!(clean_name("a\u{7}b"), None);
        assert_eq!(clean_name(&"x".repeat(MAX_NAME_BYTES + 1)), None);
        assert_eq!(clean_name(&"ñ".repeat(MAX_NAME_BYTES / 2 + 1)), None);
        let Card::Contact { name, .. } =
            Card::parse(&contact(Some("line\nbreak")).payload().unwrap()).unwrap()
        else {
            panic!("contact")
        };
        assert_eq!(name, None, "a name that cannot be shown is dropped");
    }

    #[test]
    fn a_contact_card_gives_the_route_it_describes() {
        let Card::Contact { route, .. } = contact(None) else {
            panic!("contact")
        };
        let parsed = crate::parse_route(&route.route().unwrap()).unwrap();
        assert_eq!(CardRoute::from_route(&parsed), route);
    }

    #[test]
    fn a_card_is_found_inside_a_message_once() {
        let card = &cards()[0];
        let link = card.link(DEFAULT_LINK_BASE).unwrap();
        let message = format!("Te invito a Arveil:\n{link}.\nCaduca mañana");
        assert_eq!(Card::find(&message).unwrap(), *card);
        assert_eq!(Card::find(&format!("(<{link}>) {link}")).unwrap(), *card);
        let other = cards()[1].link(DEFAULT_LINK_BASE).unwrap();
        assert_eq!(
            Card::find(&format!("{link} {other}")),
            Err(LinkError::Ambiguous)
        );
        assert_eq!(Card::find("hola, ¿qué tal?"), Err(LinkError::NotALink));
        assert_eq!(
            Card::find(&format!(
                "https://arveil.kaicorplabs.com/contact#{}",
                card.payload().unwrap()
            )),
            Err(LinkError::KindMismatch {
                path: "contact".into(),
                kind: "join"
            })
        );
    }

    /// `relay/internal/links` writes the same bytes for the same inputs.
    #[test]
    fn the_relay_and_the_client_write_the_same_join_payload() {
        assert_eq!(
            cards()[0].payload().unwrap(),
            "pmN1cmx4IndzczovL3JlbGF5LmV4YW1wbGUub3JnL3YxL2NoYW5uZWxka2luZGRqb2luZ3ZlcnNpb24Bamludml0YXRpb25YIAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBb3JlYWxtX25vaXNlX2tleVggCAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAhxcmVhbG1fc2lnbmluZ19rZXlYIP0XJDhaoMdbZPt4zWAvodmR_ev3axPFjtcC6sg16fYY"
        );
    }

    #[test]
    fn a_newer_version_is_named_as_such() {
        let w = Wire {
            version: INVITATION_VERSION + 1,
            kind: "join".into(),
            ..Wire::default()
        };
        let cbor = arveil_core::signed::canonical(&w).unwrap();
        assert_eq!(
            Card::parse(&BASE64URL_NOPAD.encode(&cbor)),
            Err(LinkError::NewerVersion)
        );
    }
}
