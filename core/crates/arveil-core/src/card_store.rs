//! Contact cards this device showed or shared, and conversations started by
//! people who are not contacts yet (ADR-012 §4). Same encrypted connection
//! as the rest of the profile; the schema is version 7 of [`crate::schema`].

use rusqlite::{OptionalExtension, params};

use super::{Client, ClientError, hex_of};

/// How long an in-person code stays valid at most, even with its screen
/// open.
pub const IN_PERSON_SECONDS: i64 = 10 * 60;
/// How long a shared contact link stays valid unless revoked.
pub const LINK_SECONDS: i64 = 30 * 24 * 60 * 60;

/// Which way a card travels.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CardKind {
    /// Shown on this screen to someone in front of it: once, briefly.
    InPerson,
    /// Sent as a link: for 30 days, until revoked.
    Link,
}

impl CardKind {
    fn as_str(self) -> &'static str {
        match self {
            CardKind::InPerson => "in-person",
            CardKind::Link => "link",
        }
    }

    fn parse(s: &str) -> Option<Self> {
        match s {
            "in-person" => Some(CardKind::InPerson),
            "link" => Some(CardKind::Link),
            _ => None,
        }
    }
}

/// A card this device made.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OwnCard {
    pub secret: Vec<u8>,
    pub kind: CardKind,
    pub created_at: i64,
    pub expires_at: i64,
    pub used_at: Option<i64>,
    pub revoked: bool,
}

/// How a verified contact was verified.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VerifiedHow {
    /// The two people read the same safety number.
    Comparison,
    /// One scanned the other's code in person.
    InPerson,
}

impl VerifiedHow {
    fn as_str(self) -> &'static str {
        match self {
            VerifiedHow::Comparison => "comparison",
            VerifiedHow::InPerson => "in-person",
        }
    }

    pub(super) fn parse(s: &str) -> Option<Self> {
        match s {
            "comparison" => Some(VerifiedHow::Comparison),
            "in-person" => Some(VerifiedHow::InPerson),
            _ => None,
        }
    }
}

/// Where a conversation stands for this device.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RequestStatus {
    /// Started by someone who is not a contact: waits for an answer.
    Pending,
    /// Declined: hidden, and what arrives for it is dropped.
    Declined,
}

/// What a card did for a conversation that someone started.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CardUse {
    /// No card of this device, or one that is no longer valid.
    None,
    /// A shared link made at this time.
    Link { created_at: i64 },
    /// The in-person code, still to be bound to the sender's root.
    InPersonPending,
    /// The in-person code, bound: the sender is verified in person.
    InPerson,
}

/// A conversation waiting for, or refused by, the person's answer.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Request {
    pub group_id: Vec<u8>,
    pub status: RequestStatus,
    /// Who started it, once the roster said so.
    pub from: Option<Vec<u8>>,
    pub card: CardUse,
    /// How they describe themselves; shown, never trusted.
    pub name: Option<String>,
}

/// `request, request_from, request_card, request_card_at, request_name`.
type RequestRow = (
    Option<i64>,
    Option<Vec<u8>>,
    Option<String>,
    Option<i64>,
    Option<String>,
);

fn card_use(kind: Option<String>, at: Option<i64>) -> CardUse {
    match (kind.as_deref(), at) {
        (Some("link"), Some(created_at)) => CardUse::Link { created_at },
        (Some("in-person-pending"), _) => CardUse::InPersonPending,
        (Some("in-person"), _) => CardUse::InPerson,
        _ => CardUse::None,
    }
}

impl Client {
    /// Make a card secret of this kind, valid from `now`.
    pub fn card_create(&self, kind: CardKind, now: i64) -> Result<OwnCard, ClientError> {
        let mut secret = vec![0u8; 16];
        getrandom::fill(&mut secret).map_err(|_| crate::identity::IdentityError::Random)?;
        let expires_at = now
            + match kind {
                CardKind::InPerson => IN_PERSON_SECONDS,
                CardKind::Link => LINK_SECONDS,
            };
        self.conn.lock().execute(
            "INSERT INTO contact_cards (secret, kind, created_at, expires_at) VALUES (?1, ?2, ?3, ?4)",
            params![secret, kind.as_str(), now, expires_at],
        )?;
        Ok(OwnCard {
            secret,
            kind,
            created_at: now,
            expires_at,
            used_at: None,
            revoked: false,
        })
    }

    /// Stop a card from working: an in-person code whose screen closed, or a
    /// link the person revoked.
    pub fn card_revoke(&self, secret: &[u8]) -> Result<bool, ClientError> {
        Ok(self.conn.lock().execute(
            "UPDATE contact_cards SET revoked = 1 WHERE secret = ?1 AND revoked = 0",
            params![secret],
        )? == 1)
    }

    /// Shared links that still work, newest first.
    pub fn cards_shared(&self, now: i64) -> Result<Vec<OwnCard>, ClientError> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT secret, kind, created_at, expires_at, used_at, revoked FROM contact_cards
             WHERE kind = 'link' AND revoked = 0 AND expires_at > ?1
             ORDER BY created_at DESC, secret",
        )?;
        let rows = stmt.query_map(params![now], |r| {
            Ok(OwnCard {
                secret: r.get(0)?,
                kind: CardKind::parse(&r.get::<_, String>(1)?).unwrap_or(CardKind::Link),
                created_at: r.get(2)?,
                expires_at: r.get(3)?,
                used_at: r.get(4)?,
                revoked: r.get::<_, i64>(5)? != 0,
            })
        })?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    /// Spend a card secret a conversation carried. A valid in-person code
    /// works once; a link works until it expires or is revoked. Anything
    /// else, unknown secrets included, is [`None`].
    pub fn card_redeem(&self, secret: &[u8], now: i64) -> Result<Option<OwnCard>, ClientError> {
        let conn = self.conn.lock();
        let card: Option<(String, i64, i64, Option<i64>, i64)> = conn
            .query_row(
                "SELECT kind, created_at, expires_at, used_at, revoked FROM contact_cards WHERE secret = ?1",
                params![secret],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
            )
            .optional()?;
        let Some((kind, created_at, expires_at, used_at, revoked)) = card else {
            return Ok(None);
        };
        let Some(kind) = CardKind::parse(&kind) else {
            return Ok(None);
        };
        if revoked != 0 || now >= expires_at || (kind == CardKind::InPerson && used_at.is_some()) {
            return Ok(None);
        }
        conn.execute(
            "UPDATE contact_cards SET used_at = COALESCE(used_at, ?2) WHERE secret = ?1",
            params![secret, now],
        )?;
        Ok(Some(OwnCard {
            secret: secret.to_vec(),
            kind,
            created_at,
            expires_at,
            used_at: Some(used_at.unwrap_or(now)),
            revoked: false,
        }))
    }

    /// The name this person puts on their cards, if any.
    pub fn card_name(&self) -> Result<Option<String>, ClientError> {
        Ok(self
            .conn
            .lock()
            .query_row("SELECT name FROM own_card WHERE id = 1", [], |r| r.get(0))
            .optional()?
            .flatten())
    }

    pub fn card_name_set(&self, name: Option<&str>) -> Result<(), ClientError> {
        self.conn.lock().execute(
            "INSERT INTO own_card (id, name) VALUES (1, ?1)
             ON CONFLICT(id) DO UPDATE SET name = excluded.name",
            params![name],
        )?;
        Ok(())
    }

    /// Make someone a contact this person chose: their conversations are
    /// joined without asking from now on.
    pub fn contact_accept(&self, identity: &[u8]) -> Result<(), ClientError> {
        let n = self.conn.lock().execute(
            "UPDATE contacts SET accepted = 1 WHERE identity_id = ?1",
            params![identity],
        )?;
        if n == 0 {
            return Err(ClientError::NoSuchContact(hex_of(identity)));
        }
        Ok(())
    }

    /// Pin a contact as verified, saying how.
    pub fn contact_verified(
        &self,
        identity: &[u8],
        how: VerifiedHow,
        now: i64,
    ) -> Result<(), ClientError> {
        let n = self.conn.lock().execute(
            "UPDATE contacts SET verified = 1, verified_at = ?2, verified_how = ?3, accepted = 1
             WHERE identity_id = ?1",
            params![identity, now, how.as_str()],
        )?;
        if n == 0 {
            return Err(ClientError::NoSuchContact(hex_of(identity)));
        }
        Ok(())
    }

    /// A conversation just joined from a Welcome waits for an answer until
    /// its roster says a contact started it.
    pub fn request_open(&self, group_id: &[u8]) -> Result<(), ClientError> {
        self.conn.lock().execute(
            "UPDATE conversations SET request = 1 WHERE group_id = ?1 AND request IS NULL",
            params![group_id],
        )?;
        Ok(())
    }

    pub fn request(&self, group_id: &[u8]) -> Result<Option<Request>, ClientError> {
        let conn = self.conn.lock();
        let row: Option<RequestRow> = conn
            .query_row(
                "SELECT request, request_from, request_card, request_card_at, request_name
                 FROM conversations WHERE group_id = ?1",
                params![group_id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
            )
            .optional()?;
        Ok(row.and_then(|(status, from, card, at, name)| {
            let status = match status {
                Some(1) => RequestStatus::Pending,
                Some(2) => RequestStatus::Declined,
                _ => return None,
            };
            Some(Request {
                group_id: group_id.to_vec(),
                status,
                from,
                card: card_use(card, at),
                name,
            })
        }))
    }

    /// Who started a conversation, as its first roster says. Set once.
    pub fn request_set_from(&self, group_id: &[u8], identity: &[u8]) -> Result<(), ClientError> {
        self.conn.lock().execute(
            "UPDATE conversations SET request_from = ?2 WHERE group_id = ?1 AND request_from IS NULL",
            params![group_id, identity],
        )?;
        Ok(())
    }

    /// What the hello of a conversation carried.
    pub fn request_set_card(
        &self,
        group_id: &[u8],
        card: &CardUse,
        name: Option<&str>,
    ) -> Result<(), ClientError> {
        let (kind, at) = match card {
            CardUse::None => (None, None),
            CardUse::Link { created_at } => (Some("link"), Some(*created_at)),
            CardUse::InPersonPending => (Some("in-person-pending"), None),
            CardUse::InPerson => (Some("in-person"), None),
        };
        self.conn.lock().execute(
            "UPDATE conversations SET request_card = ?2, request_card_at = ?3,
                    request_name = COALESCE(?4, request_name)
             WHERE group_id = ?1",
            params![group_id, kind, at, name],
        )?;
        Ok(())
    }

    /// The person's answer, or a contact's conversation joined without one.
    pub fn request_resolve(&self, group_id: &[u8], accepted: bool) -> Result<(), ClientError> {
        self.conn.lock().execute(
            "UPDATE conversations SET request = ?2 WHERE group_id = ?1",
            params![group_id, if accepted { None } else { Some(2i64) }],
        )?;
        Ok(())
    }

    /// Conversations whose status the person has to see: pending requests.
    pub fn requests_pending(&self) -> Result<Vec<Request>, ClientError> {
        let groups: Vec<Vec<u8>> = {
            let conn = self.conn.lock();
            let mut stmt = conn.prepare(
                "SELECT group_id FROM conversations WHERE request = 1 ORDER BY created_at, group_id",
            )?;
            stmt.query_map([], |r| r.get(0))?
                .collect::<Result<_, _>>()?
        };
        groups
            .into_iter()
            .filter_map(|g| self.request(&g).transpose())
            .collect()
    }

    /// Conversations whose in-person code still has to be bound to the
    /// sender's root before anyone is marked verified.
    pub fn requests_in_person_pending(&self) -> Result<Vec<Request>, ClientError> {
        let groups: Vec<Vec<u8>> = {
            let conn = self.conn.lock();
            let mut stmt = conn.prepare(
                "SELECT group_id FROM conversations WHERE request_card = 'in-person-pending'",
            )?;
            stmt.query_map([], |r| r.get(0))?
                .collect::<Result<_, _>>()?
        };
        let mut out = Vec::new();
        for g in groups {
            let conn = self.conn.lock();
            let row: (Option<i64>, Option<Vec<u8>>, Option<String>) = conn.query_row(
                "SELECT request, request_from, request_name FROM conversations WHERE group_id = ?1",
                params![g],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )?;
            out.push(Request {
                group_id: g,
                status: if row.0 == Some(2) {
                    RequestStatus::Declined
                } else {
                    RequestStatus::Pending
                },
                from: row.1,
                card: CardUse::InPersonPending,
                name: row.2,
            });
        }
        Ok(out)
    }

    /// Whether this person chose this contact.
    pub fn contact_is_accepted(&self, identity: &[u8]) -> Result<bool, ClientError> {
        Ok(self
            .conn
            .lock()
            .query_row(
                "SELECT accepted FROM contacts WHERE identity_id = ?1",
                params![identity],
                |r| r.get::<_, Option<i64>>(0),
            )
            .optional()?
            .flatten()
            == Some(1))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::storage::SharedConn;

    fn client() -> Client {
        Client::open(SharedConn::open_in_memory().unwrap()).unwrap()
    }

    #[test]
    fn an_in_person_code_works_once_and_briefly_a_link_until_revoked() {
        let c = client();
        let now = 1_800_000_000;
        let code = c.card_create(CardKind::InPerson, now).unwrap();
        assert_eq!(code.expires_at, now + IN_PERSON_SECONDS);
        assert_eq!(code.secret.len(), 16);
        assert!(c.card_redeem(&code.secret, now + 5).unwrap().is_some());
        assert!(
            c.card_redeem(&code.secret, now + 6).unwrap().is_none(),
            "once"
        );
        let late = c.card_create(CardKind::InPerson, now).unwrap();
        assert!(
            c.card_redeem(&late.secret, now + IN_PERSON_SECONDS)
                .unwrap()
                .is_none()
        );
        let closed = c.card_create(CardKind::InPerson, now).unwrap();
        assert!(c.card_revoke(&closed.secret).unwrap());
        assert!(c.card_redeem(&closed.secret, now + 1).unwrap().is_none());

        let link = c.card_create(CardKind::Link, now).unwrap();
        assert_eq!(c.cards_shared(now).unwrap(), vec![link.clone()]);
        for later in [1, 2, LINK_SECONDS - 1] {
            let used = c.card_redeem(&link.secret, now + later).unwrap().unwrap();
            assert_eq!(used.created_at, now);
        }
        assert!(
            c.card_redeem(&link.secret, now + LINK_SECONDS)
                .unwrap()
                .is_none()
        );
        assert!(c.card_revoke(&link.secret).unwrap());
        assert!(c.cards_shared(now).unwrap().is_empty());
        assert!(c.card_redeem(&[9; 16], now).unwrap().is_none(), "unknown");
    }

    #[test]
    fn a_request_waits_until_answered_and_a_contact_is_chosen_once() {
        let c = client();
        c.conversation_save(&crate::client::Conversation {
            group_id: vec![1],
            creator: false,
            peers: vec![],
        })
        .unwrap();
        assert_eq!(c.request(&[1]).unwrap(), None);
        c.request_open(&[1]).unwrap();
        c.request_set_from(&[1], &[7]).unwrap();
        c.request_set_from(&[1], &[8]).unwrap();
        c.request_set_card(&[1], &CardUse::Link { created_at: 5 }, Some("Ana"))
            .unwrap();
        let r = c.request(&[1]).unwrap().unwrap();
        assert_eq!(
            (r.status, r.from, r.card, r.name.as_deref()),
            (
                RequestStatus::Pending,
                Some(vec![7]),
                CardUse::Link { created_at: 5 },
                Some("Ana")
            )
        );
        assert_eq!(c.requests_pending().unwrap().len(), 1);
        c.request_resolve(&[1], false).unwrap();
        assert_eq!(
            c.request(&[1]).unwrap().unwrap().status,
            RequestStatus::Declined
        );
        assert!(c.requests_pending().unwrap().is_empty());
        c.request_resolve(&[1], true).unwrap();
        assert_eq!(c.request(&[1]).unwrap(), None);

        c.contact_seen(&[7], &[0xaa]).unwrap();
        assert!(!c.contact_is_accepted(&[7]).unwrap(), "met is not chosen");
        c.contact_accept(&[7]).unwrap();
        assert!(c.contact_is_accepted(&[7]).unwrap());
        c.contact_verified(&[7], VerifiedHow::InPerson, 9).unwrap();
        let contact = c.contact(&[7]).unwrap().unwrap();
        assert_eq!(contact.verified_how, Some(VerifiedHow::InPerson));
        c.card_name_set(Some("Luz")).unwrap();
        assert_eq!(c.card_name().unwrap().as_deref(), Some("Luz"));
    }
}
