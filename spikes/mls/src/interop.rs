//! Cross-implementation interop: a group created by `arveil-core` (mls-rs,
//! Arveil policy extension in the GroupContext) joined by an OpenMLS member.
//!
//! This is the conformance evidence for M0.5 step 4 (#18): two independent
//! RFC 9420 implementations agreeing on KeyPackage, Welcome, GroupContext
//! extension handling, application messages in both directions, and the
//! policy refusing a commit produced by the OpenMLS side.

use arveil_core::mls::{self, Engine, MlsIdentity};
use arveil_core::storage::SharedConn;
use mls_rs::client_builder::MlsConfig;
use mls_rs::group::ReceivedMessage;
use openmls::prelude::tls_codec::{Deserialize, Serialize};
use openmls::prelude::*;
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::OpenMlsRustCrypto;

const SUITE: Ciphersuite = Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;
const POLICY_EXT: ExtensionType = ExtensionType::Unknown(0xF000);

/// OpenMLS member whose leaf advertises support for the Arveil policy extension.
struct OpenMlsMember {
    provider: OpenMlsRustCrypto,
    signer: SignatureKeyPair,
    credential: CredentialWithKey,
}

impl OpenMlsMember {
    fn new(name: &str) -> Self {
        let provider = OpenMlsRustCrypto::default();
        let signer = SignatureKeyPair::new(SUITE.signature_algorithm()).expect("signer");
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

    /// KeyPackage on the wire, as the relay would hand it to the mls-rs side.
    fn key_package_bytes(&self) -> Vec<u8> {
        let capabilities = Capabilities::new(None, None, Some(&[POLICY_EXT]), None, None);
        let bundle = KeyPackage::builder()
            .leaf_node_capabilities(capabilities)
            .build(SUITE, &self.provider, &self.signer, self.credential.clone())
            .expect("key package");
        MlsMessageOut::from(bundle.key_package().clone())
            .tls_serialize_detached()
            .expect("serialize key package")
    }

    fn join(&self, welcome_bytes: &[u8]) -> MlsGroup {
        let welcome = match MlsMessageIn::tls_deserialize(&mut &welcome_bytes[..])
            .expect("deserialize welcome")
            .extract()
        {
            MlsMessageBodyIn::Welcome(w) => w,
            other => panic!("expected welcome, got {other:?}"),
        };
        StagedWelcome::new_from_welcome(
            &self.provider,
            &MlsGroupJoinConfig::default(),
            welcome,
            None, // ratchet tree travels inside the Welcome's GroupInfo
        )
        .expect("staged welcome")
        .into_group(&self.provider)
        .expect("join")
    }
}

fn openmls_protocol_message(bytes: &[u8]) -> ProtocolMessage {
    MlsMessageIn::tls_deserialize(&mut &bytes[..])
        .expect("deserialize")
        .try_into_protocol_message()
        .expect("protocol message")
}

pub struct InteropOutcome {
    pub openmls_read: Vec<u8>,
    pub mlsrs_read: Vec<u8>,
    pub openmls_epoch: u64,
    pub mlsrs_epoch: u64,
    pub policy_rejection: String,
}

fn arveil_peer(name: &str) -> Engine<impl MlsConfig> {
    let conn = SharedConn::open_in_memory().expect("sqlite");
    mls::open(conn, MlsIdentity::generate(name).expect("identity"))
}

pub fn run() -> InteropOutcome {
    // mls-rs side (arveil-core): alice creates the group with the policy.
    let alice = arveil_peer("alice");
    let mut g_alice = alice.create_group().expect("create group");

    // OpenMLS side: bob publishes a key package the mls-rs side consumes.
    let bob = OpenMlsMember::new("bob");
    let bob_kp = mls_rs::MlsMessage::from_bytes(&bob.key_package_bytes()).expect("parse kp");
    let commit = g_alice
        .commit_builder()
        .add_member(bob_kp)
        .expect("add")
        .build()
        .expect("commit");
    g_alice.apply_pending_commit().expect("apply");

    // bob joins from the Welcome produced by mls-rs.
    let welcome_bytes = commit.welcome_messages[0]
        .to_bytes()
        .expect("welcome bytes");
    let mut g_bob = bob.join(&welcome_bytes);

    // mls-rs -> OpenMLS
    let msg = g_alice
        .encrypt_application_message(b"from mls-rs", Default::default())
        .expect("encrypt");
    let processed = g_bob
        .process_message(
            &bob.provider,
            openmls_protocol_message(&msg.to_bytes().expect("bytes")),
        )
        .expect("openmls processes mls-rs message");
    let openmls_read = match processed.into_content() {
        ProcessedMessageContent::ApplicationMessage(m) => m.into_bytes(),
        other => panic!("expected application message, got {other:?}"),
    };

    // OpenMLS -> mls-rs
    let out = g_bob
        .create_message(&bob.provider, &bob.signer, b"from openmls")
        .expect("create message");
    let mlsrs_read = match g_alice
        .process_incoming_message(
            mls_rs::MlsMessage::from_bytes(&out.tls_serialize_detached().expect("ser"))
                .expect("parse"),
        )
        .expect("mls-rs processes openmls message")
    {
        ReceivedMessage::ApplicationMessage(m) => m.data().to_vec(),
        other => panic!("expected application message, got {other:?}"),
    };

    // OpenMLS bob (leaf 1) commits a self-update; the Arveil policy on the
    // mls-rs side must refuse it.
    let bundle = g_bob
        .self_update(&bob.provider, &bob.signer, LeafNodeParameters::default())
        .expect("openmls self update");
    let epoch_before = g_alice.current_epoch();
    let policy_rejection = g_alice
        .process_incoming_message(
            mls_rs::MlsMessage::from_bytes(&bundle.commit().tls_serialize_detached().expect("ser"))
                .expect("parse"),
        )
        .expect_err("policy must refuse a commit from leaf 1")
        .to_string();
    assert_eq!(g_alice.current_epoch(), epoch_before);

    InteropOutcome {
        openmls_read,
        mlsrs_read,
        openmls_epoch: g_bob.epoch().as_u64(),
        mlsrs_epoch: g_alice.current_epoch(),
        policy_rejection,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mlsrs_group_with_policy_interoperates_with_openmls_member() {
        let o = run();
        assert_eq!(o.openmls_read, b"from mls-rs");
        assert_eq!(o.mlsrs_read, b"from openmls");
        assert_eq!(o.openmls_epoch, 1);
        assert_eq!(o.mlsrs_epoch, 1);
        assert!(
            o.policy_rejection.contains("only the lowest active leaf may commit"),
            "got: {}",
            o.policy_rejection
        );
    }
}
