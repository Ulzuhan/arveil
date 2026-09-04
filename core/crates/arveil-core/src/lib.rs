//! Arveil client core.
//!
//! This crate will hold the security authority of the client: identity and
//! device credentials, the MLS integration, the Noise channel to the relay,
//! encrypted local storage with transactional outbox/inbox, and recovery.
//!
//! Phase 0 status: skeleton only. See `docs/PHASE0.md` for the milestone plan
//! and `docs/ARCHITECTURE.md` for the boundaries this crate must respect:
//! the relay never links this crate, and the UI never decides whether a
//! signature, device or commit is valid.

pub mod attachments;
pub mod channel;
pub mod client;
pub mod delivery;
pub mod envelope;
pub mod identity;
pub mod mls;
#[cfg(feature = "recovery")]
pub mod recovery;
pub mod signed;
pub mod storage;

/// Wire protocol major version carried in every frame and in the Noise prologue.
///
/// `0` means "pre-release, no compatibility promise". It becomes `1` when the
/// gates in `docs/PROTOCOL.md` section 10 are met.
pub const PROTOCOL_VERSION: u16 = 0;

/// Human-readable version of the core, for diagnostics only.
pub fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn protocol_version_is_pre_release() {
        assert_eq!(PROTOCOL_VERSION, 0);
    }

    #[test]
    fn version_matches_manifest() {
        assert_eq!(version(), "0.0.1");
    }
}
