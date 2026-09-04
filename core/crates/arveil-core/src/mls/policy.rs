//! Group policy carried in the authenticated GroupContext and enforced by
//! every member before any commit changes state (`docs/PROTOCOL.md` §5).
//!
//! Phase 0 profile: a single authorized committer identified by leaf index.
//! The deterministic-successor rule under evaluation (REVIEW-v0.3 §3.1) will
//! extend this extension rather than replace the mechanism.

use mls_rs::MlsRules;
use mls_rs::group::{GroupContext, Roster};
use mls_rs::mls_rules::{
    CommitDirection, CommitOptions, CommitSource, DefaultMlsRules, EncryptionOptions,
    ProposalBundle,
};
use mls_rs_codec::{MlsDecode, MlsEncode, MlsSize};
use mls_rs_core::error::IntoAnyError;
use mls_rs_core::extension::{ExtensionType, MlsCodecExtension};

/// Private-use extension type (RFC 9420 §17.3 reserves 0xF000–0xFFFF).
pub const GROUP_POLICY_EXTENSION_TYPE: ExtensionType = ExtensionType::new(0xF000);

/// Authenticated group policy. Version 1: one authorized committer.
#[derive(Clone, Debug, PartialEq, Eq, MlsSize, MlsEncode, MlsDecode)]
pub struct GroupPolicy {
    pub version: u8,
    pub authorized_committer: u32,
}

impl GroupPolicy {
    pub const VERSION: u8 = 1;

    pub fn single_committer(leaf_index: u32) -> Self {
        Self {
            version: Self::VERSION,
            authorized_committer: leaf_index,
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
        "commit from leaf {committer} refused: only leaf {authorized} may commit ({direction:?})"
    )]
    UnauthorizedCommitter {
        committer: u32,
        authorized: u32,
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
#[derive(Clone, Debug, Default)]
pub struct PolicyRules {
    inner: DefaultMlsRules,
}

impl PolicyRules {
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
        let policy = Self::policy_of(current_context)?;
        match &source {
            CommitSource::ExistingMember(m) if m.index == policy.authorized_committer => {}
            CommitSource::ExistingMember(m) => {
                return Err(PolicyError::UnauthorizedCommitter {
                    committer: m.index,
                    authorized: policy.authorized_committer,
                    direction,
                });
            }
            CommitSource::NewMember(_) => return Err(PolicyError::ExternalCommit),
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
