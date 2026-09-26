//! Signed client-update announcements (ADR-010, docs/CLIENT_UPDATES.md).
//!
//! The one Ed25519 check in the update path. The app parses the envelope and
//! the announced fields; whether the signature holds is decided here, with the
//! same Ed25519 implementation the rest of the core uses.

use ed25519_dalek::{Signature, VerifyingKey};

/// Signed ahead of the exact payload bytes, so an update signature can never
/// be mistaken for any other signature made with the same key.
pub const UPDATE_SIGNATURE_DOMAIN: &[u8] = b"arveil-client-updates-v1\n";

/// Whether `signature` is a valid Ed25519 signature by `public_key` over
/// [`UPDATE_SIGNATURE_DOMAIN`] followed by `payload`. Strict verification:
/// non-canonical signatures and small-order keys are refused. A key or a
/// signature of the wrong length is simply invalid.
pub fn verify_update_signature(payload: &[u8], signature: &[u8], public_key: &[u8]) -> bool {
    let (Ok(key), Ok(signature)) = (
        <&[u8; 32]>::try_from(public_key),
        <&[u8; 64]>::try_from(signature),
    ) else {
        return false;
    };
    let Ok(key) = VerifyingKey::from_bytes(key) else {
        return false;
    };
    let mut message = Vec::with_capacity(UPDATE_SIGNATURE_DOMAIN.len() + payload.len());
    message.extend_from_slice(UPDATE_SIGNATURE_DOMAIN);
    message.extend_from_slice(payload);
    key.verify_strict(&message, &Signature::from_bytes(signature))
        .is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::{Signer, SigningKey};

    // clients/flutter/test/fixtures/update-v1-openssl.json, signed with
    // OpenSSL 3, independently of this crate and of the Dart tests.
    const OPENSSL_KEY: &str = "7ff2290faf32ea77358f413053e6c30479fb0f966014c5eb28d664fc2f676490";
    const OPENSSL_SIGNATURE: &str = "e9d74d8464e75ac97a102e22c8bd9493de831e05b4f9c6feb54b070307ab85040cb2856408aa39a37923f4fb369bd7c1361131e45dc9ea6d40d0332f62804f06";
    const OPENSSL_PAYLOAD: &[u8] = br#"{"schema":1,"channel":"beta","sequence":7,"expires":"2035-01-01T00:00:00Z","platforms":{"android-arm64":{"version":"0.1.0","build":18,"minimum_sdk":24,"application_id":"io.github.ulzuhan.arveil","url":"https://github.com/example/arveil/releases/download/clients-v0.1.0-beta.1/app.apk","size":5,"sha256":"74f81fe167d99b4cb41d6d0ccda82278caee9f3e2f25d5e5a3936ff3dcec60d0","notes":"OpenSSL interoperability fixture.","notes_url":"https://example.org/releases/18"}}}"#;

    fn bytes(value: &str) -> Vec<u8> {
        hex::decode(value).unwrap()
    }

    fn signed(key: &SigningKey, payload: &[u8]) -> Vec<u8> {
        key.sign(&[UPDATE_SIGNATURE_DOMAIN, payload].concat())
            .to_bytes()
            .to_vec()
    }

    #[test]
    fn domain_matches_the_rules_shared_with_the_app_and_the_signer() {
        let vectors =
            include_str!("../../../../clients/flutter/test/fixtures/update-manifest-vectors.json");
        assert!(vectors.contains(r#""domain": "arveil-client-updates-v1\n""#));
        assert_eq!(UPDATE_SIGNATURE_DOMAIN, b"arveil-client-updates-v1\n");
    }

    #[test]
    fn accepts_the_independent_openssl_fixture() {
        assert!(verify_update_signature(
            OPENSSL_PAYLOAD,
            &bytes(OPENSSL_SIGNATURE),
            &bytes(OPENSSL_KEY),
        ));
    }

    #[test]
    fn refuses_any_change_to_payload_signature_or_key() {
        let key = bytes(OPENSSL_KEY);
        let signature = bytes(OPENSSL_SIGNATURE);
        let mut payload = OPENSSL_PAYLOAD.to_vec();
        payload[40] ^= 1;
        assert!(!verify_update_signature(&payload, &signature, &key));
        let mut tampered = signature.clone();
        tampered[10] ^= 1;
        assert!(!verify_update_signature(OPENSSL_PAYLOAD, &tampered, &key));
        let other = SigningKey::from_bytes(&[9; 32]).verifying_key().to_bytes();
        assert!(!verify_update_signature(
            OPENSSL_PAYLOAD,
            &signature,
            &other
        ));
    }

    #[test]
    fn refuses_wrong_lengths_and_a_signature_without_the_domain() {
        let key = SigningKey::from_bytes(&[3; 32]);
        let public = key.verifying_key().to_bytes();
        let payload = b"{\"schema\":1}";
        let good = signed(&key, payload);
        assert!(verify_update_signature(payload, &good, &public));
        assert!(!verify_update_signature(payload, &good[..63], &public));
        assert!(!verify_update_signature(payload, &good, &public[..31]));
        assert!(!verify_update_signature(payload, &[], &[]));
        // The same key signing the bare payload, as for another protocol.
        let bare = key.sign(payload).to_bytes();
        assert!(!verify_update_signature(payload, &bare, &public));
    }
}
