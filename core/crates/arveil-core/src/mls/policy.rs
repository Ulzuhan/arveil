//! Group policy carried in the authenticated GroupContext and enforced by
//! every member before any commit changes state (`docs/PROTOCOL.md` §5).
//!
//! Phase 2 profile (version 2, REVIEW-v0.3 §3.1): the authorized committer
//! is the **lowest leaf that is not known to be revoked**. A device that
//! wants to displace the leaves below it must remove them in the same
//! commit, and every member checks independently that each of those leaves
//! was revoked by a manifest it verified under that identity's own root.
//! There is no election and no relay sequencing: the committer is a
//! function of state every member already validates.

use mls_rs::MlsRules;
use mls_rs::group::{GroupContext, Roster};
use mls_rs::mls_rules::{
    CommitDirection, CommitOptions, CommitSource, DefaultMlsRules, EncryptionOptions,
    ProposalBundle,
};
use mls_rs_codec::{MlsDecode, MlsEncode, MlsSize};
use mls_rs_core::error::IntoAnyError;
use mls_rs_core::extension::{ExtensionType, MlsCodecExtension};
use mls_rs_core::group::Member;

use crate::storage::SharedConn;

/// Private-use extension type (RFC 9420 §17.3 reserves 0xF000–0xFFFF).
pub const GROUP_POLICY_EXTENSION_TYPE: ExtensionType = ExtensionType::new(0xF000);

/// Authenticated group policy. Version 2: the lowest active leaf commits.
/// `creator_leaf` records who created the group; it is informational and
/// never overrides the rule.
#[derive(Clone, Debug, PartialEq, Eq, MlsSize, MlsEncode, MlsDecode)]
pub struct GroupPolicy {
    pub version: u8,
    pub creator_leaf: u32,
}

impl GroupPolicy {
    pub const VERSION: u8 = 2;

    pub fn lowest_active_leaf(creator_leaf: u32) -> Self {
        Self {
            version: Self::VERSION,
            creator_leaf,
        }
    }
}

impl MlsCodecExtension for GroupPolicy {
    fn extension_type() -> ExtensionType {
        GROUP_POLICY_EXTENSION_TYPE
    }
}

#[derive(Debug, thiserror::Error)]
pub enum PolicyError {
    #[error(
        "group context carries no Arveil policy extension; refusing to commit or accept commits"
    )]
    MissingPolicy,
    #[error("unsupported policy version {0}")]
    UnsupportedVersion(u8),
    #[error(
        "commit from leaf {committer} refused: leaf {blocking} is lower and not known to be revoked; only the lowest active leaf may commit ({direction:?})"
    )]
    UnauthorizedCommitter {
        committer: u32,
        blocking: u32,
        direction: CommitDirection,
    },
    #[error(
        "commit from leaf {committer} refused: it must also remove the revoked leaf {revoked} below it ({direction:?})"
    )]
    RevokedLeafNotRemoved {
        committer: u32,
        revoked: u32,
        direction: CommitDirection,
    },
    #[error("external commits are not accepted in this profile")]
    ExternalCommit,
    #[error("policy extension unreadable: {0}")]
    Extension(String),
}

impl IntoAnyError for PolicyError {
    fn into_dyn_error(self) -> Result<Box<dyn std::error::Error + Send + Sync>, Self> {
        Ok(Box::new(self))
    }
}

/// `MlsRules` that fail closed: no policy in the context means no commits.
///
/// The revocation state comes from this device's own store: a leaf counts as
/// revoked only once a manifest signed by its identity's root has been
/// verified and recorded ([`crate::client::Client::peer_manifest_accept`]).
/// Until then the member refuses the successor's commit and retries after
/// the next manifest refresh, rather than trusting the commit's own claim.
#[derive(Clone, Debug, Default)]
pub struct PolicyRules {
    inner: DefaultMlsRules,
    conn: Option<SharedConn>,
}

/// Is this device id recorded as revoked, as a peer or as one of our own
/// devices? A store without those tables (the MLS-only tests) answers no.
fn revoked(conn: &Option<SharedConn>, device_id: &[u8]) -> bool {
    let Some(conn) = conn else {
        return false;
    };
    let c = conn.lock();
    let peer: i64 = c
        .query_row(
            "SELECT COUNT(*) FROM peers WHERE device_id = ?1 AND revoked = 1",
            [device_id],
            |r| r.get(0),
        )
        .unwrap_or(0);
    let own: i64 = c
        .query_row(
            "SELECT COUNT(*) FROM identity_devices WHERE device_id = ?1 AND revoked = 1",
            [device_id],
            |r| r.get(0),
        )
        .unwrap_or(0);
    peer + own > 0
}

fn device_of(m: &Member) -> Vec<u8> {
    m.signing_identity
        .credential
        .as_basic()
        .map(|b| b.identifier.clone())
        .unwrap_or_default()
}

impl PolicyRules {
    /// Rules backed by this device's store, so revocations are known.
    pub fn new(conn: SharedConn) -> Self {
        Self {
            inner: DefaultMlsRules::default(),
            conn: Some(conn),
        }
    }

    fn policy_of(context: &GroupContext) -> Result<GroupPolicy, PolicyError> {
        let policy = context
            .extensions
            .get_as::<GroupPolicy>()
            .map_err(|e| PolicyError::Extension(e.to_string()))?
            .ok_or(PolicyError::MissingPolicy)?;
        if policy.version != GroupPolicy::VERSION {
            return Err(PolicyError::UnsupportedVersion(policy.version));
        }
        Ok(policy)
    }
}

#[cfg_attr(not(mls_build_async), maybe_async::must_be_sync)]
#[cfg_attr(mls_build_async, maybe_async::must_be_async)]
impl MlsRules for PolicyRules {
    type Error = PolicyError;

    async fn filter_proposals(
        &self,
        direction: CommitDirection,
        source: CommitSource,
        current_roster: &Roster,
        current_context: &GroupContext,
        proposals: ProposalBundle,
    ) -> Result<ProposalBundle, Self::Error> {
        let _policy = Self::policy_of(current_context)?;
        let committer = match &source {
            CommitSource::ExistingMember(m) => m.index,
            CommitSource::NewMember(_) => return Err(PolicyError::ExternalCommit),
        };
        // Every leaf below the committer must be revoked *and* removed by
        // this very commit. With no lower leaf, the committer is the lowest
        // active one and may commit freely.
        let removed: Vec<u32> = proposals
            .remove_proposals()
            .iter()
            .map(|p| p.proposal.to_remove())
            .collect();
        for member in current_roster
            .members_iter()
            .filter(|m| m.index < committer)
        {
            if !revoked(&self.conn, &device_of(&member)) {
                return Err(PolicyError::UnauthorizedCommitter {
                    committer,
                    blocking: member.index,
                    direction,
                });
            }
            if !removed.contains(&member.index) {
                return Err(PolicyError::RevokedLeafNotRemoved {
                    committer,
                    revoked: member.index,
                    direction,
                });
            }
        }
        Ok(self
            .inner
            .filter_proposals(
                direction,
                source,
                current_roster,
                current_context,
                proposals,
            )
            .await
            .unwrap_or_else(|never| match never {}))
    }

    fn commit_options(
        &self,
        new_roster: &Roster,
        new_context: &GroupContext,
        proposals: &ProposalBundle,
    ) -> Result<CommitOptions, Self::Error> {
        Ok(self
            .inner
            .commit_options(new_roster, new_context, proposals)
            .unwrap_or_else(|never| match never {}))
    }

    fn encryption_options(
        &self,
        current_roster: &Roster,
        current_context: &GroupContext,
    ) -> Result<EncryptionOptions, Self::Error> {
        Ok(self
            .inner
            .encryption_options(current_roster, current_context)
            .unwrap_or_else(|never| match never {}))
    }
}
