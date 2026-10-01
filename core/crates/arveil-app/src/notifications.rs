//! A wake hint never carries message content and does not own a second profile.
use crate::{
    ProfileConfig,
    carrier::{Bootstrap, CliError},
};
use arveil_core::channel::codec::Payload;
use tokio_tungstenite::tungstenite::http::Uri;

fn valid_endpoint(endpoint: &str) -> bool {
    if endpoint.is_empty() {
        return true;
    }
    if endpoint.len() > 512 || !endpoint.is_ascii() || endpoint.contains('#') {
        return false;
    }
    let Ok(uri) = endpoint.parse::<Uri>() else {
        return false;
    };
    let Some(host) = uri.host() else {
        return false;
    };
    if uri.authority().is_none_or(|a| a.as_str().contains('@')) {
        return false;
    }
    uri.scheme_str() == Some("https")
        || (cfg!(debug_assertions) && uri.scheme_str() == Some("http") && host == "127.0.0.1")
}

pub async fn set(config: &ProfileConfig, endpoint: &str) -> Result<(), CliError> {
    if !valid_endpoint(endpoint) {
        return Err(CliError::Domain("Invalid notification endpoint".into()));
    }
    let (session, _) = crate::session(config)?;
    let bootstrap = Bootstrap {
        realm_id: session.realm.realm_id.clone(),
        signing_key: session.realm.signing_public,
        noise_public: session.realm.noise_public.clone(),
        url: session.realm.bootstrap_url.clone(),
    };
    let mut connection = crate::connect(config, &session, &bootstrap).await?;
    let result = connection
        .request(Payload::NotifyHintSet {
            url: endpoint.to_owned(),
        })
        .await;
    connection.close().await;
    match result? {
        Payload::Ack => Ok(()),
        _ => Err(CliError::Protocol(
            "Unexpected notification registration reply".into(),
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn bounded_https_capability_or_explicit_removal() {
        assert!(valid_endpoint(""));
        assert!(valid_endpoint("https://notify.example.org/up-test?up=1"));
        for url in [
            "ftp://example.org/x",
            "http://example.org/x",
            "https://u:p@example.org/x",
            "https://example.org/x#secret",
            "https://example.org/\nsecret",
            "relative",
        ] {
            assert!(!valid_endpoint(url));
        }
        assert!(!valid_endpoint(&format!(
            "https://example.org/{}",
            "x".repeat(513)
        )));
    }
}
