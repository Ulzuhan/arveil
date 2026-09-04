//! Q2 for mls-rs: enforce "only leaf N may commit" through `MlsRules`.
//!
//! mls-rs applies an incoming commit inside `process_incoming_message`, so
//! there is no staged-commit handle to inspect. The hook that runs *before*
//! the provisional state replaces the current one is
//! `MlsRules::filter_proposals`, which receives the commit's source
//! (`CommitSource::ExistingMember` with the committer's leaf index) for both
//! directions, sending and receiving. Returning an error there makes the
//! whole commit fail. The test checks that the failure leaves the epoch
//! unchanged and the group still usable.

use mls_rs::client_builder::MlsConfig;
use mls_rs::error::MlsError;
use mls_rs::group::{GroupContext, ReceivedMessage, Roster};
use mls_rs::identity::SigningIdentity;
use mls_rs::identity::basic::{BasicCredential, BasicIdentityProvider};
use mls_rs::mls_rules::{
    CommitDirection, CommitOptions, CommitSource, DefaultMlsRules, EncryptionOptions,
    ProposalBundle,
};
use mls_rs::{CipherSuite, CipherSuiteProvider, Client, CryptoProvider, MlsRules};
use mls_rs_core::error::IntoAnyError;
use mls_rs_crypto_rustcrypto::RustCryptoProvider;

use crate::mlsrs_spike::make_client;

const CIPHERSUITE: CipherSuite = CipherSuite::CURVE25519_AES128;

#[derive(Debug)]
pub struct PolicyError(pub String);

impl std::fmt::Display for PolicyError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for PolicyError {}

impl IntoAnyError for PolicyError {
    fn into_dyn_error(self) -> Result<Box<dyn std::error::Error + Send + Sync>, Self> {
        Ok(Box::new(self))
    }
}

/// Only `authorized_leaf` may produce commits; external commits are refused.
/// Everything else delegates to `DefaultMlsRules`.
#[derive(Clone, Debug)]
pub struct CommitterPolicy {
    pub authorized_leaf: u32,
    inner: DefaultMlsRules,
}

impl CommitterPolicy {
    pub fn new(authorized_leaf: u32) -> Self {
        Self {
            authorized_leaf,
            inner: DefaultMlsRules::default(),
        }
    }
}

#[cfg_attr(not(mls_build_async), maybe_async::must_be_sync)]
#[cfg_attr(mls_build_async, maybe_async::must_be_async)]
impl MlsRules for CommitterPolicy {
    type Error = PolicyError;

    async fn filter_proposals(
        &self,
        direction: CommitDirection,
        source: CommitSource,
        current_roster: &Roster,
        current_context: &GroupContext,
        proposals: ProposalBundle,
    ) -> Result<ProposalBundle, Self::Error> {
        match &source {
            CommitSource::ExistingMember(member) if member.index == self.authorized_leaf => {}
            CommitSource::ExistingMember(member) => {
                return Err(PolicyError(format!(
                    "commit from leaf {} refused: only leaf {} may commit ({direction:?})",
                    member.index, self.authorized_leaf
                )));
            }
            CommitSource::NewMember(_) => {
                return Err(PolicyError(
                    "external commits are not accepted in this profile".into(),
                ));
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

pub fn make_client_with_policy(
    name: &str,
    policy: CommitterPolicy,
) -> Result<Client<impl MlsConfig>, MlsError> {
    let crypto = RustCryptoProvider::default();
    let suite = crypto
        .cipher_suite_provider(CIPHERSUITE)
        .expect("cipher suite");
    let (secret, public) = suite.signature_key_generate().expect("signing key");
    let identity = SigningIdentity::new(
        BasicCredential::new(name.as_bytes().to_vec()).into_credential(),
        public,
    );
    Ok(Client::builder()
        .identity_provider(BasicIdentityProvider)
        .crypto_provider(crypto)
        .mls_rules(policy)
        .signing_identity(identity, secret, CIPHERSUITE)
        .build())
}

pub struct Q2Outcome {
    /// Error text from the rejected commit.
    pub rejection: String,
    pub epoch_before: u64,
    pub epoch_after: u64,
    /// Alice can still commit afterwards (state not corrupted by the failure).
    pub epoch_after_own_commit: u64,
    /// Bob, who ran without the policy, decrypts Alice's later message: the
    /// honest side never diverged from a state Bob can follow.
    pub bob_reads_later_message: bool,
}

/// Alice (leaf 0) enforces the policy. Bob (leaf 1) runs a client *without*
/// it, so he can produce a valid commit adding Charlie. Alice must refuse it.
pub fn q2_reject_unauthorized_commit() -> Result<Q2Outcome, MlsError> {
    let alice = make_client_with_policy("alice", CommitterPolicy::new(0))?;
    let bob = make_client("bob")?;
    let charlie = make_client("charlie")?;

    let mut alice_group = alice.group_builder()?.build()?;
    let bob_kp = bob.generate_key_package_message(Default::default(), Default::default(), None)?;
    let commit = alice_group.commit_builder().add_member(bob_kp)?.build()?;
    alice_group.apply_pending_commit()?;
    let (mut bob_group, _) = bob.join_group(None, &commit.welcome_messages[0], None)?;

    // Bob commits an Add for Charlie. Valid MLS, forbidden by policy.
    let charlie_kp =
        charlie.generate_key_package_message(Default::default(), Default::default(), None)?;
    let bob_commit = bob_group.commit_builder().add_member(charlie_kp)?.build()?;
    // Bob does NOT apply his own commit: he must wait for the group to accept
    // it, and in this profile it never will.

    let epoch_before = alice_group.current_epoch();
    let rejection = match alice_group.process_incoming_message(bob_commit.commit_message.clone()) {
        Ok(ReceivedMessage::Commit(desc)) => {
            panic!(
                "policy did not fire: commit from leaf {} applied",
                desc.committer
            )
        }
        Ok(other) => panic!("unexpected message kind: {other:?}"),
        Err(e) => e.to_string(),
    };
    let epoch_after = alice_group.current_epoch();

    // Alice's own commit still works and Bob can follow it.
    bob_group.clear_pending_commit();
    let own = alice_group.commit_builder().build()?;
    alice_group.apply_pending_commit()?;
    bob_group.process_incoming_message(own.commit_message)?;
    let epoch_after_own_commit = alice_group.current_epoch();

    let msg = alice_group.encrypt_application_message(b"still here", Default::default())?;
    let bob_reads_later_message = matches!(
        bob_group.process_incoming_message(msg)?,
        ReceivedMessage::ApplicationMessage(m) if m.data() == b"still here"
    );

    Ok(Q2Outcome {
        rejection,
        epoch_before,
        epoch_after,
        epoch_after_own_commit,
        bob_reads_later_message,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Q2 for mls-rs, answered via `MlsRules::filter_proposals`.
    /// https://github.com/Ulzuhan/arveil/issues/16
    #[test]
    fn q2_unauthorized_commit_is_rejected_before_state_change() {
        let o = q2_reject_unauthorized_commit().expect("q2");
        assert!(
            o.rejection.contains("only leaf 0 may commit"),
            "rejection must come from our policy, got: {}",
            o.rejection
        );
        assert_eq!(o.epoch_before, 1);
        assert_eq!(
            o.epoch_after, o.epoch_before,
            "a refused commit leaves the epoch unchanged"
        );
        assert_eq!(
            o.epoch_after_own_commit, 2,
            "the group is still usable by the authorized committer"
        );
        assert!(o.bob_reads_later_message);
    }
}
