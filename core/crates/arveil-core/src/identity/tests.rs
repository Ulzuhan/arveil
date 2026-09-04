use super::*;

fn device() -> DevicePublicKeys {
    DeviceKeys::generate(vec![7u8; 32]).unwrap().public()
}

const NOW: u64 = 1_800_000_000;
const VALID: Validity = Validity {
    not_before: NOW - 10,
    not_after: NOW + 3600,
};

#[test]
fn credential_issued_by_root_verifies_and_binds_keys() {
    let root = RootKey::generate().unwrap();
    let dev = device();
    let signed = issue_credential(&root, &dev, VALID, USE_MLS_LEAF | USE_TRANSPORT).unwrap();

    let v = verify_credential(&signed, None, NOW).unwrap();
    assert_eq!(v.root, root.public());
    assert_eq!(v.credential.device_id, dev.device_id);
    assert_eq!(
        v.credential.transport_noise_public_key,
        dev.transport_noise_public_key
    );
    assert_eq!(v.credential.allowed_uses, USE_MLS_LEAF | USE_TRANSPORT);
    assert_eq!(v.hash, credential_hash(&signed));

    // Known contact with a different root: refused (I-02).
    let other = RootKey::generate().unwrap();
    assert!(matches!(
        verify_credential(&signed, Some(&other.public()), NOW),
        Err(IdentityError::RootMismatch)
    ));
    // Outside the validity window.
    assert!(matches!(
        verify_credential(&signed, None, NOW + 7200),
        Err(IdentityError::NotValidAt(_))
    ));
    // Tampered body: signature fails.
    let mut tampered = signed.clone();
    let i = tampered.len() / 2;
    tampered[i] ^= 0x01;
    assert!(verify_credential(&tampered, None, NOW).is_err());
}

#[test]
fn credential_signed_by_a_foreign_root_is_refused() {
    // Body claims root A but is signed by root B.
    let a = RootKey::generate().unwrap();
    let b = RootKey::generate().unwrap();
    let body = DeviceCredential {
        version: CREDENTIAL_VERSION,
        identity_root_public_key: a.public().as_bytes().to_vec(),
        device_id: vec![1; 16],
        mls_signature_public_key: vec![2; 32],
        transport_noise_public_key: vec![3; 32],
        envelope_hpke_public_key: vec![4; 32],
        validity: VALID,
        allowed_uses: USE_TRANSPORT,
    };
    let forged = crate::signed::sign_value(CREDENTIAL_CONTEXT, &body, &b.signing).unwrap();
    assert!(matches!(
        verify_credential(&forged, None, NOW),
        Err(IdentityError::Signed(SignedError::BadSignature))
    ));
}

#[test]
fn manifest_chain_sequence_and_conflicts() {
    let root = RootKey::generate().unwrap();
    let c1 = credential_hash(b"cred-1");
    let c2 = credential_hash(b"cred-2");

    let m1 = issue_manifest(&root, None, std::slice::from_ref(&c1), &[]).unwrap();
    let (body1, s1) = accept_manifest(&m1, &root.public(), None).unwrap();
    assert_eq!(body1.manifest_sequence, 1);
    assert!(body1.previous_manifest_hash.is_empty());

    let m2 = issue_manifest(&root, Some(&s1), &[c1.clone(), c2.clone()], &[]).unwrap();
    let (body2, s2) = accept_manifest(&m2, &root.public(), Some(&s1)).unwrap();
    assert_eq!(body2.manifest_sequence, 2);
    assert_eq!(body2.previous_manifest_hash, s1.hash);

    // Rollback refused.
    assert!(matches!(
        accept_manifest(&m1, &root.public(), Some(&s2)),
        Err(IdentityError::ManifestRollback { got: 1, known: 2 })
    ));
    // Same manifest again is idempotent.
    assert_eq!(
        accept_manifest(&m2, &root.public(), Some(&s2)).unwrap().1,
        s2
    );
    // A different manifest with the same sequence is a conflict (fork).
    let m2b = issue_manifest(
        &root,
        Some(&s1),
        std::slice::from_ref(&c2),
        std::slice::from_ref(&c1),
    )
    .unwrap();
    assert!(matches!(
        accept_manifest(&m2b, &root.public(), Some(&s2)),
        Err(IdentityError::ManifestConflict(2))
    ));
    // Chain broken: a sequence-3 manifest chained to s1's hash instead of s2's.
    let m3_body = DeviceManifest {
        version: MANIFEST_VERSION,
        identity_id: root.identity_id(),
        manifest_sequence: 3,
        previous_manifest_hash: s1.hash.clone(),
        active_credential_hashes: vec![],
        revoked_credential_hashes: vec![],
    };
    let m3 = crate::signed::sign_value(MANIFEST_CONTEXT, &m3_body, &root.signing).unwrap();
    assert!(matches!(
        accept_manifest(&m3, &root.public(), Some(&s2)),
        Err(IdentityError::ChainBroken)
    ));
    // Manifest for another identity signed by this root: refused.
    let other = RootKey::generate().unwrap();
    let foreign = issue_manifest(&other, None, &[], &[]).unwrap();
    assert!(accept_manifest(&foreign, &root.public(), None).is_err());
}

#[test]
fn identity_id_is_domain_separated_hash_of_root() {
    let root = RootKey::from_seed(&[9u8; 32]);
    let id = root.identity_id();
    assert_eq!(id.len(), 32);
    assert_ne!(id, sha2::Sha256::digest(root.public().as_bytes()).to_vec());
    assert_eq!(id, identity_id(&root.public()));
}
