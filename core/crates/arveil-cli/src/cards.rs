//! Contact cards and conversation requests (ADR-012 §4) on the command line.

use std::path::Path;

use arveil_app::{Application, CardUse};

use crate::carrier::CliError;
use crate::chat::{cli_error, render};

fn application(data_dir: &Path) -> Result<Application, CliError> {
    crate::commands::open_session(data_dir)
}

/// `arveil contact card --data-dir D [--in-person]`: a link to share, or a
/// code for someone in front of this screen (valid ten minutes, once).
pub fn card(data_dir: &Path, in_person: bool) -> Result<(), CliError> {
    let card = application(data_dir)?
        .offer_card(in_person)
        .map_err(cli_error)?;
    println!("card: {}", card.link);
    println!("secret: {}", hex::encode(&card.secret));
    println!("expires: {}", card.expires_at);
    Ok(())
}

/// `arveil contact card-close --data-dir D <secret>`: the code's screen
/// closed, or the shared link is revoked.
pub fn close(data_dir: &Path, secret: &str) -> Result<(), CliError> {
    let secret = hex::decode(secret).map_err(|e| CliError::Domain(format!("secret: {e}")))?;
    let result = application(data_dir)?
        .close_card(&secret)
        .map_err(cli_error)?;
    render(result);
    println!("closed: {}", hex::encode(secret));
    Ok(())
}

/// `arveil contact card-name --data-dir D <name>`: how cards introduce you.
pub fn name(data_dir: &Path, name: &str) -> Result<(), CliError> {
    let result = application(data_dir)?
        .set_card_name(Some(name))
        .map_err(cli_error)?;
    render(result);
    Ok(())
}

/// `arveil contact open --data-dir D <bootstrap> <card> [--scanned]`.
pub fn open(data_dir: &Path, bootstrap: &str, text: &str, scanned: bool) -> Result<(), CliError> {
    let app = application(data_dir)?;
    let preview = app.preview_card(text).map_err(cli_error)?;
    println!(
        "card: identity {} {}",
        hex::encode(&preview.identity_id),
        preview
            .name
            .as_deref()
            .map(|n| format!("says it is {n}"))
            .unwrap_or_default()
    );
    let result = app
        .start_from_card(bootstrap, text, scanned)
        .map_err(cli_error)?;
    render(result);
    Ok(())
}

/// `arveil chat requests --data-dir D`.
pub fn requests(data_dir: &Path) -> Result<(), CliError> {
    let mut any = false;
    for conversation in application(data_dir)?.conversations().map_err(cli_error)? {
        let Some(request) = conversation.request else {
            continue;
        };
        any = true;
        println!(
            "request {} from {} ({}){}",
            hex::encode(&conversation.group_id),
            request
                .from
                .as_deref()
                .map(hex::encode)
                .unwrap_or_else(|| "someone not named yet".into()),
            match request.card {
                CardUse::None => "did not use any of your links".to_string(),
                CardUse::Link { created_at } => format!("used your link from {created_at}"),
                CardUse::InPersonPending => "scanned your code; checking".into(),
                CardUse::InPerson => "scanned your code in person".into(),
            },
            request
                .name
                .map(|n| format!(", says it is {n}"))
                .unwrap_or_default()
        );
    }
    if !any {
        println!("requests: none");
    }
    Ok(())
}

/// `arveil chat accept|decline --data-dir D <group-prefix>`.
pub fn answer(data_dir: &Path, prefix: &str, accept: bool) -> Result<(), CliError> {
    let app = application(data_dir)?;
    let prefix = prefix.trim().to_ascii_lowercase();
    let matches: Vec<Vec<u8>> = app
        .conversations()
        .map_err(cli_error)?
        .into_iter()
        .filter(|c| c.request.is_some() && hex::encode(&c.group_id).starts_with(&prefix))
        .map(|c| c.group_id)
        .collect();
    let [group] = matches.as_slice() else {
        return Err(CliError::Domain(format!(
            "{} requests start with {prefix}",
            matches.len()
        )));
    };
    let result = app.answer_request(group, accept).map_err(cli_error)?;
    render(result);
    Ok(())
}
