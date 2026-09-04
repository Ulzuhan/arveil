//! Q1 for OpenMLS: `StorageProvider` over a shared `rusqlite::Connection`.
//!
//! Generated from `openmls_memory_storage` 0.6.0 (MIT): the 72 trait methods
//! are kept verbatim; only the storage struct and its six helpers changed,
//! from an in-memory map to a key-value table on a connection the
//! application controls. OpenMLS writes through this provider during every
//! operation, so whatever transaction is open on the connection captures
//! those writes together with the application's own rows.

use openmls_rust_crypto::RustCrypto;
use openmls_traits::OpenMlsProvider;
use openmls_traits::storage::*;
use rusqlite::{OptionalExtension, params};
use serde::Serialize;

use crate::mlsrs_sqlite::SharedConn;

const KV_SCHEMA: &str =
    "CREATE TABLE IF NOT EXISTS openmls_kv (key BLOB PRIMARY KEY, value BLOB NOT NULL)";

#[derive(Debug)]
pub struct SqliteStorage {
    conn: SharedConn,
}

impl SqliteStorage {
    pub fn new(conn: SharedConn) -> rusqlite::Result<Self> {
        conn.lock().execute_batch(KV_SCHEMA)?;
        Ok(Self { conn })
    }

    fn get_raw(&self, storage_key: &[u8]) -> Result<Option<Vec<u8>>, SqliteKvError> {
        Ok(self
            .conn
            .lock()
            .query_row(
                "SELECT value FROM openmls_kv WHERE key = ?1",
                params![storage_key],
                |r| r.get::<_, Vec<u8>>(0),
            )
            .optional()?)
    }

    fn put_raw(&self, storage_key: &[u8], value: &[u8]) -> Result<(), SqliteKvError> {
        self.conn.lock().execute(
            "INSERT INTO openmls_kv (key, value) VALUES (?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![storage_key, value],
        )?;
        Ok(())
    }

    fn delete_raw(&self, storage_key: &[u8]) -> Result<(), SqliteKvError> {
        self.conn.lock().execute(
            "DELETE FROM openmls_kv WHERE key = ?1",
            params![storage_key],
        )?;
        Ok(())
    }

    #[inline(always)]
    fn write<const VERSION: u16>(
        &self,
        label: &[u8],
        key: &[u8],
        value: Vec<u8>,
    ) -> Result<(), <Self as StorageProvider<CURRENT_VERSION>>::Error> {
        let storage_key = build_key_from_vec::<VERSION>(label, key.to_vec());
        self.put_raw(&storage_key, &value)
    }

    fn append<const VERSION: u16>(
        &self,
        label: &[u8],
        key: &[u8],
        value: Vec<u8>,
    ) -> Result<(), <Self as StorageProvider<CURRENT_VERSION>>::Error> {
        let storage_key = build_key_from_vec::<VERSION>(label, key.to_vec());
        let mut list: Vec<Vec<u8>> = match self.get_raw(&storage_key)? {
            Some(bytes) => serde_json::from_slice(&bytes)?,
            None => Vec::new(),
        };
        list.push(value);
        self.put_raw(&storage_key, &serde_json::to_vec(&list)?)
    }

    fn remove_item<const VERSION: u16>(
        &self,
        label: &[u8],
        key: &[u8],
        value: Vec<u8>,
    ) -> Result<(), <Self as StorageProvider<CURRENT_VERSION>>::Error> {
        let storage_key = build_key_from_vec::<VERSION>(label, key.to_vec());
        let mut list: Vec<Vec<u8>> = match self.get_raw(&storage_key)? {
            Some(bytes) => serde_json::from_slice(&bytes)?,
            None => Vec::new(),
        };
        if let Some(pos) = list.iter().position(|stored_item| stored_item == &value) {
            list.remove(pos);
        }
        self.put_raw(&storage_key, &serde_json::to_vec(&list)?)
    }

    #[inline(always)]
    fn read<const VERSION: u16, V: Entity<VERSION>>(
        &self,
        label: &[u8],
        key: &[u8],
    ) -> Result<Option<V>, <Self as StorageProvider<CURRENT_VERSION>>::Error> {
        let storage_key = build_key_from_vec::<VERSION>(label, key.to_vec());
        match self.get_raw(&storage_key)? {
            Some(value) => serde_json::from_slice(&value)
                .map_err(|_| SqliteKvError::SerializationError)
                .map(Some),
            None => Ok(None),
        }
    }

    #[inline(always)]
    fn read_list<const VERSION: u16, V: Entity<VERSION>>(
        &self,
        label: &[u8],
        key: &[u8],
    ) -> Result<Vec<V>, <Self as StorageProvider<CURRENT_VERSION>>::Error> {
        let storage_key = build_key_from_vec::<VERSION>(label, key.to_vec());
        let value: Vec<Vec<u8>> = match self.get_raw(&storage_key)? {
            Some(bytes) => serde_json::from_slice(&bytes)?,
            None => vec![],
        };
        value
            .iter()
            .map(|value_bytes| serde_json::from_slice(value_bytes))
            .collect::<Result<Vec<V>, _>>()
            .map_err(|_| SqliteKvError::SerializationError)
    }

    #[inline(always)]
    fn delete<const VERSION: u16>(
        &self,
        label: &[u8],
        key: &[u8],
    ) -> Result<(), <Self as StorageProvider<CURRENT_VERSION>>::Error> {
        let storage_key = build_key_from_vec::<VERSION>(label, key.to_vec());
        self.conn.lock().execute(
            "DELETE FROM openmls_kv WHERE key = ?1",
            params![storage_key],
        )?;
        Ok(())
    }

    pub fn count(&self) -> i64 {
        self.conn
            .lock()
            .query_row("SELECT COUNT(*) FROM openmls_kv", [], |r| r.get(0))
            .expect("count")
    }
}

/// `OpenMlsProvider` combining RustCrypto with the SQLite storage.
pub struct SqliteProvider {
    crypto: RustCrypto,
    storage: SqliteStorage,
}

impl SqliteProvider {
    pub fn new(storage: SqliteStorage) -> Self {
        Self {
            crypto: RustCrypto::default(),
            storage,
        }
    }
}

impl OpenMlsProvider for SqliteProvider {
    type CryptoProvider = RustCrypto;
    type RandProvider = RustCrypto;
    type StorageProvider = SqliteStorage;

    fn storage(&self) -> &Self::StorageProvider {
        &self.storage
    }

    fn crypto(&self) -> &Self::CryptoProvider {
        &self.crypto
    }

    fn rand(&self) -> &Self::RandProvider {
        &self.crypto
    }
}

/// Errors thrown by the key store.
#[derive(thiserror::Error, Debug, Copy, Clone, PartialEq, Eq)]
#[allow(dead_code)] // variants kept from the reference implementation
pub enum SqliteKvError {
    #[error("The key store does not allow storing serialized values.")]
    UnsupportedValueTypeBytes,
    #[error("Updating is not supported by this key store.")]
    UnsupportedMethod,
    #[error("Error serializing value.")]
    SerializationError,
    #[error("SQLite error.")]
    Database,
}

impl From<rusqlite::Error> for SqliteKvError {
    fn from(_: rusqlite::Error) -> Self {
        SqliteKvError::Database
    }
}

const KEY_PACKAGE_LABEL: &[u8] = b"KeyPackage";
const PSK_LABEL: &[u8] = b"Psk";
const ENCRYPTION_KEY_PAIR_LABEL: &[u8] = b"EncryptionKeyPair";
const SIGNATURE_KEY_PAIR_LABEL: &[u8] = b"SignatureKeyPair";
const EPOCH_KEY_PAIRS_LABEL: &[u8] = b"EpochKeyPairs";

// related to PublicGroup
const TREE_LABEL: &[u8] = b"Tree";
const GROUP_CONTEXT_LABEL: &[u8] = b"GroupContext";
#[cfg(feature = "extensions-draft")]
const APPLICATION_EXPORT_TREE_LABEL: &[u8] = b"ApplicationExportTree";
#[cfg(feature = "virtual-clients-draft")]
const VC_EMULATION_EPOCH_STATE_LABEL: &[u8] = b"VcEmulationEpochState";
#[cfg(feature = "virtual-clients-draft")]
const VC_EMULATION_BINDING_LABEL: &[u8] = b"VcEmulationBinding";
#[cfg(feature = "virtual-clients-draft")]
const REGISTERED_VC_EMULATION_EPOCH_LABEL: &[u8] = b"RegisteredVcEmulationEpoch";
#[cfg(feature = "virtual-clients-draft")]
const VC_OPERATION_TREE_LABEL: &[u8] = b"VcOperationTree";
#[cfg(feature = "virtual-clients-draft")]
const RETAINED_KEY_PACKAGE_MATERIAL_LABEL: &[u8] = b"RetainedKeyPackageMaterial";
#[cfg(feature = "virtual-clients-draft")]
const RETAINED_KEY_PACKAGE_EPOCH_LABEL: &[u8] = b"RetainedKeyPackageEpoch";
const INTERIM_TRANSCRIPT_HASH_LABEL: &[u8] = b"InterimTranscriptHash";
const CONFIRMATION_TAG_LABEL: &[u8] = b"ConfirmationTag";

// related to MlsGroup
const JOIN_CONFIG_LABEL: &[u8] = b"MlsGroupJoinConfig";
const OWN_LEAF_NODES_LABEL: &[u8] = b"OwnLeafNodes";
const GROUP_STATE_LABEL: &[u8] = b"GroupState";
const QUEUED_PROPOSAL_LABEL: &[u8] = b"QueuedProposal";
const PROPOSAL_QUEUE_REFS_LABEL: &[u8] = b"ProposalQueueRefs";
const OWN_LEAF_NODE_INDEX_LABEL: &[u8] = b"OwnLeafNodeIndex";
const EPOCH_SECRETS_LABEL: &[u8] = b"EpochSecrets";
const RESUMPTION_PSK_STORE_LABEL: &[u8] = b"ResumptionPsk";
const MESSAGE_SECRETS_LABEL: &[u8] = b"MessageSecrets";

impl StorageProvider<CURRENT_VERSION> for SqliteStorage {
    type Error = SqliteKvError;

    fn queue_proposal<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        ProposalRef: traits::ProposalRef<CURRENT_VERSION>,
        QueuedProposal: traits::QueuedProposal<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        proposal_ref: &ProposalRef,
        proposal: &QueuedProposal,
    ) -> Result<(), Self::Error> {
        // write proposal to key (group_id, proposal_ref)
        let key = serde_json::to_vec(&(group_id, proposal_ref))?;
        let value = serde_json::to_vec(proposal)?;
        self.write::<CURRENT_VERSION>(QUEUED_PROPOSAL_LABEL, &key, value)?;

        // update proposal list for group_id
        let key = serde_json::to_vec(group_id)?;
        let value = serde_json::to_vec(proposal_ref)?;
        self.append::<CURRENT_VERSION>(PROPOSAL_QUEUE_REFS_LABEL, &key, value)?;

        Ok(())
    }

    fn write_tree<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        TreeSync: traits::TreeSync<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        tree: &TreeSync,
    ) -> Result<(), Self::Error> {
        self.write::<CURRENT_VERSION>(
            TREE_LABEL,
            &serde_json::to_vec(&group_id).unwrap(),
            serde_json::to_vec(&tree).unwrap(),
        )
    }

    fn write_interim_transcript_hash<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        InterimTranscriptHash: traits::InterimTranscriptHash<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        interim_transcript_hash: &InterimTranscriptHash,
    ) -> Result<(), Self::Error> {
        let key = build_key::<CURRENT_VERSION, &GroupId>(INTERIM_TRANSCRIPT_HASH_LABEL, group_id);
        let value = serde_json::to_vec(&interim_transcript_hash).unwrap();

        self.put_raw(&key, &value)?;
        Ok(())
    }

    fn write_context<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        GroupContext: traits::GroupContext<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        group_context: &GroupContext,
    ) -> Result<(), Self::Error> {
        let key = build_key::<CURRENT_VERSION, &GroupId>(GROUP_CONTEXT_LABEL, group_id);
        let value = serde_json::to_vec(&group_context).unwrap();

        self.put_raw(&key, &value)?;
        Ok(())
    }

    fn write_confirmation_tag<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        ConfirmationTag: traits::ConfirmationTag<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        confirmation_tag: &ConfirmationTag,
    ) -> Result<(), Self::Error> {
        let key = build_key::<CURRENT_VERSION, &GroupId>(CONFIRMATION_TAG_LABEL, group_id);
        let value = serde_json::to_vec(&confirmation_tag).unwrap();

        self.put_raw(&key, &value)?;
        Ok(())
    }

    fn write_signature_key_pair<
        SignaturePublicKey: traits::SignaturePublicKey<CURRENT_VERSION>,
        SignatureKeyPair: traits::SignatureKeyPair<CURRENT_VERSION>,
    >(
        &self,
        public_key: &SignaturePublicKey,
        signature_key_pair: &SignatureKeyPair,
    ) -> Result<(), Self::Error> {
        let key =
            build_key::<CURRENT_VERSION, &SignaturePublicKey>(SIGNATURE_KEY_PAIR_LABEL, public_key);
        let value = serde_json::to_vec(&signature_key_pair).unwrap();

        self.put_raw(&key, &value)?;
        Ok(())
    }

    fn queued_proposal_refs<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        ProposalRef: traits::ProposalRef<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Vec<ProposalRef>, Self::Error> {
        self.read_list(PROPOSAL_QUEUE_REFS_LABEL, &serde_json::to_vec(group_id)?)
    }

    fn queued_proposals<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        ProposalRef: traits::ProposalRef<CURRENT_VERSION>,
        QueuedProposal: traits::QueuedProposal<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Vec<(ProposalRef, QueuedProposal)>, Self::Error> {
        let refs: Vec<ProposalRef> =
            self.read_list(PROPOSAL_QUEUE_REFS_LABEL, &serde_json::to_vec(group_id)?)?;

        refs.into_iter()
            .map(|proposal_ref| -> Result<_, _> {
                let key = (group_id, &proposal_ref);
                let key = serde_json::to_vec(&key)?;

                let proposal = self.read(QUEUED_PROPOSAL_LABEL, &key)?.unwrap();
                Ok((proposal_ref, proposal))
            })
            .collect::<Result<Vec<_>, _>>()
    }

    fn tree<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        TreeSync: traits::TreeSync<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<TreeSync>, Self::Error> {
        let key = build_key::<CURRENT_VERSION, &GroupId>(TREE_LABEL, group_id);

        let Some(value) = self.get_raw(&key)? else {
            return Ok(None);
        };
        let value = serde_json::from_slice(&value).unwrap();

        Ok(value)
    }

    fn group_context<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        GroupContext: traits::GroupContext<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<GroupContext>, Self::Error> {
        let key = build_key::<CURRENT_VERSION, &GroupId>(GROUP_CONTEXT_LABEL, group_id);

        let Some(value) = self.get_raw(&key)? else {
            return Ok(None);
        };
        let value = serde_json::from_slice(&value).unwrap();

        Ok(value)
    }

    fn interim_transcript_hash<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        InterimTranscriptHash: traits::InterimTranscriptHash<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<InterimTranscriptHash>, Self::Error> {
        let key = build_key::<CURRENT_VERSION, &GroupId>(INTERIM_TRANSCRIPT_HASH_LABEL, group_id);

        let Some(value) = self.get_raw(&key)? else {
            return Ok(None);
        };
        let value = serde_json::from_slice(&value).unwrap();

        Ok(value)
    }

    fn confirmation_tag<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        ConfirmationTag: traits::ConfirmationTag<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<ConfirmationTag>, Self::Error> {
        let key = build_key::<CURRENT_VERSION, &GroupId>(CONFIRMATION_TAG_LABEL, group_id);

        let Some(value) = self.get_raw(&key)? else {
            return Ok(None);
        };
        let value = serde_json::from_slice(&value).unwrap();

        Ok(value)
    }

    fn signature_key_pair<
        SignaturePublicKey: traits::SignaturePublicKey<CURRENT_VERSION>,
        SignatureKeyPair: traits::SignatureKeyPair<CURRENT_VERSION>,
    >(
        &self,
        public_key: &SignaturePublicKey,
    ) -> Result<Option<SignatureKeyPair>, Self::Error> {
        let key =
            build_key::<CURRENT_VERSION, &SignaturePublicKey>(SIGNATURE_KEY_PAIR_LABEL, public_key);

        let Some(value) = self.get_raw(&key)? else {
            return Ok(None);
        };
        let value = serde_json::from_slice(&value).unwrap();

        Ok(value)
    }

    fn write_key_package<
        HashReference: traits::HashReference<CURRENT_VERSION>,
        KeyPackage: traits::KeyPackage<CURRENT_VERSION>,
    >(
        &self,
        hash_ref: &HashReference,
        key_package: &KeyPackage,
    ) -> Result<(), Self::Error> {
        let key = serde_json::to_vec(&hash_ref).unwrap();
        let value = serde_json::to_vec(&key_package).unwrap();

        self.write::<CURRENT_VERSION>(KEY_PACKAGE_LABEL, &key, value)
            .unwrap();

        Ok(())
    }

    fn write_psk<
        PskId: traits::PskId<CURRENT_VERSION>,
        PskBundle: traits::PskBundle<CURRENT_VERSION>,
    >(
        &self,
        psk_id: &PskId,
        psk: &PskBundle,
    ) -> Result<(), Self::Error> {
        self.write::<CURRENT_VERSION>(
            PSK_LABEL,
            &serde_json::to_vec(&psk_id).unwrap(),
            serde_json::to_vec(&psk).unwrap(),
        )
    }

    fn write_encryption_key_pair<
        EncryptionKey: traits::EncryptionKey<CURRENT_VERSION>,
        HpkeKeyPair: traits::HpkeKeyPair<CURRENT_VERSION>,
    >(
        &self,
        public_key: &EncryptionKey,
        key_pair: &HpkeKeyPair,
    ) -> Result<(), Self::Error> {
        self.write::<CURRENT_VERSION>(
            ENCRYPTION_KEY_PAIR_LABEL,
            &serde_json::to_vec(public_key).unwrap(),
            serde_json::to_vec(key_pair).unwrap(),
        )
    }

    fn key_package<
        KeyPackageRef: traits::HashReference<CURRENT_VERSION>,
        KeyPackage: traits::KeyPackage<CURRENT_VERSION>,
    >(
        &self,
        hash_ref: &KeyPackageRef,
    ) -> Result<Option<KeyPackage>, Self::Error> {
        let key = serde_json::to_vec(&hash_ref).unwrap();
        self.read(KEY_PACKAGE_LABEL, &key)
    }

    fn psk<PskBundle: traits::PskBundle<CURRENT_VERSION>, PskId: traits::PskId<CURRENT_VERSION>>(
        &self,
        psk_id: &PskId,
    ) -> Result<Option<PskBundle>, Self::Error> {
        self.read(PSK_LABEL, &serde_json::to_vec(&psk_id).unwrap())
    }

    fn encryption_key_pair<
        HpkeKeyPair: traits::HpkeKeyPair<CURRENT_VERSION>,
        EncryptionKey: traits::EncryptionKey<CURRENT_VERSION>,
    >(
        &self,
        public_key: &EncryptionKey,
    ) -> Result<Option<HpkeKeyPair>, Self::Error> {
        self.read(
            ENCRYPTION_KEY_PAIR_LABEL,
            &serde_json::to_vec(public_key).unwrap(),
        )
    }

    fn delete_signature_key_pair<
        SignaturePublicKeuy: traits::SignaturePublicKey<CURRENT_VERSION>,
    >(
        &self,
        public_key: &SignaturePublicKeuy,
    ) -> Result<(), Self::Error> {
        self.delete::<CURRENT_VERSION>(
            SIGNATURE_KEY_PAIR_LABEL,
            &serde_json::to_vec(public_key).unwrap(),
        )
    }

    fn delete_encryption_key_pair<EncryptionKey: traits::EncryptionKey<CURRENT_VERSION>>(
        &self,
        public_key: &EncryptionKey,
    ) -> Result<(), Self::Error> {
        self.delete::<CURRENT_VERSION>(
            ENCRYPTION_KEY_PAIR_LABEL,
            &serde_json::to_vec(&public_key).unwrap(),
        )
    }

    fn delete_key_package<KeyPackageRef: traits::HashReference<CURRENT_VERSION>>(
        &self,
        hash_ref: &KeyPackageRef,
    ) -> Result<(), Self::Error> {
        #[cfg(feature = "virtual-clients-draft")]
        {
            let serialized_ref = serde_json::to_vec(&hash_ref)?;
            self.delete::<CURRENT_VERSION>(RETAINED_KEY_PACKAGE_MATERIAL_LABEL, &serialized_ref)?;
            self.delete::<CURRENT_VERSION>(RETAINED_KEY_PACKAGE_EPOCH_LABEL, &serialized_ref)?;
        }
        self.delete::<CURRENT_VERSION>(KEY_PACKAGE_LABEL, &serde_json::to_vec(&hash_ref)?)
    }

    fn delete_psk<PskKey: traits::PskId<CURRENT_VERSION>>(
        &self,
        psk_id: &PskKey,
    ) -> Result<(), Self::Error> {
        self.delete::<CURRENT_VERSION>(PSK_LABEL, &serde_json::to_vec(&psk_id)?)
    }

    fn group_state<
        GroupState: traits::GroupState<CURRENT_VERSION>,
        GroupId: traits::GroupId<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<GroupState>, Self::Error> {
        self.read(GROUP_STATE_LABEL, &serde_json::to_vec(&group_id)?)
    }

    fn write_group_state<
        GroupState: traits::GroupState<CURRENT_VERSION>,
        GroupId: traits::GroupId<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        group_state: &GroupState,
    ) -> Result<(), Self::Error> {
        self.write::<CURRENT_VERSION>(
            GROUP_STATE_LABEL,
            &serde_json::to_vec(group_id)?,
            serde_json::to_vec(group_state)?,
        )
    }

    fn delete_group_state<GroupId: traits::GroupId<CURRENT_VERSION>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.delete::<CURRENT_VERSION>(GROUP_STATE_LABEL, &serde_json::to_vec(group_id)?)
    }

    fn message_secrets<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        MessageSecrets: traits::MessageSecrets<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<MessageSecrets>, Self::Error> {
        self.read(MESSAGE_SECRETS_LABEL, &serde_json::to_vec(group_id)?)
    }

    fn write_message_secrets<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        MessageSecrets: traits::MessageSecrets<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        message_secrets: &MessageSecrets,
    ) -> Result<(), Self::Error> {
        self.write::<CURRENT_VERSION>(
            MESSAGE_SECRETS_LABEL,
            &serde_json::to_vec(group_id)?,
            serde_json::to_vec(message_secrets)?,
        )
    }

    fn delete_message_secrets<GroupId: traits::GroupId<CURRENT_VERSION>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.delete::<CURRENT_VERSION>(MESSAGE_SECRETS_LABEL, &serde_json::to_vec(group_id)?)
    }

    fn resumption_psk_store<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        ResumptionPskStore: traits::ResumptionPskStore<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<ResumptionPskStore>, Self::Error> {
        self.read(RESUMPTION_PSK_STORE_LABEL, &serde_json::to_vec(group_id)?)
    }

    fn write_resumption_psk_store<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        ResumptionPskStore: traits::ResumptionPskStore<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        resumption_psk_store: &ResumptionPskStore,
    ) -> Result<(), Self::Error> {
        self.write::<CURRENT_VERSION>(
            RESUMPTION_PSK_STORE_LABEL,
            &serde_json::to_vec(group_id)?,
            serde_json::to_vec(resumption_psk_store)?,
        )
    }

    fn delete_all_resumption_psk_secrets<GroupId: traits::GroupId<CURRENT_VERSION>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.delete::<CURRENT_VERSION>(RESUMPTION_PSK_STORE_LABEL, &serde_json::to_vec(group_id)?)
    }

    fn own_leaf_index<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        LeafNodeIndex: traits::LeafNodeIndex<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<LeafNodeIndex>, Self::Error> {
        self.read(OWN_LEAF_NODE_INDEX_LABEL, &serde_json::to_vec(group_id)?)
    }

    fn write_own_leaf_index<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        LeafNodeIndex: traits::LeafNodeIndex<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        own_leaf_index: &LeafNodeIndex,
    ) -> Result<(), Self::Error> {
        self.write::<CURRENT_VERSION>(
            OWN_LEAF_NODE_INDEX_LABEL,
            &serde_json::to_vec(group_id)?,
            serde_json::to_vec(own_leaf_index)?,
        )
    }

    fn delete_own_leaf_index<GroupId: traits::GroupId<CURRENT_VERSION>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.delete::<CURRENT_VERSION>(OWN_LEAF_NODE_INDEX_LABEL, &serde_json::to_vec(group_id)?)
    }

    fn group_epoch_secrets<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        GroupEpochSecrets: traits::GroupEpochSecrets<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<GroupEpochSecrets>, Self::Error> {
        self.read(EPOCH_SECRETS_LABEL, &serde_json::to_vec(group_id)?)
    }

    fn write_group_epoch_secrets<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        GroupEpochSecrets: traits::GroupEpochSecrets<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        group_epoch_secrets: &GroupEpochSecrets,
    ) -> Result<(), Self::Error> {
        self.write::<CURRENT_VERSION>(
            EPOCH_SECRETS_LABEL,
            &serde_json::to_vec(group_id)?,
            serde_json::to_vec(group_epoch_secrets)?,
        )
    }

    fn delete_group_epoch_secrets<GroupId: traits::GroupId<CURRENT_VERSION>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.delete::<CURRENT_VERSION>(EPOCH_SECRETS_LABEL, &serde_json::to_vec(group_id)?)
    }

    fn write_encryption_epoch_key_pairs<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        EpochKey: traits::EpochKey<CURRENT_VERSION>,
        HpkeKeyPair: traits::HpkeKeyPair<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        epoch: &EpochKey,
        leaf_index: u32,
        key_pairs: &[HpkeKeyPair],
    ) -> Result<(), Self::Error> {
        let key = epoch_key_pairs_id(group_id, epoch, leaf_index)?;
        let value = serde_json::to_vec(key_pairs)?;

        self.write::<CURRENT_VERSION>(EPOCH_KEY_PAIRS_LABEL, &key, value)
    }

    fn encryption_epoch_key_pairs<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        EpochKey: traits::EpochKey<CURRENT_VERSION>,
        HpkeKeyPair: traits::HpkeKeyPair<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        epoch: &EpochKey,
        leaf_index: u32,
    ) -> Result<Vec<HpkeKeyPair>, Self::Error> {
        let key = epoch_key_pairs_id(group_id, epoch, leaf_index)?;
        let storage_key = build_key_from_vec::<CURRENT_VERSION>(EPOCH_KEY_PAIRS_LABEL, key);
        match self.get_raw(&storage_key)? {
            Some(value) => {
                serde_json::from_slice(&value).map_err(|_| SqliteKvError::SerializationError)
            }
            None => Ok(vec![]),
        }
    }

    fn delete_encryption_epoch_key_pairs<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        EpochKey: traits::EpochKey<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        epoch: &EpochKey,
        leaf_index: u32,
    ) -> Result<(), Self::Error> {
        let key = epoch_key_pairs_id(group_id, epoch, leaf_index)?;
        self.delete::<CURRENT_VERSION>(EPOCH_KEY_PAIRS_LABEL, &key)
    }

    fn clear_proposal_queue<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        ProposalRef: traits::ProposalRef<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        // Get all proposal refs for this group.
        let proposal_refs: Vec<ProposalRef> =
            self.read_list(PROPOSAL_QUEUE_REFS_LABEL, &serde_json::to_vec(group_id)?)?;
        for proposal_ref in proposal_refs {
            // Delete all proposals.
            let key = serde_json::to_vec(&(group_id, proposal_ref))?;
            self.delete_raw(&key)?;
        }

        // Delete the proposal refs from the store.
        let key = build_key::<CURRENT_VERSION, &GroupId>(PROPOSAL_QUEUE_REFS_LABEL, group_id);
        self.delete_raw(&key)?;

        Ok(())
    }

    fn mls_group_join_config<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        MlsGroupJoinConfig: traits::MlsGroupJoinConfig<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<MlsGroupJoinConfig>, Self::Error> {
        self.read(JOIN_CONFIG_LABEL, &serde_json::to_vec(group_id).unwrap())
    }

    fn write_mls_join_config<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        MlsGroupJoinConfig: traits::MlsGroupJoinConfig<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        config: &MlsGroupJoinConfig,
    ) -> Result<(), Self::Error> {
        let key = serde_json::to_vec(group_id).unwrap();
        let value = serde_json::to_vec(config).unwrap();

        self.write::<CURRENT_VERSION>(JOIN_CONFIG_LABEL, &key, value)
    }

    fn own_leaf_nodes<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        LeafNode: traits::LeafNode<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Vec<LeafNode>, Self::Error> {
        self.read_list(OWN_LEAF_NODES_LABEL, &serde_json::to_vec(group_id).unwrap())
    }

    fn append_own_leaf_node<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        LeafNode: traits::LeafNode<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        leaf_node: &LeafNode,
    ) -> Result<(), Self::Error> {
        let key = serde_json::to_vec(group_id)?;
        let value = serde_json::to_vec(leaf_node)?;
        self.append::<CURRENT_VERSION>(OWN_LEAF_NODES_LABEL, &key, value)
    }

    fn delete_own_leaf_nodes<GroupId: traits::GroupId<CURRENT_VERSION>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.delete::<CURRENT_VERSION>(OWN_LEAF_NODES_LABEL, &serde_json::to_vec(group_id).unwrap())
    }

    fn delete_group_config<GroupId: traits::GroupId<CURRENT_VERSION>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.delete::<CURRENT_VERSION>(JOIN_CONFIG_LABEL, &serde_json::to_vec(group_id).unwrap())
    }

    fn delete_tree<GroupId: traits::GroupId<CURRENT_VERSION>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.delete::<CURRENT_VERSION>(TREE_LABEL, &serde_json::to_vec(group_id).unwrap())
    }

    fn delete_confirmation_tag<GroupId: traits::GroupId<CURRENT_VERSION>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.delete::<CURRENT_VERSION>(
            CONFIRMATION_TAG_LABEL,
            &serde_json::to_vec(group_id).unwrap(),
        )
    }

    fn delete_context<GroupId: traits::GroupId<CURRENT_VERSION>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.delete::<CURRENT_VERSION>(GROUP_CONTEXT_LABEL, &serde_json::to_vec(group_id).unwrap())
    }

    fn delete_interim_transcript_hash<GroupId: traits::GroupId<CURRENT_VERSION>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.delete::<CURRENT_VERSION>(
            INTERIM_TRANSCRIPT_HASH_LABEL,
            &serde_json::to_vec(group_id).unwrap(),
        )
    }

    fn remove_proposal<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        ProposalRef: traits::ProposalRef<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        proposal_ref: &ProposalRef,
    ) -> Result<(), Self::Error> {
        let key = serde_json::to_vec(group_id).unwrap();
        let value = serde_json::to_vec(proposal_ref).unwrap();

        self.remove_item::<CURRENT_VERSION>(PROPOSAL_QUEUE_REFS_LABEL, &key, value)?;

        let key = serde_json::to_vec(&(group_id, proposal_ref)).unwrap();
        self.delete::<CURRENT_VERSION>(QUEUED_PROPOSAL_LABEL, &key)
    }

    #[cfg(feature = "extensions-draft")]
    fn write_application_export_tree<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        ApplicationExportTree: traits::ApplicationExportTree<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        application_export_tree: &ApplicationExportTree,
    ) -> Result<(), Self::Error> {
        self.write::<CURRENT_VERSION>(
            APPLICATION_EXPORT_TREE_LABEL,
            &serde_json::to_vec(&group_id).unwrap(),
            serde_json::to_vec(&application_export_tree).unwrap(),
        )
    }

    #[cfg(feature = "extensions-draft")]
    fn application_export_tree<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        ApplicationExportTree: traits::ApplicationExportTree<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<ApplicationExportTree>, Self::Error> {
        let key = build_key::<CURRENT_VERSION, &GroupId>(APPLICATION_EXPORT_TREE_LABEL, group_id);

        let Some(value) = self.get_raw(&key)? else {
            return Ok(None);
        };
        let value = serde_json::from_slice(&value).unwrap();

        Ok(value)
    }

    #[cfg(feature = "extensions-draft")]
    fn delete_application_export_tree<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        ApplicationExportTree: traits::ApplicationExportTree<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.delete::<CURRENT_VERSION>(
            APPLICATION_EXPORT_TREE_LABEL,
            &serde_json::to_vec(group_id).unwrap(),
        )
    }

    #[cfg(feature = "virtual-clients-draft")]
    fn write_vc_emulation_epoch_state<
        EpochId: traits::VcEpochId<CURRENT_VERSION>,
        VcEmulationEpochState: traits::VcEmulationEpochState<CURRENT_VERSION>,
    >(
        &self,
        epoch_id: &EpochId,
        vc_emulation_epoch_state: &VcEmulationEpochState,
    ) -> Result<(), Self::Error> {
        self.write::<CURRENT_VERSION>(
            VC_EMULATION_EPOCH_STATE_LABEL,
            &serde_json::to_vec(epoch_id).unwrap(),
            serde_json::to_vec(vc_emulation_epoch_state).unwrap(),
        )
    }

    #[cfg(feature = "virtual-clients-draft")]
    fn vc_emulation_epoch_state<
        EpochId: traits::VcEpochId<CURRENT_VERSION>,
        VcEmulationEpochState: traits::VcEmulationEpochState<CURRENT_VERSION>,
    >(
        &self,
        epoch_id: &EpochId,
    ) -> Result<Option<VcEmulationEpochState>, Self::Error> {
        let key = build_key::<CURRENT_VERSION, &EpochId>(VC_EMULATION_EPOCH_STATE_LABEL, epoch_id);
        let Some(value) = self.get_raw(&key)? else {
            return Ok(None);
        };
        Ok(serde_json::from_slice(value).unwrap())
    }

    #[cfg(feature = "virtual-clients-draft")]
    fn delete_vc_emulation_state_if_unreferenced<EpochId: traits::VcEpochId<CURRENT_VERSION>>(
        &self,
        epoch_id: &EpochId,
    ) -> Result<bool, Self::Error> {
        let serialized_epoch_id = serde_json::to_vec(epoch_id)?;
        // Hold the write lock across the liveness check and the deletion so a
        // material stored concurrently cannot be orphaned.
        let referenced = values
            .iter()
            .any(|(key, value)| is_epoch_tag(key) && value == &serialized_epoch_id);
        if referenced {
            return Ok(false);
        }
        let state_key = build_key_from_vec::<CURRENT_VERSION>(
            VC_EMULATION_EPOCH_STATE_LABEL,
            serialized_epoch_id.clone(),
        );
        let tree_key =
            build_key_from_vec::<CURRENT_VERSION>(VC_OPERATION_TREE_LABEL, serialized_epoch_id);
        values.remove(&state_key);
        values.remove(&tree_key);
        Ok(true)
    }

    #[cfg(feature = "virtual-clients-draft")]
    fn write_vc_emulation_bindings<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        VcEmulationBindings: traits::VcEmulationBindings<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        bindings: &VcEmulationBindings,
    ) -> Result<(), Self::Error> {
        self.write::<CURRENT_VERSION>(
            VC_EMULATION_BINDING_LABEL,
            &serde_json::to_vec(group_id).unwrap(),
            serde_json::to_vec(bindings).unwrap(),
        )
    }

    #[cfg(feature = "virtual-clients-draft")]
    fn vc_emulation_bindings<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        VcEmulationBindings: traits::VcEmulationBindings<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<VcEmulationBindings>, Self::Error> {
        let key = build_key::<CURRENT_VERSION, &GroupId>(VC_EMULATION_BINDING_LABEL, group_id);
        let Some(value) = self.get_raw(&key)? else {
            return Ok(None);
        };
        Ok(serde_json::from_slice(value).unwrap())
    }

    #[cfg(feature = "virtual-clients-draft")]
    fn delete_vc_emulation_bindings<GroupId: traits::GroupId<CURRENT_VERSION>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.delete::<CURRENT_VERSION>(
            VC_EMULATION_BINDING_LABEL,
            &serde_json::to_vec(group_id).unwrap(),
        )
    }

    #[cfg(feature = "virtual-clients-draft")]
    fn write_registered_vc_emulation_epoch<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        RegisteredVcEmulationEpoch: traits::RegisteredVcEmulationEpoch<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        registered: &RegisteredVcEmulationEpoch,
    ) -> Result<(), Self::Error> {
        self.write::<CURRENT_VERSION>(
            REGISTERED_VC_EMULATION_EPOCH_LABEL,
            &serde_json::to_vec(group_id).unwrap(),
            serde_json::to_vec(registered).unwrap(),
        )
    }

    #[cfg(feature = "virtual-clients-draft")]
    fn registered_vc_emulation_epoch<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        RegisteredVcEmulationEpoch: traits::RegisteredVcEmulationEpoch<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<RegisteredVcEmulationEpoch>, Self::Error> {
        let key =
            build_key::<CURRENT_VERSION, &GroupId>(REGISTERED_VC_EMULATION_EPOCH_LABEL, group_id);
        let Some(value) = self.get_raw(&key)? else {
            return Ok(None);
        };
        Ok(serde_json::from_slice(value).unwrap())
    }

    #[cfg(feature = "virtual-clients-draft")]
    fn delete_registered_vc_emulation_epoch<GroupId: traits::GroupId<CURRENT_VERSION>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.delete::<CURRENT_VERSION>(
            REGISTERED_VC_EMULATION_EPOCH_LABEL,
            &serde_json::to_vec(group_id).unwrap(),
        )
    }

    #[cfg(feature = "virtual-clients-draft")]
    fn write_vc_operation_tree<
        EpochId: traits::VcEpochId<CURRENT_VERSION>,
        VcOperationTree: traits::VcOperationTree<CURRENT_VERSION>,
    >(
        &self,
        epoch_id: &EpochId,
        vc_operation_tree: &VcOperationTree,
    ) -> Result<(), Self::Error> {
        self.write::<CURRENT_VERSION>(
            VC_OPERATION_TREE_LABEL,
            &serde_json::to_vec(epoch_id).unwrap(),
            serde_json::to_vec(vc_operation_tree).unwrap(),
        )
    }

    #[cfg(feature = "virtual-clients-draft")]
    fn vc_operation_tree<
        EpochId: traits::VcEpochId<CURRENT_VERSION>,
        VcOperationTree: traits::VcOperationTree<CURRENT_VERSION>,
    >(
        &self,
        epoch_id: &EpochId,
    ) -> Result<Option<VcOperationTree>, Self::Error> {
        let key = build_key::<CURRENT_VERSION, &EpochId>(VC_OPERATION_TREE_LABEL, epoch_id);
        let Some(value) = self.get_raw(&key)? else {
            return Ok(None);
        };
        Ok(serde_json::from_slice(value).unwrap())
    }

    #[cfg(feature = "virtual-clients-draft")]
    fn write_retained_key_package_material_batch<
        EpochId: traits::VcEpochId<CURRENT_VERSION>,
        VcOperationTree: traits::VcOperationTree<CURRENT_VERSION>,
        KeyPackageRef: traits::HashReference<CURRENT_VERSION>,
        RetainedKeyPackageMaterial: traits::RetainedKeyPackageMaterial<CURRENT_VERSION>,
    >(
        &self,
        epoch_id: &EpochId,
        operation_tree: &VcOperationTree,
        materials: &[(KeyPackageRef, RetainedKeyPackageMaterial)],
    ) -> Result<(), Self::Error> {
        let serialized_epoch_id = serde_json::to_vec(epoch_id)?;
        // Take the write lock once so the advanced tree and all materials are
        // written together. A reader cannot observe an advanced tree without
        // the materials it produced.
        let tree_key = build_key_from_vec::<CURRENT_VERSION>(
            VC_OPERATION_TREE_LABEL,
            serialized_epoch_id.clone(),
        );
        values.insert(tree_key, serde_json::to_vec(operation_tree)?);
        for (hash_ref, record) in materials {
            let serialized_ref = serde_json::to_vec(hash_ref)?;
            let material_key = build_key_from_vec::<CURRENT_VERSION>(
                RETAINED_KEY_PACKAGE_MATERIAL_LABEL,
                serialized_ref.clone(),
            );
            values.insert(material_key, serde_json::to_vec(record)?);
            let epoch_tag_key = build_key_from_vec::<CURRENT_VERSION>(
                RETAINED_KEY_PACKAGE_EPOCH_LABEL,
                serialized_ref,
            );
            values.insert(epoch_tag_key, serialized_epoch_id.clone());
        }
        Ok(())
    }

    #[cfg(feature = "virtual-clients-draft")]
    fn retained_key_package_material<
        KeyPackageRef: traits::HashReference<CURRENT_VERSION>,
        RetainedKeyPackageMaterial: traits::RetainedKeyPackageMaterial<CURRENT_VERSION>,
    >(
        &self,
        hash_ref: &KeyPackageRef,
    ) -> Result<Option<RetainedKeyPackageMaterial>, Self::Error> {
        let key = build_key::<CURRENT_VERSION, &KeyPackageRef>(
            RETAINED_KEY_PACKAGE_MATERIAL_LABEL,
            hash_ref,
        );
        let Some(value) = self.get_raw(&key)? else {
            return Ok(None);
        };
        Ok(serde_json::from_slice(value).unwrap())
    }

    #[cfg(feature = "virtual-clients-draft")]
    fn has_retained_key_package_material_for_epoch<EpochId: traits::VcEpochId<CURRENT_VERSION>>(
        &self,
        epoch_id: &EpochId,
    ) -> Result<bool, Self::Error> {
        let serialized_epoch_id = serde_json::to_vec(epoch_id)?;
        let referenced = values
            .iter()
            .any(|(key, value)| is_epoch_tag(key) && value == &serialized_epoch_id);
        Ok(referenced)
    }

    #[cfg(feature = "virtual-clients-draft")]
    fn delete_retained_key_package_material<
        KeyPackageRef: traits::HashReference<CURRENT_VERSION>,
    >(
        &self,
        hash_ref: &KeyPackageRef,
    ) -> Result<(), Self::Error> {
        let serialized_ref = serde_json::to_vec(hash_ref)?;
        self.delete::<CURRENT_VERSION>(RETAINED_KEY_PACKAGE_MATERIAL_LABEL, &serialized_ref)?;
        self.delete::<CURRENT_VERSION>(RETAINED_KEY_PACKAGE_EPOCH_LABEL, &serialized_ref)
    }
}

/// Build a key with version and label.
fn build_key_from_vec<const V: u16>(label: &[u8], key: Vec<u8>) -> Vec<u8> {
    let mut key_out = label.to_vec();
    key_out.extend_from_slice(&key);
    key_out.extend_from_slice(&u16::to_be_bytes(V));
    key_out
}

/// Whether a storage key belongs to a retained-KeyPackage epoch tag entry.
#[cfg(feature = "virtual-clients-draft")]
fn is_epoch_tag(storage_key: &[u8]) -> bool {
    storage_key.starts_with(RETAINED_KEY_PACKAGE_EPOCH_LABEL)
}

/// Build a key with version and label.
fn build_key<const V: u16, K: Serialize>(label: &[u8], key: K) -> Vec<u8> {
    build_key_from_vec::<V>(label, serde_json::to_vec(&key).unwrap())
}

fn epoch_key_pairs_id(
    group_id: &impl traits::GroupId<CURRENT_VERSION>,
    epoch: &impl traits::EpochKey<CURRENT_VERSION>,
    leaf_index: u32,
) -> Result<Vec<u8>, <SqliteStorage as StorageProvider<CURRENT_VERSION>>::Error> {
    let mut key = serde_json::to_vec(group_id)?;
    key.extend_from_slice(&serde_json::to_vec(epoch)?);
    key.extend_from_slice(&serde_json::to_vec(&leaf_index)?);
    Ok(key)
}

impl From<serde_json::Error> for SqliteKvError {
    fn from(_: serde_json::Error) -> Self {
        Self::SerializationError
    }
}

// ---------------------------------------------------------------------------
// Q1 experiment
// ---------------------------------------------------------------------------

/// Counts of `(openmls_kv rows, outbox rows)` and whether the group loads,
/// after a rolled-back and after a committed unit of work.
pub struct OpenMlsQ1Outcome {
    pub kv_rows_before: i64,
    pub after_rollback: (i64, i64, bool),
    pub after_commit: (i64, i64, bool),
    pub loaded_epoch: Option<u64>,
}

/// Creator `a` runs on the SQLite provider. Inside one transaction the
/// application inserts an outbox row and asks OpenMLS to create a group and
/// add `b`; OpenMLS writes through the provider into the same transaction.
pub fn q1_shared_transaction() -> OpenMlsQ1Outcome {
    use crate::openmls_spike::Member;
    use openmls::prelude::*;
    use openmls_basic_credential::SignatureKeyPair;

    let ciphersuite = Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;
    let conn = SharedConn::open_in_memory().expect("sqlite");
    let provider = SqliteProvider::new(SqliteStorage::new(conn.clone()).expect("kv schema"));

    // Long-lived identity material, written outside the unit of work.
    let signer = SignatureKeyPair::new(ciphersuite.signature_algorithm()).expect("signer");
    signer.store(provider.storage()).expect("store signer");
    let credential = CredentialWithKey {
        credential: BasicCredential::new(b"sasha".to_vec()).into(),
        signature_key: signer.public().into(),
    };
    let b = Member::new("maxim");
    let kv_rows_before = provider.storage().count();

    let unit_of_work = |commit: bool| -> (i64, i64, bool, Option<u64>) {
        conn.lock().execute_batch("BEGIN").expect("begin");
        conn.lock()
            .execute(
                "INSERT INTO outbox (payload) VALUES (?1)",
                params![b"ciphertext-1"],
            )
            .expect("outbox insert");
        let mut group = MlsGroup::new(
            &provider,
            &signer,
            &MlsGroupCreateConfig::default(),
            credential.clone(),
        )
        .expect("create group");
        let b_kp = b.key_package();
        group
            .add_members(
                &provider,
                &signer,
                core::slice::from_ref(b_kp.key_package()),
            )
            .expect("add member");
        group.merge_pending_commit(&provider).expect("merge");
        let group_id = group.group_id().clone();
        drop(group);
        conn.lock()
            .execute_batch(if commit { "COMMIT" } else { "ROLLBACK" })
            .expect("end tx");

        let loaded = MlsGroup::load(provider.storage(), &group_id).expect("load");
        (
            provider.storage().count(),
            conn.count("outbox"),
            loaded.is_some(),
            loaded.map(|g| g.epoch().as_u64()),
        )
    };

    let (kv, outbox, loadable, _) = unit_of_work(false);
    let after_rollback = (kv, outbox, loadable);
    let (kv, outbox, loadable, epoch) = unit_of_work(true);
    OpenMlsQ1Outcome {
        kv_rows_before,
        after_rollback,
        after_commit: (kv, outbox, loadable),
        loaded_epoch: epoch,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Q1 for OpenMLS, answered: because OpenMLS writes through the provider
    /// during each operation, a provider bound to the application's own
    /// connection puts every write inside the application's transaction.
    /// https://github.com/Ulzuhan/arveil/issues/15
    #[test]
    fn q1_group_state_and_outbox_row_commit_or_roll_back_together() {
        let o = q1_shared_transaction();
        assert_eq!(
            o.after_rollback,
            (o.kv_rows_before, 0, false),
            "rollback leaves only the pre-existing signer row, no outbox row, no loadable group"
        );
        assert!(
            o.after_commit.0 > o.kv_rows_before,
            "commit persists the group's key-value rows"
        );
        assert_eq!(
            (o.after_commit.1, o.after_commit.2),
            (1, true),
            "commit persists the outbox row and the group is loadable"
        );
        assert_eq!(
            o.loaded_epoch,
            Some(1),
            "the loaded group is at epoch 1 after the Add"
        );
    }
}
