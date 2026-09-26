//! Small application operations needed by the conversation screen.
use crate::{ProfileConfig, Route, carrier::CliError, enrolled, own_route, parse_route, session};
use arveil_core::client::safety_number;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RoutePreview {
    pub identity_id: Vec<u8>,
    pub device_id: Vec<u8>,
    pub safety_number: String,
}

/// A pasted route for a new conversation. `safety_number` is the number
/// the two people compared and saw match; without it the contact is saved
/// unverified, to be compared later.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ConversationRoute {
    pub route: String,
    pub safety_number: Option<String>,
}

pub(super) fn own(config: &ProfileConfig) -> Result<String, CliError> {
    let (session, _) = session(config)?;
    own_route(&session)
}

pub(super) fn checked_routes(values: &[String]) -> Result<Vec<Route>, CliError> {
    if values.is_empty() || values.len() > 16 {
        return Err(CliError::Domain(
            "choose between one and sixteen device routes".into(),
        ));
    }
    let mut devices = std::collections::HashSet::new();
    values
        .iter()
        .map(|value| {
            if value.len() > 4096 {
                return Err(CliError::Domain("route is too long".into()));
            }
            let route = parse_route(value)?;
            if route.device_id.len() != 16
                || route.credential_hash.len() != 32
                || route.mailbox_id.len() != 16
                || route.write_capability.len() != 32
                || route.hpke_public.len() != 32
                || !devices.insert(route.device_id.clone())
            {
                return Err(CliError::Domain("invalid or repeated device route".into()));
            }
            Ok(route)
        })
        .collect()
}

pub(super) fn preview(
    config: &ProfileConfig,
    values: &[String],
) -> Result<Vec<RoutePreview>, CliError> {
    let (client, device, _) = enrolled(config)?;
    let own = client
        .root_public()
        .map_err(crate::storage_error("identity"))?
        .ok_or_else(|| CliError::Domain("no identity".into()))?;
    checked_routes(values)?
        .into_iter()
        .map(|route| {
            if route.device_id == device.keys.device_id {
                return Err(CliError::Domain(
                    "cannot start a conversation with this device".into(),
                ));
            }
            Ok(RoutePreview {
                identity_id: route.identity_id,
                device_id: route.device_id,
                safety_number: safety_number(own.as_bytes(), &route.root_public),
            })
        })
        .collect()
}

/// Saves the identity behind each route as a contact before the
/// conversation starts. Only a route whose number was compared is pinned as
/// verified; the others stay unverified. A root that contradicts a verified
/// contact is refused either way.
pub(super) fn remember(
    config: &ProfileConfig,
    values: &[ConversationRoute],
) -> Result<Vec<String>, CliError> {
    let routes: Vec<String> = values.iter().map(|v| v.route.clone()).collect();
    let previews = preview(config, &routes)?;
    let digits = |s: &str| s.chars().filter(char::is_ascii_digit).collect::<String>();
    for (value, preview) in values.iter().zip(previews) {
        if let Some(number) = &value.safety_number
            && digits(number) != digits(&preview.safety_number)
        {
            return Err(CliError::Domain(
                "route comparison no longer matches".into(),
            ));
        }
    }
    let (client, _, _) = enrolled(config)?;
    client.unit_of_work(|| {
        for (route, value) in checked_routes(&routes)?.iter().zip(values) {
            client
                .contact_seen(&route.identity_id, &route.root_public)
                .map_err(crate::storage_error("contact"))?;
            if let Some(number) = &value.safety_number
                && !client
                    .contact_verify(&route.identity_id, number, crate::onboarding::now() as i64)
                    .map_err(crate::storage_error("contact"))?
            {
                return Err(CliError::Domain("contact comparison did not match".into()));
            }
            client
                .contact_route_save(&route.identity_id, &route.device_id, &value.route)
                .map_err(crate::storage_error("contact route"))?;
        }
        Ok::<_, CliError>(())
    })?;
    Ok(routes)
}
