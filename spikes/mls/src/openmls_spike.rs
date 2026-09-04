//! OpenMLS 0.9 side of the M0.5 spike.
//!
//! Baseline: a two-member group and one application message.
//! Q2: a valid commit from an unauthorized member is inspected as a
//! `StagedCommit` and dropped before merge; the receiver's epoch is unchanged.
//! Q1: OpenMLS writes through `StorageProvider` during every operation; the
//! SQLite-backed provider and the shared-transaction test are in
//! `openmls_sqlite.rs`.

use openmls::prelude::tls_codec::{Deserialize, Serialize};
use openmls::prelude::*;
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::OpenMlsRustCrypto;

const CIPHERSUITE: Ciphersuite = Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;

/// One participant: provider (with in-memory storage), signer and credential.
pub struct Member {
    pub provider: OpenMlsRustCrypto,
    pub signer: SignatureKeyPair,
    pub credential: CredentialWithKey,
}

impl Member {
    pub fn new(name: &str) -> Self {
        let provider = OpenMlsRustCrypto::default();
        let signer =
            SignatureKeyPair::new(CIPHERSUITE.signature_algorithm()).expect("signature key pair");
        signer.store(provider.storage()).expect("store signer");
        let credential = CredentialWithKey {
            credential: BasicCredential::new(name.as_bytes().to_vec()).into(),
            signature_key: signer.public().into(),
        };
        Self {
            provider,
            signer,
            credential,
        }
    }

    pub fn key_package(&self) -> KeyPackageBundle {
        KeyPackage::builder()
            .build(
                CIPHERSUITE,
                &self.provider,
                &self.signer,
                self.credential.clone(),
            )
            .expect("key package")
    }
}

/// Round-trip an outgoing message through the wire format, as the relay would carry it.
fn wire(msg: &MlsMessageOut) -> ProtocolMessage {
    let bytes = msg.tls_serialize_detached().expect("serialize");
    MlsMessageIn::tls_deserialize(&mut bytes.as_slice())
        .expect("deserialize")
        .try_into_protocol_message()
        .expect("protocol message")
}

/// Creator `a` opens a group and adds `b`; returns both group handles.
pub fn two_member_group(a: &Member, b: &Member) -> (MlsGroup, MlsGroup) {
    let mut group_a = MlsGroup::new(
        &a.provider,
        &a.signer,
        &MlsGroupCreateConfig::default(),
        a.credential.clone(),
    )
    .expect("create group");

    let b_kp = b.key_package();
    let (_commit, welcome, _group_info) = group_a
        .add_members(
            &a.provider,
            &a.signer,
            core::slice::from_ref(b_kp.key_package()),
        )
        .expect("add member");
    group_a
        .merge_pending_commit(&a.provider)
        .expect("merge own commit");

    let welcome_bytes = welcome.tls_serialize_detached().expect("serialize welcome");
    let welcome = match MlsMessageIn::tls_deserialize(&mut welcome_bytes.as_slice())
        .expect("deserialize welcome")
        .extract()
    {
        MlsMessageBodyIn::Welcome(w) => w,
        other => panic!("expected welcome, got {other:?}"),
    };
    let group_b = StagedWelcome::new_from_welcome(
        &b.provider,
        &MlsGroupJoinConfig::default(),
        welcome,
        Some(group_a.export_ratchet_tree().into()),
    )
    .expect("staged welcome")
    .into_group(&b.provider)
    .expect("join group");

    (group_a, group_b)
}

/// Baseline: `a` sends one application message and `b` decrypts it.
pub fn baseline() -> (u64, Vec<u8>) {
    let a = Member::new("sasha");
    let b = Member::new("maxim");
    let (mut group_a, mut group_b) = two_member_group(&a, &b);

    let out = group_a
        .create_message(&a.provider, &a.signer, b"hello from openmls")
        .expect("create message");
    let processed = group_b
        .process_message(&b.provider, wire(&out))
        .expect("process message");
    let plaintext = match processed.into_content() {
        ProcessedMessageContent::ApplicationMessage(m) => m.into_bytes(),
        other => panic!("expected application message, got {other:?}"),
    };
    (group_b.epoch().as_u64(), plaintext)
}

/// Q2: only leaf 0 (the creator) may commit. `b` (leaf 1) produces a *valid*
/// commit adding a third member; `a` inspects it as a staged commit and drops
/// it. `a`'s epoch must not advance.
///
/// Returns `(sender_leaf, adds_in_commit, epoch_before, epoch_after)`.
pub fn q2_reject_unauthorized_commit() -> (u32, usize, u64, u64) {
    let a = Member::new("sasha");
    let b = Member::new("maxim");
    let c = Member::new("charlie");
    let (mut group_a, mut group_b) = two_member_group(&a, &b);

    let c_kp = c.key_package();
    let (commit, _welcome, _info) = group_b
        .add_members(
            &b.provider,
            &b.signer,
            core::slice::from_ref(c_kp.key_package()),
        )
        .expect("b commits an add");
    // b believes its commit will be accepted; that is b's problem, not a's.
    group_b.merge_pending_commit(&b.provider).expect("b merges");

    let epoch_before = group_a.epoch().as_u64();
    let processed = group_a
        .process_message(&a.provider, wire(&commit))
        .expect("a validates the commit cryptographically");

    let sender_leaf = match processed.sender() {
        Sender::Member(index) => index.u32(),
        other => panic!("expected member sender, got {other:?}"),
    };
    let staged = match processed.into_content() {
        ProcessedMessageContent::StagedCommitMessage(staged) => staged,
        other => panic!("expected staged commit, got {other:?}"),
    };
    let adds = staged.add_proposals().count();

    // Policy check happens here, with the full staged commit available.
    const AUTHORIZED_COMMITTER: u32 = 0;
    if sender_leaf == AUTHORIZED_COMMITTER {
        group_a
            .merge_staged_commit(&a.provider, *staged)
            .expect("merge authorized commit");
    } else {
        // Reject: simply do not merge. `staged` is dropped here.
        drop(staged);
    }

    (sender_leaf, adds, epoch_before, group_a.epoch().as_u64())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn baseline_two_members_exchange_a_message() {
        let (epoch, plaintext) = baseline();
        assert_eq!(epoch, 1, "one add commit moves the group to epoch 1");
        assert_eq!(plaintext, b"hello from openmls");
    }

    #[test]
    fn q2_unauthorized_commit_is_inspected_and_not_merged() {
        let (sender_leaf, adds, before, after) = q2_reject_unauthorized_commit();
        assert_eq!(sender_leaf, 1, "the commit came from the non-creator leaf");
        assert_eq!(
            adds, 1,
            "the staged commit exposes its Add proposal for inspection"
        );
        assert_eq!(
            before, after,
            "rejecting before merge leaves the epoch unchanged"
        );
    }

    // Q1 for OpenMLS is answered in `openmls_sqlite.rs`.
}
