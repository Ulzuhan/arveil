//! Local address book. Aliases never authenticate an identity, and mailbox
//! capabilities remain in encrypted storage rather than UI list projections.
use crate::{ProfileConfig, carrier::CliError, conversation_ui, enrolled, storage_error};
use arveil_core::client::{Client, Contact};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ContactDevice {
    pub device_id: Vec<u8>,
    pub revoked: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ContactSummary {
    pub identity_id: Vec<u8>,
    pub name: Option<String>,
    pub label: String,
    pub verified: bool,
    pub verified_how: Option<arveil_core::client::VerifiedHow>,
    /// Chosen by this person, as opposed to only met in a group.
    pub accepted: bool,
    pub safety_number: String,
    pub devices: Vec<ContactDevice>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SavedRecipient {
    pub identity_id: Vec<u8>,
    pub device_id: Vec<u8>,
}

fn name(value: &str) -> Result<&str, CliError> {
    let value = value.trim();
    if value.chars().count() > 128 || value.chars().any(char::is_control) {
        return Err(CliError::Domain(
            "use a local name of at most 128 characters without control characters".into(),
        ));
    }
    Ok(value)
}

fn summary(client: &Client, contact: Contact) -> Result<ContactSummary, CliError> {
    let safety_number = client
        .safety_number_with(&contact.identity_id)
        .map_err(storage_error("contact"))?;
    let devices = client
        .contact_routes(&contact.identity_id)
        .map_err(storage_error("contact routes"))?
        .into_iter()
        .map(|(device_id, _)| {
            let revoked = client
                .device_revoked(&device_id)
                .map_err(storage_error("device"))?;
            Ok(ContactDevice { device_id, revoked })
        })
        .collect::<Result<_, CliError>>()?;
    Ok(ContactSummary {
        label: contact.label(),
        identity_id: contact.identity_id,
        name: contact.name,
        verified: contact.verified,
        verified_how: contact.verified_how,
        accepted: contact.accepted,
        safety_number,
        devices,
    })
}

fn get(client: &Client, identity: &[u8]) -> Result<ContactSummary, CliError> {
    let contact = client
        .contact(identity)
        .map_err(storage_error("contact"))?
        .ok_or_else(|| CliError::Domain("no such contact".into()))?;
    summary(client, contact)
}

pub(super) fn list(config: &ProfileConfig) -> Result<Vec<ContactSummary>, CliError> {
    let (client, _, _) = enrolled(config)?;
    let own = client.identity_id().map_err(storage_error("identity"))?;
    client
        .contacts()
        .map_err(storage_error("contacts"))?
        .into_iter()
        .filter(|c| Some(&c.identity_id) != own.as_ref())
        .map(|c| summary(&client, c))
        .collect()
}

pub(super) fn save(
    config: &ProfileConfig,
    value: &str,
    alias: &str,
    number: Option<&str>,
) -> Result<ContactSummary, CliError> {
    let alias = name(alias)?;
    let values = vec![value.trim().to_owned()];
    let previews = conversation_ui::preview(config, &values)?;
    let route = conversation_ui::checked_routes(&values)?.remove(0);
    let (client, _, _) = enrolled(config)?;
    let own = client.identity_id().map_err(storage_error("identity"))?;
    if Some(&route.identity_id) == own.as_ref() {
        return Err(CliError::Domain(
            "your own identity is not a contact".into(),
        ));
    }
    if let Some(number) = number {
        let digits = |s: &str| s.chars().filter(char::is_ascii_digit).collect::<String>();
        if digits(number) != digits(&previews[0].safety_number) {
            return Err(CliError::Domain(
                "contact comparison no longer matches".into(),
            ));
        }
    }
    client.unit_of_work(|| {
        client
            .contact_seen(&route.identity_id, &route.root_public)
            .map_err(storage_error("contact"))?;
        // Importing another device must not erase an existing local alias.
        // Explicit rename with an empty string is the way to clear it.
        if !alias.is_empty() {
            client
                .contact_rename(&route.identity_id, alias)
                .map_err(storage_error("contact"))?;
        }
        client
            .contact_route_save(&route.identity_id, &route.device_id, &values[0])
            .map_err(storage_error("contact route"))?;
        if let Some(number) = number
            && !client
                .contact_verify(&route.identity_id, number, crate::onboarding::now() as i64)
                .map_err(storage_error("contact"))?
        {
            return Err(CliError::Domain("contact comparison did not match".into()));
        }
        get(&client, &route.identity_id)
    })
}

pub(super) fn rename(
    config: &ProfileConfig,
    identity: &[u8],
    alias: &str,
) -> Result<ContactSummary, CliError> {
    let alias = name(alias)?;
    let (client, _, _) = enrolled(config)?;
    client.unit_of_work(|| {
        client
            .contact_rename(identity, alias)
            .map_err(storage_error("contact"))?;
        get(&client, identity)
    })
}

pub(super) fn verify(
    config: &ProfileConfig,
    identity: &[u8],
    number: &str,
) -> Result<ContactSummary, CliError> {
    let (client, _, _) = enrolled(config)?;
    client.unit_of_work(|| {
        // Someone met only in a conversation is known by the root its roster
        // named: comparing the number pins that root.
        if client
            .contact(identity)
            .map_err(storage_error("contact"))?
            .is_none()
            && let Some(root) = roster_root(&client, identity)?
        {
            client
                .contact_seen(identity, &root)
                .map_err(storage_error("contact"))?;
        }
        if !client
            .contact_verify(identity, number, crate::onboarding::now() as i64)
            .map_err(storage_error("contact"))?
        {
            return Err(CliError::Domain(
                "contact comparison no longer matches".into(),
            ));
        }
        get(&client, identity)
    })
}

/// The root a conversation roster gave another identity, if any.
fn roster_root(client: &Client, identity: &[u8]) -> Result<Option<Vec<u8>>, CliError> {
    let own = client.identity_id().map_err(storage_error("identity"))?;
    if own.as_deref() == Some(identity) {
        return Ok(None);
    }
    Ok(client
        .conversations()
        .map_err(storage_error("conversations"))?
        .into_iter()
        .flat_map(|c| c.peers)
        .find(|p| p.identity == identity && !p.root_public.is_empty())
        .map(|p| p.root_public))
}

/// Saved routes for a new conversation. Verification is not required: an
/// unverified contact can be talked to and compared with later.
pub(super) fn recipient_routes(
    config: &ProfileConfig,
    recipients: &[SavedRecipient],
) -> Result<Vec<String>, CliError> {
    if recipients.is_empty() || recipients.len() > 16 {
        return Err(CliError::Domain(
            "choose between one and sixteen saved devices".into(),
        ));
    }
    let (client, _, _) = enrolled(config)?;
    let mut values = Vec::new();
    for recipient in recipients {
        let contact = client
            .contact(&recipient.identity_id)
            .map_err(storage_error("contact"))?
            .ok_or_else(|| CliError::Domain("save the contact first".into()))?;
        if client
            .device_revoked(&recipient.device_id)
            .map_err(storage_error("device"))?
        {
            return Err(CliError::Domain("the saved device is revoked".into()));
        }
        let value = client
            .contact_routes(&recipient.identity_id)
            .map_err(storage_error("contact routes"))?
            .into_iter()
            .find(|(id, _)| id == &recipient.device_id)
            .map(|(_, value)| value)
            .ok_or_else(|| CliError::Domain("add a route for this device first".into()))?;
        let parsed = conversation_ui::checked_routes(std::slice::from_ref(&value))?.remove(0);
        if parsed.identity_id != contact.identity_id
            || parsed.root_public != contact.root_public
            || parsed.device_id != recipient.device_id
        {
            return Err(CliError::Domain(
                "saved route no longer matches contact".into(),
            ));
        }
        values.push(value);
    }
    // Includes duplicate-device and own-device checks even for API callers.
    conversation_ui::preview(config, &values)?;
    Ok(values)
}
