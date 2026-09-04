//! The MLS engine: an mls-rs client bound to the core's SQLite connection,
//! with the Arveil group policy enforced on every commit.
//!
//! Phase 0 identity: a `BasicCredential` with a name. The device credential
//! binding of `docs/PROTOCOL.md` §5 replaces it in milestone M0.3.

use mls_rs::client_builder::MlsConfig;
use mls_rs::error::MlsError;
use mls_rs::identity::SigningIdentity;
use mls_rs::identity::basic::{BasicCredential, BasicIdentityProvider};
use mls_rs::{
    CipherSuite, CipherSuiteProvider, Client, CryptoProvider, ExtensionList, Group, MlsMessage,
};
use mls_rs_core::crypto::SignatureSecretKey;
use mls_rs_core::error::IntoAnyError;
use mls_rs_crypto_rustcrypto::RustCryptoProvider;

use super::policy::{GROUP_POLICY_EXTENSION_TYPE, GroupPolicy, PolicyRules};
use super::store::{SqliteGroupStore, SqliteKeyPackageStore, SqlitePskStore};
use crate::storage::SharedConn;

/// The mandatory-to-implement suite (RFC 9420 §17.1), the only one Arveil uses.
pub const CIPHERSUITE: CipherSuite = CipherSuite::CURVE25519_AES128;

/// Long-lived signing identity of this device for MLS leaves.
///
/// Phase 0 keeps it in memory; M0.3 stores it under the device credential.
#[derive(Clone)]
pub struct MlsIdentity {
    pub signing_identity: SigningIdentity,
    pub secret: SignatureSecretKey,
}

impl MlsIdentity {
    /// Rebuild from stored key bytes; `identity` is the BasicCredential
    /// identity (the device id in Arveil).
    pub fn from_parts(identity: &[u8], secret: &[u8], public: &[u8]) -> Self {
        let credential = BasicCredential::new(identity.to_vec()).into_credential();
        Self {
            signing_identity: SigningIdentity::new(credential, public.to_vec().into()),
            secret: secret.to_vec().into(),
        }
    }

    pub fn generate(name: &str) -> Result<Self, MlsError> {
        Self::generate_for(name.as_bytes())
    }

    /// Generate a signing key with an arbitrary BasicCredential identity.
    pub fn generate_for(identity: &[u8]) -> Result<Self, MlsError> {
        let suite = RustCryptoProvider::default()
            .cipher_suite_provider(CIPHERSUITE)
            .ok_or(MlsError::UnsupportedCipherSuite(CIPHERSUITE))?;
        let (secret, public) = suite
            .signature_key_generate()
            .map_err(|e| MlsError::CryptoProviderError(e.into_any_error()))?;
        let credential = BasicCredential::new(identity.to_vec()).into_credential();
        Ok(Self {
            signing_identity: SigningIdentity::new(credential, public),
            secret,
        })
    }
}

/// One mls-rs client over the shared connection.
pub struct Engine<C: MlsConfig> {
    client: Client<C>,
}

/// Build the engine. Returned as `impl MlsConfig` because the mls-rs config
/// type is a long builder chain; callers never name it.
pub fn open(conn: SharedConn, identity: MlsIdentity) -> Engine<impl MlsConfig> {
    let client = Client::builder()
        .identity_provider(BasicIdentityProvider)
        .crypto_provider(RustCryptoProvider::default())
        .mls_rules(PolicyRules::new(conn.clone()))
        .group_state_storage(SqliteGroupStore::new(conn.clone()))
        .key_package_repo(SqliteKeyPackageStore::new(conn.clone()))
        .psk_store(SqlitePskStore::new(conn))
        // Leaves advertise support for the policy extension so members can be
        // added to groups whose context carries it.
        .extension_type(GROUP_POLICY_EXTENSION_TYPE)
        .signing_identity(identity.signing_identity, identity.secret, CIPHERSUITE)
        .build();
    Engine { client }
}

impl<C: MlsConfig> Engine<C> {
    /// A fresh KeyPackage to publish on the relay. Its private material is
    /// stored in the key package table of the shared connection.
    pub fn key_package(&self) -> Result<MlsMessage, MlsError> {
        self.client
            .generate_key_package_message(Default::default(), Default::default(), None)
    }

    /// Create a group whose context carries the Arveil policy. This device
    /// is leaf 0 and therefore the first committer; the rule itself is
    /// "the lowest leaf that is not known to be revoked".
    pub fn create_group(&self) -> Result<Group<C>, MlsError> {
        let mut extensions = ExtensionList::new();
        extensions
            .set_from(GroupPolicy::lowest_active_leaf(0))
            .map_err(|e| MlsError::ExtensionError(e.into_any_error()))?;
        self.client
            .group_builder()?
            .with_group_context_extensions(extensions)
            .build()
    }

    /// Create a group *without* the policy extension. Only for tests that
    /// prove the rules fail closed.
    #[cfg(test)]
    pub(crate) fn create_group_without_policy(&self) -> Result<Group<C>, MlsError> {
        self.client.group_builder()?.build()
    }

    /// Join from a Welcome. The ratchet tree must be in the Welcome
    /// (mls-rs includes it by default) since the relay never serves trees.
    pub fn join(&self, welcome: &MlsMessage) -> Result<Group<C>, MlsError> {
        let (group, _info) = self.client.join_group(None, welcome, None)?;
        Ok(group)
    }

    /// Load a persisted group by id.
    pub fn load_group(&self, group_id: &[u8]) -> Result<Group<C>, MlsError> {
        self.client.load_group(group_id)
    }
}
