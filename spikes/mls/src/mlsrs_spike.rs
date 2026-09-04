//! mls-rs 0.56 side of the M0.5 spike.
//!
//! Baseline: a two-member group and one application message.
//! Q1 (partial): mls-rs persists explicitly. `load_group` fails before
//! `write_to_storage()` and succeeds after, which is the property that lets
//! the write sit inside our own transaction. The full answer needs a
//! `GroupStateStorage` implementation over the transaction's connection.
//! Q2: stub. mls-rs applies an incoming commit inside
//! `process_incoming_message`; enforcing a committer policy must go through
//! `MlsRules` (proposal filtering, commit options) or the identity provider,
//! and the spike has to prove a rejected commit leaves state untouched.

use mls_rs::client_builder::MlsConfig;
use mls_rs::error::MlsError;
use mls_rs::group::ReceivedMessage;
use mls_rs::identity::SigningIdentity;
use mls_rs::identity::basic::{BasicCredential, BasicIdentityProvider};
use mls_rs::{CipherSuite, CipherSuiteProvider, Client, CryptoProvider};
use mls_rs_crypto_rustcrypto::RustCryptoProvider;

const CIPHERSUITE: CipherSuite = CipherSuite::CURVE25519_AES128;

pub fn make_client(name: &str) -> Result<Client<impl MlsConfig>, MlsError> {
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
        .signing_identity(identity, secret, CIPHERSUITE)
        .build())
}

/// Baseline: alice creates a group, adds bob, sends one message.
/// Returns `(bob_epoch, plaintext)`.
pub fn baseline() -> Result<(u64, Vec<u8>), MlsError> {
    let alice = make_client("alice")?;
    let bob = make_client("bob")?;

    let mut alice_group = alice.group_builder()?.build()?;
    let bob_kp = bob.generate_key_package_message(Default::default(), Default::default(), None)?;
    let commit = alice_group.commit_builder().add_member(bob_kp)?.build()?;
    alice_group.apply_pending_commit()?;
    let (mut bob_group, _) = bob.join_group(None, &commit.welcome_messages[0], None)?;

    let msg = alice_group.encrypt_application_message(b"hello from mls-rs", Default::default())?;
    let plaintext = match bob_group.process_incoming_message(msg)? {
        ReceivedMessage::ApplicationMessage(m) => m.data().to_vec(),
        other => panic!("expected application message, got {other:?}"),
    };
    Ok((bob_group.current_epoch(), plaintext))
}

/// Explicit-write model: nothing reaches storage until `write_to_storage`.
/// Returns `(loadable_before_write, loadable_after_write)`.
pub fn explicit_write_model() -> Result<(bool, bool), MlsError> {
    let alice = make_client("alice")?;
    let mut group = alice.group_builder()?.build()?;
    let id = group.group_id().to_vec();

    let before = alice.load_group(&id).is_ok();
    group.write_to_storage()?;
    let after = alice.load_group(&id).is_ok();
    Ok((before, after))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn baseline_two_members_exchange_a_message() {
        let (epoch, plaintext) = baseline().expect("baseline");
        assert_eq!(epoch, 1, "one add commit moves the group to epoch 1");
        assert_eq!(plaintext, b"hello from mls-rs");
    }

    #[test]
    fn group_state_is_only_persisted_on_explicit_write() {
        let (before, after) = explicit_write_model().expect("explicit write");
        assert!(!before, "no storage write happens implicitly");
        assert!(after, "write_to_storage persists the group");
    }

    /// Q1 for mls-rs: implement `GroupStateStorage` (and the key package and
    /// PSK storage traits) over a `rusqlite::Connection` holding an open
    /// transaction; call `write_to_storage` plus an outbox insert inside it;
    /// roll back and assert both are absent; commit and assert both present.
    /// Tracked in https://github.com/Ulzuhan/arveil/issues/15
    #[test]
    #[ignore = "M0.5 Q1: SQLite-backed GroupStateStorage over our transaction not implemented yet"]
    fn q1_group_state_and_outbox_row_commit_or_roll_back_together() {
        unimplemented!("see issue #15");
    }

    /// Q2 for mls-rs: a valid commit from a non-authorized member must be
    /// rejected before it changes state. Candidate mechanisms: `MlsRules`
    /// (`filter_proposals` with `CommitSource`), or validating
    /// `CommitMessageDescription::committer` and discarding the group handle
    /// without `write_to_storage`. The test must show `current_epoch()` is
    /// unchanged on the persisted state after a rejected commit.
    /// Tracked in https://github.com/Ulzuhan/arveil/issues/16
    #[test]
    #[ignore = "M0.5 Q2: committer policy enforcement path not chosen yet"]
    fn q2_unauthorized_commit_is_rejected_before_state_change() {
        unimplemented!("see issue #16");
    }
}
