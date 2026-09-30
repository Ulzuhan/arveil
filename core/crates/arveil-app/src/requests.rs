//! Contact cards and conversation requests (ADR-012 §4).
//!
//! A card is the `contact` payload of [`crate::links`]: this device's route
//! and a secret. Whoever opens it starts a conversation whose first event
//! is `hello {secret, name}`. On this side:
//!
//! - a conversation started by someone who is not a contact waits as a
//!   request, which the person accepts or declines; one from a contact, or
//!   from another device of this identity, is joined as before;
//! - a secret from a shared link says which link was used; an unknown or
//!   expired one says no link was;
//! - the in-person code, once its sender's route is bound to the root that
//!   signed it and to the leaf that sent the hello, marks that person
//!   verified in person. The scanning side marks this one verified when it
//!   scans.
//!
//! Older clients drop an unknown event kind, so `hello` is additive.

use arveil_core::client::{CardKind, CardUse, OwnCard, Request, RequestStatus, VerifiedHow};
use serde::{Deserialize, Serialize};

use super::*;
use crate::links::{Card, CardRoute, DEFAULT_LINK_BASE, Realm, clean_name};

/// The first event of a conversation someone started.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Hello {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub secret: Option<serde_bytes::ByteBuf>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
}

/// A card this device shows or shares.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CardOffer {
    pub secret: Vec<u8>,
    pub link: String,
    pub in_person: bool,
    pub created_at: i64,
    pub expires_at: i64,
}

/// What an opened card says about the person, before talking.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CardPreview {
    pub identity_id: Vec<u8>,
    /// How they describe themselves; shown, never trusted.
    pub name: Option<String>,
    /// The name this profile already gives them, if it knows them.
    pub known_as: Option<String>,
    pub safety_number: String,
    pub verified: bool,
}

/// A request as a screen shows it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RequestSummary {
    pub from: Option<Vec<u8>>,
    pub name: Option<String>,
    pub card: CardUse,
}

impl From<Request> for RequestSummary {
    fn from(r: Request) -> Self {
        Self {
            from: r.from,
            name: r.name,
            card: r.card,
        }
    }
}

pub(crate) fn encode_hello(hello: &Hello) -> Result<Vec<u8>, CliError> {
    encode_event(
        "hello",
        &arveil_core::signed::canonical(hello).map_err(protocol_error("hello"))?,
    )
}

/// The hello this device sends when it starts a conversation without a
/// card: only its name, if it put one on its cards.
pub(crate) fn plain_hello(client: &Client) -> Result<Option<Hello>, CliError> {
    Ok(client
        .card_name()
        .map_err(storage_error("card name"))?
        .map(|name| Hello {
            secret: None,
            name: Some(name),
        }))
}

/// After a roster: the conversation was started by whoever sent its first
/// roster. It is joined without asking when that is this identity, a
/// contact this person chose, or when another device of this identity is
/// already in it; otherwise it stays a request.
pub(crate) fn classify(
    s: &Session,
    gid: &[u8],
    sender: Option<&[u8]>,
    peers: &[Peer],
) -> Result<(), CliError> {
    let Some(request) = s.client.request(gid).map_err(storage_error("request"))? else {
        return Ok(());
    };
    if request.status != RequestStatus::Pending || request.from.is_some() {
        return Ok(());
    }
    let Some(from) = sender else {
        return Ok(());
    };
    s.client
        .request_set_from(gid, from)
        .map_err(storage_error("request"))?;
    let known = from == s.identity_id.as_slice()
        || peers.iter().any(|p| p.identity == s.identity_id)
        || s.client
            .contact_is_accepted(from)
            .map_err(storage_error("contact"))?;
    if known {
        s.client
            .request_resolve(gid, true)
            .map_err(storage_error("request"))?;
    }
    Ok(())
}

/// A hello: which card it used, and how its sender describes itself.
pub(crate) fn receive_hello(
    s: &Session,
    gid: &[u8],
    sender: Option<&[u8]>,
    body: &[u8],
) -> Result<StateChange, CliError> {
    let hello: Hello = ciborium::from_reader(body).map_err(protocol_error("hello"))?;
    if sender == Some(s.identity_id.as_slice()) {
        return Ok(StateChange::MlsMessageProcessed {
            group_id: gid.to_vec(),
            description: "own hello".into(),
        });
    }
    let now = unix_now();
    let card = match &hello.secret {
        Some(secret) => match s
            .client
            .card_redeem(secret, now)
            .map_err(storage_error("card"))?
        {
            Some(OwnCard {
                kind: CardKind::InPerson,
                ..
            }) => CardUse::InPersonPending,
            Some(OwnCard {
                kind: CardKind::Link,
                created_at,
                ..
            }) => CardUse::Link { created_at },
            None => CardUse::None,
        },
        None => CardUse::None,
    };
    let name = hello.name.as_deref().and_then(clean_name);
    s.client
        .request_set_card(gid, &card, name.as_deref())
        .map_err(storage_error("request"))?;
    Ok(StateChange::HelloReceived {
        group_id: gid.to_vec(),
        name,
        card,
    })
}

/// Bind every in-person code this device was shown back through to the
/// root and the leaf of whoever used it, and only then mark them verified
/// in person and the conversation accepted. A code that does not bind
/// counts as no card at all. Network trouble leaves it for the next sync.
pub(crate) async fn settle_in_person<C: MlsConfig>(
    s: &Session,
    engine: &Engine<C>,
    conn: &mut Connection,
) -> Result<(), CliError> {
    for request in s
        .client
        .requests_in_person_pending()
        .map_err(storage_error("request"))?
    {
        let Some(from) = request.from.clone() else {
            continue;
        };
        let conversation = s
            .client
            .conversations()
            .map_err(storage_error("conversations"))?
            .into_iter()
            .find(|c| c.group_id == request.group_id);
        let Some(conversation) = conversation else {
            continue;
        };
        let group = engine
            .load_group(&request.group_id)
            .map_err(storage_error("mls load"))?;
        let mut bound = None;
        for peer in conversation.peers.iter().filter(|p| p.identity == from) {
            let Some(route) = route_of_peer(peer) else {
                continue;
            };
            let parsed = parse_route(&route)?;
            let credential = match verified_route_credential(conn, &parsed).await {
                Ok(c) => c,
                Err(CliError::Domain(_)) => continue,
                Err(e) => return Err(e),
            };
            let leaf = group.roster().members().into_iter().find(|m| {
                m.signing_identity
                    .credential
                    .as_basic()
                    .is_some_and(|b| b.identifier() == parsed.device_id.as_slice())
            });
            if leaf.is_some_and(|m| {
                m.signing_identity.signature_key.as_bytes()
                    == credential.mls_signature_public_key.as_slice()
            }) {
                bound = Some((parsed, route));
                break;
            }
        }
        let now = unix_now();
        match bound {
            Some((route, text)) => {
                s.client
                    .contact_route_save(&from, &route.device_id, &text)
                    .map_err(storage_error("contact"))?;
                s.client
                    .contact_verified(&from, VerifiedHow::InPerson, now)
                    .map_err(storage_error("contact"))?;
                s.client
                    .request_set_card(&request.group_id, &CardUse::InPerson, None)
                    .map_err(storage_error("request"))?;
                if request.status == RequestStatus::Pending {
                    s.client
                        .request_resolve(&request.group_id, true)
                        .map_err(storage_error("request"))?;
                }
                record_change(StateChange::ContactVerifiedInPerson {
                    group_id: request.group_id,
                    identity_id: from,
                });
            }
            None => s
                .client
                .request_set_card(&request.group_id, &CardUse::None, None)
                .map_err(storage_error("request"))?,
        }
    }
    Ok(())
}

/// The person's answer to a request. Accepting makes its sender a contact
/// with the routes the conversation carries; declining hides it and drops
/// what arrives for it.
pub(crate) fn answer(
    config: &ProfileConfig,
    group_id: &[u8],
    accept: bool,
) -> Result<(), CliError> {
    let s = local(config)?;
    let request = s
        .client
        .request(group_id)
        .map_err(storage_error("request"))?
        .filter(|r| r.status == RequestStatus::Pending)
        .ok_or_else(|| CliError::Domain("no request waits for an answer here".into()))?;
    if accept && let Some(from) = &request.from {
        let conversation = s
            .client
            .conversations()
            .map_err(storage_error("conversations"))?
            .into_iter()
            .find(|c| c.group_id == group_id);
        for peer in conversation.iter().flat_map(|c| &c.peers) {
            if &peer.identity == from
                && let Some(route) = route_of_peer(peer)
            {
                s.client
                    .contact_route_save(from, &peer.device_id, &route)
                    .map_err(storage_error("contact"))?;
            }
        }
        s.client
            .contact_accept(from)
            .map_err(storage_error("contact"))?;
        if let Some(name) = request.name.as_deref()
            && s.client
                .contact(from)
                .map_err(storage_error("contact"))?
                .is_some_and(|c| c.name.is_none())
        {
            s.client
                .contact_rename(from, name)
                .map_err(storage_error("contact"))?;
        }
    }
    s.client
        .request_resolve(group_id, accept)
        .map_err(storage_error("request"))?;
    record_change(StateChange::RequestAnswered {
        group_id: group_id.to_vec(),
        accepted: accept,
    });
    Ok(())
}

/// Make a card for this device: `in_person` for a code shown on this
/// screen, otherwise a link to share.
pub(crate) fn offer_card(config: &ProfileConfig, in_person: bool) -> Result<CardOffer, CliError> {
    let (client, device, realm) = enrolled(config)?;
    let mailbox = client
        .mailbox_own()
        .map_err(storage_error("mailbox"))?
        .ok_or_else(|| CliError::Domain("no mailbox yet; finish enrolling first".into()))?;
    let route = parse_route(&route_string(&client, &device, &mailbox)?)?;
    let kind = if in_person {
        CardKind::InPerson
    } else {
        CardKind::Link
    };
    let card = client
        .card_create(kind, unix_now())
        .map_err(storage_error("card"))?;
    let link = Card::Contact {
        realm: Realm {
            signing_key: realm.signing_public,
            noise_public: realm.noise_public.clone(),
            url: realm.preferred_endpoint_url().to_owned(),
        },
        route: CardRoute::from_route(&route),
        secret: card.secret.clone(),
        name: client.card_name().map_err(storage_error("card name"))?,
    }
    .link(DEFAULT_LINK_BASE)
    .map_err(|e| CliError::Domain(format!("card: {e}")))?;
    Ok(CardOffer {
        secret: card.secret,
        link,
        in_person,
        created_at: card.created_at,
        expires_at: card.expires_at,
    })
}

/// Read a contact card and say who it names, for this realm only.
pub(crate) fn preview_card(config: &ProfileConfig, text: &str) -> Result<CardPreview, CliError> {
    let (route, name, _) = card_route(config, text)?;
    let client = open_client(config)?;
    let preview = crate::conversation_ui::preview(config, std::slice::from_ref(&route))?
        .into_iter()
        .next()
        .ok_or_else(|| CliError::Domain("card: no route".into()))?;
    let known = client
        .contact(&preview.identity_id)
        .map_err(storage_error("contact"))?;
    Ok(CardPreview {
        identity_id: preview.identity_id,
        name,
        known_as: known.as_ref().and_then(|c| c.name.clone()),
        safety_number: preview.safety_number,
        verified: known.is_some_and(|c| c.verified),
    })
}

/// The route and self-description a card carries, refusing a card for
/// another realm or for this very identity.
fn card_route(
    config: &ProfileConfig,
    text: &str,
) -> Result<(String, Option<String>, Vec<u8>), CliError> {
    let card = Card::find(text).map_err(|e| CliError::Domain(format!("card: {e}")))?;
    let Card::Contact {
        realm,
        route,
        secret,
        name,
    } = card
    else {
        return Err(CliError::Domain(format!(
            "this is a {} code, not a contact",
            card.kind()
        )));
    };
    let (client, _, own_realm) = enrolled(config)?;
    if realm.realm_id() != own_realm.realm_id {
        return Err(CliError::Domain(
            "card: this person uses another server; both of you need the same one".into(),
        ));
    }
    let route = route
        .route()
        .map_err(|e| CliError::Domain(format!("card: {e}")))?;
    let parsed = parse_route(&route)?;
    if client.identity_id().map_err(storage_error("identity"))? == Some(parsed.identity_id) {
        return Err(CliError::Domain("card: this is your own card".into()));
    }
    Ok((route, name, secret))
}

/// Start talking to the person a card names. `scanned` says it was read in
/// person from their screen: the root it names is then verified in person.
pub(crate) async fn start_from_card(
    config: &ProfileConfig,
    bootstrap: &str,
    text: &str,
    scanned: bool,
) -> Result<(), CliError> {
    let (route, name, secret) = card_route(config, text)?;
    let own_name = open_client(config)?
        .card_name()
        .map_err(storage_error("card name"))?;
    let hello = Hello {
        secret: Some(serde_bytes::ByteBuf::from(secret)),
        name: own_name,
    };
    Box::pin(start_with(
        config,
        bootstrap,
        &[route.as_str()],
        Some(hello),
    ))
    .await?;
    let parsed = parse_route(&route)?;
    let client = open_client(config)?;
    client
        .contact_route_save(&parsed.identity_id, &parsed.device_id, &route)
        .map_err(storage_error("contact"))?;
    if let Some(name) = name
        && client
            .contact(&parsed.identity_id)
            .map_err(storage_error("contact"))?
            .is_some_and(|c| c.name.is_none())
    {
        client
            .contact_rename(&parsed.identity_id, &name)
            .map_err(storage_error("contact"))?;
    }
    if scanned {
        client
            .contact_verified(&parsed.identity_id, VerifiedHow::InPerson, unix_now())
            .map_err(storage_error("contact"))?;
        record_change(StateChange::ContactVerifiedInPerson {
            group_id: Vec::new(),
            identity_id: parsed.identity_id,
        });
    }
    Ok(())
}

/// Whether what arrives for a conversation is dropped: it was declined.
pub(crate) fn declined(s: &Session, gid: &[u8]) -> Result<bool, CliError> {
    Ok(s.client
        .request(gid)
        .map_err(storage_error("request"))?
        .is_some_and(|r| r.status == RequestStatus::Declined))
}

#[cfg(test)]
mod tests {
    use super::*;
    use arveil_core::channel::endpoints::{self, Endpoint, RealmEndpointList};

    #[test]
    fn contact_codes_shared_links_and_reopened_server_details_use_the_current_route() {
        let mut nonce = [0; 12];
        getrandom::fill(&mut nonce).unwrap();
        let dir = std::env::temp_dir().join(format!("arveil-card-route-{}", hex::encode(nonce)));
        std::fs::create_dir_all(&dir).unwrap();
        let config = ProfileConfig::unencrypted(&dir);
        let signing = ed25519_dalek::SigningKey::from_bytes(&[9; 32]);
        let realm_id = endpoints::realm_id(&signing.verifying_key());
        let original = "ws://192.0.2.1:8447/v1/channel";
        let public = "wss://relay.example.org/v1/channel";
        let client = open_client(&config).unwrap();
        client.identity_new().unwrap();
        client.device_new(1_800_000_000).unwrap();
        client
            .realm_save(&realm_id, &signing.verifying_key(), &[8; 32], original)
            .unwrap();
        client.realm_mark_enrolled(&realm_id).unwrap();
        client
            .mailbox_save(&OwnMailbox {
                mailbox_id: vec![1; 16],
                read_capability: vec![2; 32],
                write_capability: vec![3; 32],
            })
            .unwrap();
        let endpoints = RealmEndpointList {
            version: 1,
            realm_id: realm_id.clone(),
            sequence: 2,
            realm_noise_public_key: vec![7; 32],
            endpoints: vec![
                Endpoint {
                    kind: "tailnet".into(),
                    url: original.into(),
                    priority: 20,
                },
                Endpoint {
                    kind: "admin".into(),
                    url: "http://127.0.0.1/admin".into(),
                    priority: 0,
                },
                Endpoint {
                    kind: "public".into(),
                    url: public.into(),
                    priority: 1,
                },
            ],
        };
        client
            .realm_accept_endpoint_list(
                &realm_id,
                &arveil_core::signed::sign_value(endpoints::CONTEXT, &endpoints, &signing).unwrap(),
            )
            .unwrap();
        drop(client);

        // No network is available: both card forms must work from the
        // persisted verified list after reopening, including its current key.
        for in_person in [true, false] {
            let offer = offer_card(&config, in_person).unwrap();
            let Card::Contact { realm, route, .. } = Card::parse(&offer.link).unwrap() else {
                panic!("expected a contact card")
            };
            assert_eq!(realm.url, public);
            assert_eq!(realm.noise_public, vec![7; 32]);
            assert_eq!(realm.signing_key, signing.verifying_key());
            let (client, device, _) = enrolled(&config).unwrap();
            assert_eq!(route.device_id, device.keys.device_id);
            assert_eq!(client.realm().unwrap().unwrap().bootstrap_url, original);
        }
        let status = crate::onboarding::status(&config).unwrap();
        let bootstrap = Bootstrap::parse(&status.bootstrap.unwrap()).unwrap();
        assert_eq!(bootstrap.url, public);
        assert_eq!(bootstrap.noise_public, vec![7; 32]);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
