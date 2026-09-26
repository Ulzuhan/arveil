//! Client-update signatures for the app (ADR-010). The app parses the signed
//! announcement; only the Ed25519 check crosses into Rust.

use flutter_rust_bridge::frb;

/// Whether `signature` is a valid Ed25519 signature by `public_key` over the
/// update domain separator followed by the exact `payload` bytes.
#[frb(sync)]
pub fn verify_update_signature(payload: Vec<u8>, signature: Vec<u8>, public_key: Vec<u8>) -> bool {
    arveil_app::updates::verify_update_signature(&payload, &signature, &public_key)
}

/// The domain separator signed ahead of the payload, for the app's tests and
/// the release tooling to check against.
#[frb(sync)]
pub fn update_signature_domain() -> String {
    String::from_utf8(arveil_app::updates::UPDATE_SIGNATURE_DOMAIN.to_vec())
        .expect("the domain is ASCII")
}
