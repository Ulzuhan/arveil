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
pub mod pairing;
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

/// The commit a release was built from, from `ARVEIL_REVISION` at build
/// time, so a binary can be traced back to source (M3.5). `None` locally.
pub fn revision() -> Option<&'static str> {
    option_env!("ARVEIL_REVISION").filter(|r| !r.is_empty())
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

    /// An ordinary build claims no revision; releases inject one (M3.5).
    #[test]
    fn revision_is_absent_unless_a_release_sets_it() {
        match option_env!("ARVEIL_REVISION") {
            None | Some("") => assert_eq!(revision(), None),
            Some(r) => assert_eq!(revision(), Some(r)),
        }
    }
}
