//! One durable operation from admission to a conversation. The relay only
//! sees hashes and admission receipts; the contact travels in the shared link.
use super::*;
use crate::links::{Card, CardRoute, DEFAULT_LINK_BASE, Realm, clean_name};
use arveil_core::channel::codec::InvitationRecord;
use arveil_core::client::{InvitationHello, InvitationOperation, operation_digest};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum InvitationAction {
    Policy,
    Create,
    RetryIssue {
        id: Vec<u8>,
    },
    List {
        refresh: bool,
    },
    Revoke {
        id: Vec<u8>,
    },
    Accept {
        text: Option<String>,
        name: Option<String>,
    },
    Pending,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InvitationPolicy {
    pub can_invite: bool,
    pub server_time: u64,
    pub ttl: u64,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InvitationView {
    pub id: Vec<u8>,
    pub state: String,
    pub created_at: i64,
    pub expires_at: i64,
    pub link: Option<String>,
    pub group_id: Vec<u8>,
    pub checked_at: i64,
    pub name: Option<String>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum InvitationOutput {
    Policy(InvitationPolicy),
    Items(Vec<InvitationView>),
    Item(InvitationView),
    Pending(Option<InvitationView>),
}
impl From<links::LinkError> for CliError {
    fn from(_: links::LinkError) -> Self {
        failure("invalid invitation")
    }
}
fn failure(reason: &str) -> CliError {
    CliError::Domain(format!("invitation: {reason}"))
}
fn save(c: &Client, o: &InvitationOperation) -> Result<(), CliError> {
    c.invitation_operation_save(o)
        .map_err(storage_error("invitation"))
}
fn view(o: InvitationOperation) -> InvitationView {
    let name = match Card::parse(&o.link) {
        Ok(Card::Invitation { name, .. }) => name,
        _ => None,
    };
    let state = if o.direction == "outgoing" && o.state == "pending" && o.expires_at <= unix_now() {
        "expired".into()
    } else {
        o.state
    };
    let link = if state == "pending" && !o.link.is_empty() {
        Some(o.link)
    } else {
        None
    };
    InvitationView {
        id: o.id,
        state,
        created_at: o.created_at,
        expires_at: o.expires_at,
        link,
        group_id: o.group_id,
        checked_at: o.checked_at,
        name,
    }
}
fn request_key(server_time: u64) -> Result<Vec<u8>, CliError> {
    let mut key = vec![0; 24];
    key[..8].copy_from_slice(&server_time.to_be_bytes());
    getrandom::fill(&mut key[8..]).map_err(domain_error("random"))?;
    Ok(key)
}
fn blank(id: Vec<u8>, direction: &str) -> InvitationOperation {
    InvitationOperation {
        id,
        direction: direction.into(),
        link: String::new(),
        request_key: vec![],
        claim_key: vec![],
        secret: vec![],
        state: "prepared".into(),
        created_at: unix_now(),
        expires_at: 0,
        claimant: vec![],
        group_id: vec![],
        key_package: vec![],
        checked_at: 0,
    }
}
async fn connection(config: &ProfileConfig) -> Result<Connection, CliError> {
    let (s, _) = session(config)?;
    let realm = Realm {
        signing_key: s.realm.signing_public,
        noise_public: s.realm.noise_public.clone(),
        url: s.realm.preferred_endpoint_url().into(),
    };
    connect(config, &s, &Bootstrap::parse(&realm.bootstrap())?).await
}
async fn policy(conn: &mut Connection) -> Result<InvitationPolicy, CliError> {
    match conn.request(Payload::InvitePolicyGet).await {
        Ok(Payload::InvitePolicy {
            can_invite,
            server_time,
            ttl,
        }) if ttl > 0 && ttl <= 7 * 24 * 3600 && server_time <= (i64::MAX as u64) - ttl => {
            Ok(InvitationPolicy {
                can_invite,
                server_time,
                ttl,
            })
        }
        Err(CliError::Relay { code: 400, .. }) => Err(failure("server update required")),
        Err(e) => Err(e),
        _ => Err(failure("invalid server reply")),
    }
}
fn apply_record(o: &mut InvitationOperation, r: InvitationRecord) -> Result<(), CliError> {
    if o.id != r.id
        || r.created_at > i64::MAX as u64
        || r.expires_at > i64::MAX as u64
        || !matches!(r.state.as_str(), "pending" | "used" | "revoked" | "expired")
    {
        return Err(failure("invalid server reply"));
    }
    if r.state == "used" && r.claimed_identity.len() != 32 {
        return Err(failure("invalid claim"));
    }
    o.state = if r.state == "used" && !o.group_id.is_empty() {
        "connected".into()
    } else {
        r.state
    };
    o.created_at = r.created_at as i64;
    o.expires_at = r.expires_at as i64;
    o.claimant = r.claimed_identity;
    o.checked_at = unix_now();
    Ok(())
}
async fn issue(config: &ProfileConfig, id: Option<Vec<u8>>) -> Result<InvitationView, CliError> {
    let (c, device, _) = enrolled(config)?;
    let mut conn = connection(config).await?;
    let policy = policy(&mut conn).await?;
    if !policy.can_invite {
        return Err(failure("owner permission required"));
    }
    key_packages::maintain(&c, &device, &mut conn, true).await?;
    // connect() may just have learned a signed endpoint update. Read the
    // persisted realm again so a new card never embeds the stale snapshot.
    let realm = c
        .realm()
        .map_err(storage_error("realm"))?
        .ok_or_else(|| failure("finish enrollment"))?;
    let mut op = if let Some(id) = id {
        c.invitation_operation(&id, "outgoing")
            .map_err(storage_error("invitation"))?
            .ok_or_else(|| failure("unknown invitation"))?
    } else if let Some(op) = c
        .invitation_operations("outgoing")
        .map_err(storage_error("invitation"))?
        .into_iter()
        .find(|o| o.state == "issuing")
    {
        op
    } else {
        let mailbox = c
            .mailbox_own()
            .map_err(storage_error("mailbox"))?
            .ok_or_else(|| failure("finish enrollment"))?;
        let route = CardRoute::from_route(&parse_route(&route_string(&c, &device, &mailbox)?)?);
        let mut token = vec![0; 32];
        let mut secret = vec![0; 16];
        getrandom::fill(&mut token).map_err(domain_error("random"))?;
        getrandom::fill(&mut secret).map_err(domain_error("random"))?;
        let mut op = blank(operation_digest(&token), "outgoing");
        op.request_key = request_key(policy.server_time)?;
        op.secret = secret.clone();
        op.state = "issuing".into();
        op.expires_at = (policy.server_time + policy.ttl) as i64;
        op.link = Card::Invitation {
            realm: Realm {
                signing_key: realm.signing_public,
                noise_public: realm.noise_public.clone(),
                url: realm.preferred_endpoint_url().into(),
            },
            invitation: token,
            expires_at: op.expires_at as u64,
            route,
            secret,
            name: c.card_name().map_err(storage_error("name"))?,
        }
        .link(DEFAULT_LINK_BASE)?;
        save(&c, &op)?;
        op
    };
    if op.state != "issuing" {
        return Ok(view(op));
    }
    let reply = conn
        .request(Payload::InviteCreate {
            request_key: op.request_key.clone(),
            token_hash: op.id.clone(),
            ttl: policy.ttl,
        })
        .await?;
    let Payload::Invitation { invitation } = reply else {
        return Err(failure("invalid server reply"));
    };
    apply_record(&mut op, invitation)?;
    let mut card = Card::parse(&op.link)?;
    if let Card::Invitation { expires_at, .. } = &mut card {
        *expires_at = op.expires_at as u64
    };
    op.link = card.link(DEFAULT_LINK_BASE)?;
    save(&c, &op)?;
    Ok(view(op))
}
async fn list(config: &ProfileConfig, refresh: bool) -> Result<Vec<InvitationView>, CliError> {
    let c = open_client(config)?;
    if refresh {
        let mut conn = connection(config).await?;
        policy(&mut conn).await?;
        let mut cursor = 0;
        loop {
            let reply = conn
                .request(Payload::InviteList { cursor, limit: 50 })
                .await?;
            let Payload::Invitations {
                invitations,
                next_cursor,
            } = reply
            else {
                return Err(failure("invalid server reply"));
            };
            let done = invitations.len() < 50;
            for row in invitations {
                let mut op = c
                    .invitation_operation(&row.id, "outgoing")
                    .map_err(storage_error("invitation"))?
                    .unwrap_or_else(|| blank(row.id.clone(), "outgoing"));
                apply_record(&mut op, row)?;
                save(&c, &op)?
            }
            if done {
                break;
            };
            if next_cursor <= cursor {
                return Err(failure("invalid page"));
            };
            cursor = next_cursor;
        }
    }
    c.invitation_cleanup(unix_now())
        .map_err(storage_error("invitation"))?;
    Ok(c.invitation_operations("outgoing")
        .map_err(storage_error("invitation"))?
        .into_iter()
        .map(view)
        .collect())
}
async fn revoke(config: &ProfileConfig, id: &[u8]) -> Result<InvitationView, CliError> {
    let c = open_client(config)?;
    let mut op = c
        .invitation_operation(id, "outgoing")
        .map_err(storage_error("invitation"))?
        .ok_or_else(|| failure("unknown invitation"))?;
    if !op.group_id.is_empty() {
        return Err(failure("already used"));
    }
    op.state = "revoke-pending".into();
    save(&c, &op)?;
    let mut conn = connection(config).await?;
    // A lost create reply is not proof the server did nothing. Resolve the
    // same request first, then revoke it. An old pruned request cannot reissue.
    if !op.request_key.is_empty() {
        match conn
            .request(Payload::InviteGet {
                invitation_id: id.into(),
            })
            .await
        {
            Err(CliError::Relay { code: 410, .. }) => {
                match conn
                    .request(Payload::InviteCreate {
                        request_key: op.request_key.clone(),
                        token_hash: op.id.clone(),
                        ttl: 7 * 24 * 3600,
                    })
                    .await
                {
                    Err(CliError::Relay { code: 410, .. }) => {
                        op.state = "revoked".into();
                        op.link.clear();
                        op.secret.clear();
                        save(&c, &op)?;
                        return Ok(view(op));
                    }
                    Err(e) => return Err(e),
                    _ => (),
                }
            }
            Err(e) => return Err(e),
            _ => (),
        }
    }
    let reply = match conn
        .request(Payload::InviteRevoke {
            invitation_id: id.into(),
        })
        .await
    {
        Err(CliError::Relay { code: 409, .. }) => {
            conn.request(Payload::InviteGet {
                invitation_id: id.into(),
            })
            .await?
        }
        other => other?,
    };
    let Payload::Invitation { invitation } = reply else {
        return Err(failure("invalid server reply"));
    };
    apply_record(&mut op, invitation)?;
    if op.state == "revoked" {
        op.link.clear();
        op.secret.clear()
    };
    save(&c, &op)?;
    Ok(view(op))
}
fn pending(config: &ProfileConfig) -> Result<Option<InvitationView>, CliError> {
    Ok(open_client(config)?
        .invitation_operations("incoming")
        .map_err(storage_error("invitation"))?
        .into_iter()
        .find(|o| !matches!(o.state.as_str(), "complete" | "unavailable"))
        .map(view))
}
async fn accept(
    config: &ProfileConfig,
    text: Option<String>,
    name: Option<String>,
) -> Result<InvitationView, CliError> {
    let c = open_client(config)?;
    let mut op = if let Some(text) = text {
        let card = Card::find(&text)?;
        let Card::Invitation {
            ref realm,
            ref invitation,
            ref route,
            ref secret,
            expires_at,
            ..
        } = card
        else {
            return Err(failure("not a personal invitation"));
        };
        if c.realm()
            .map_err(storage_error("realm"))?
            .is_some_and(|r| r.realm_id != realm.realm_id())
        {
            return Err(failure("different server"));
        }
        if c.identity_id().map_err(storage_error("identity"))?
            == Some(parse_route(&route.route()?)?.identity_id)
        {
            return Err(failure("own invitation"));
        }
        let id = operation_digest(invitation);
        let existing = c
            .invitation_operations("incoming")
            .map_err(storage_error("invitation"))?;
        if existing
            .iter()
            .any(|o| o.id != id && !matches!(o.state.as_str(), "complete" | "unavailable"))
        {
            return Err(failure("another invitation is in progress"));
        }
        if let Some(o) = c
            .invitation_operation(&id, "incoming")
            .map_err(storage_error("invitation"))?
        {
            o
        } else {
            let mut o = blank(id, "incoming");
            o.link = card.link(DEFAULT_LINK_BASE)?;
            o.secret = secret.clone();
            o.expires_at = expires_at as i64;
            o.state = "accepting".into();
            save(&c, &o)?;
            if let Some(name) = name {
                c.card_name_set(clean_name(&name).as_deref())
                    .map_err(storage_error("name"))?
            };
            o
        }
    } else {
        c.invitation_operations("incoming")
            .map_err(storage_error("invitation"))?
            .into_iter()
            .find(|o| !matches!(o.state.as_str(), "complete" | "unavailable"))
            .ok_or_else(|| failure("no pending invitation"))?
    };
    if op.state == "complete" {
        return Ok(view(op));
    }
    if op.state == "unavailable" {
        return Err(CliError::Relay {
            code: 410,
            message: "invitation unavailable".into(),
        });
    }
    let Card::Invitation {
        realm,
        invitation,
        route,
        secret,
        ..
    } = Card::parse(&op.link)?
    else {
        return Err(failure("invalid saved invitation"));
    };
    let needs_enrollment = !c
        .realm()
        .map_err(storage_error("realm"))?
        .is_some_and(|r| r.enrolled)
        || c.enrollment()
            .map_err(storage_error("enrollment"))?
            .is_some_and(|e| e.phase != EnrollmentPhase::Complete);
    if needs_enrollment
        && let Err(e) =
            onboarding::enroll(config, &realm.bootstrap(), &hex::encode(&invitation)).await
    {
        if e.relay_code() == Some(410) {
            c.unit_of_work(|| {
                if c.invitation_rejected_enrollment(&op.id)? {
                    op.state = "unavailable".into();
                    op.link.clear();
                    op.secret.clear();
                    c.invitation_operation_save(&op)?;
                }
                Ok::<_, arveil_core::client::ClientError>(())
            })
            .map_err(storage_error("invitation rejection"))?;
        }
        return Err(e);
    }
    let mut conn = connection(config).await?;
    if op.state == "accepting" {
        let reply = match conn
            .request(Payload::InviteAccept { token: invitation })
            .await
        {
            Err(e) if matches!(e.relay_code(), Some(409 | 410)) => {
                op.state = "unavailable".into();
                op.link.clear();
                op.secret.clear();
                save(&c, &op)?;
                return Err(e);
            }
            other => other?,
        };
        let Payload::Invitation {
            invitation: receipt,
        } = reply
        else {
            return Err(failure("invalid server reply"));
        };
        if receipt.id != op.id
            || Some(receipt.claimed_identity.clone())
                != c.identity_id().map_err(storage_error("identity"))?
            || receipt.state != "used"
        {
            return Err(failure("invalid claim"));
        }
        op.state = "enrolled".into();
        op.claimant = receipt.claimed_identity;
        op.checked_at = unix_now();
        save(&c, &op)?;
    }
    if op.claim_key.is_empty() {
        let p = policy(&mut conn).await?;
        op.claim_key = request_key(p.server_time)?;
        save(&c, &op)?
    }
    conn.close().await;
    let text = route.route()?;
    let hello = Hello {
        secret: Some(secret.into()),
        name: c.card_name().map_err(storage_error("name"))?,
        invitation: Some(op.id.clone().into()),
    };
    start_with_operation(
        config,
        &realm.bootstrap(),
        &[text.as_str()],
        Some(hello),
        Some(op.clone()),
    )
    .await?;
    op = c
        .invitation_operation(&op.id, "incoming")
        .map_err(storage_error("invitation"))?
        .ok_or_else(|| failure("missing progress"))?;
    let (s, _) = session(config)?;
    let (pending, failed) = s
        .delivery
        .notification_counts(&op.id, unix_now())
        .map_err(storage_error("invitation delivery"))?;
    if pending > 0 || failed > 0 {
        return Err(failure("contact route unavailable"));
    }
    let parsed = parse_route(&text)?;
    c.unit_of_work(|| {
        c.contact_route_save(&parsed.identity_id, &parsed.device_id, &text)?;
        if let Ok(Card::Invitation {
            name: Some(name), ..
        }) = Card::parse(&op.link)
            && c.contact(&parsed.identity_id)?
                .is_some_and(|c| c.name.is_none())
        {
            c.contact_rename(&parsed.identity_id, &name)?;
        }
        op.state = "complete".into();
        op.link.clear();
        op.secret.clear();
        op.key_package.clear();
        c.invitation_operation_save(&op)
    })
    .map_err(storage_error("invitation completion"))?;
    Ok(view(op))
}

pub(crate) async fn execute(
    config: &ProfileConfig,
    action: InvitationAction,
) -> Result<InvitationOutput, CliError> {
    match action {
        InvitationAction::Policy => {
            let mut conn = connection(config).await?;
            Ok(InvitationOutput::Policy(policy(&mut conn).await?))
        }
        InvitationAction::Create => issue(config, None).await.map(InvitationOutput::Item),
        InvitationAction::RetryIssue { id } => {
            issue(config, Some(id)).await.map(InvitationOutput::Item)
        }
        InvitationAction::List { refresh } => {
            list(config, refresh).await.map(InvitationOutput::Items)
        }
        InvitationAction::Revoke { id } => revoke(config, &id).await.map(InvitationOutput::Item),
        InvitationAction::Accept { text, name } => {
            accept(config, text, name).await.map(InvitationOutput::Item)
        }
        InvitationAction::Pending => pending(config).map(InvitationOutput::Pending),
    }
}

/// Match the encrypted hello to a secret issued on this device; ordinary cards
/// remain separate. Sender/root binding is checked against the roster at sync.
pub(crate) fn remember_hello(
    s: &Session,
    gid: &[u8],
    sender: Option<&[u8]>,
    hello: &Hello,
) -> Result<bool, CliError> {
    let (Some(id), Some(secret), Some(sender)) = (&hello.invitation, &hello.secret, sender) else {
        return Ok(false);
    };
    let Some(op) = s
        .client
        .invitation_operation(id, "outgoing")
        .map_err(storage_error("invitation"))?
    else {
        return Ok(false);
    };
    if secret.as_ref() != op.secret.as_slice() || secret.len() != 16 || op.state == "revoked" {
        return Ok(false);
    }
    s.client
        .invitation_hello_save(&InvitationHello {
            group_id: gid.into(),
            invitation_id: id.to_vec(),
            sender: sender.into(),
            name: hello.name.as_deref().and_then(clean_name),
        })
        .map_err(storage_error("invitation"))?;
    Ok(true)
}

pub(crate) async fn settle<C: MlsConfig>(
    s: &Session,
    engine: &Engine<C>,
    conn: &mut Connection,
) -> Result<(), CliError> {
    for h in s
        .client
        .invitation_hellos()
        .map_err(storage_error("invitation"))?
    {
        let Some(mut op) = s
            .client
            .invitation_operation(&h.invitation_id, "outgoing")
            .map_err(storage_error("invitation"))?
        else {
            continue;
        };
        if matches!(op.state.as_str(), "revoked" | "revoke-pending")
            || (!op.group_id.is_empty() && op.group_id != h.group_id)
        {
            continue;
        }
        let reply = match conn
            .request(Payload::InviteGet {
                invitation_id: op.id.clone(),
            })
            .await
        {
            // A receipt beyond retention cannot prove automatic consent.
            // Keep the ordinary request without blocking later invitation completion.
            Err(CliError::Relay { code: 410, .. }) => {
                s.client
                    .invitation_hello_remove(&h.group_id)
                    .map_err(storage_error("invitation"))?;
                continue;
            }
            other => other?,
        };
        let Payload::Invitation {
            invitation: receipt,
        } = reply
        else {
            continue;
        };
        if receipt.id != op.id
            || receipt.state != "used"
            || receipt.claimed_identity != h.sender
            || receipt.claimed_at > receipt.expires_at
        {
            continue;
        }
        if s.client
            .request(&h.group_id)
            .map_err(storage_error("request"))?
            .is_some_and(|r| r.status == arveil_core::client::RequestStatus::Declined)
        {
            s.client
                .invitation_hello_remove(&h.group_id)
                .map_err(storage_error("invitation"))?;
            continue;
        }
        let conversations = s
            .client
            .conversations()
            .map_err(storage_error("conversations"))?;
        let Some(conv) = conversations.iter().find(|c| c.group_id == h.group_id) else {
            continue;
        };
        let group = engine
            .load_group(&h.group_id)
            .map_err(storage_error("mls load"))?;
        for peer in conv.peers.iter().filter(|p| p.identity == h.sender) {
            let Some(text) = route_of_peer(peer) else {
                continue;
            };
            let parsed = parse_route(&text)?;
            let credential = match verified_route_credential(conn, &parsed).await {
                Ok(c) => c,
                Err(CliError::Domain(_)) => continue,
                Err(e) => return Err(e),
            };
            let valid = group.roster().members().into_iter().any(|m| {
                m.signing_identity
                    .credential
                    .as_basic()
                    .is_some_and(|b| b.identifier() == parsed.device_id.as_slice())
                    && m.signing_identity.signature_key.as_bytes()
                        == credential.mls_signature_public_key.as_slice()
            });
            if !valid {
                continue;
            }
            apply_record(&mut op, receipt.clone())?;
            op.state = "connected".into();
            op.group_id = h.group_id.clone();
            op.link.clear();
            s.client
                .unit_of_work(|| {
                    s.client
                        .contact_route_save(&h.sender, &parsed.device_id, &text)?;
                    if let Some(name) = &h.name
                        && s.client
                            .contact(&h.sender)?
                            .is_some_and(|c| c.name.is_none())
                    {
                        s.client.contact_rename(&h.sender, name)?;
                    }
                    s.client.request_resolve(&h.group_id, true)?;
                    s.client.invitation_operation_save(&op)?;
                    s.client.invitation_hello_remove(&h.group_id)
                })
                .map_err(storage_error("invitation contact"))?;
            break;
        }
    }
    Ok(())
}
