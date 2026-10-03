//! Fail actual SQLCipher writes at effect boundaries, then exit a child without
//! closing its Application. Only the test binary understands these controls:
//! production code and the relay have no fault-injection switches.
use super::*;
use arveil_core::storage::SharedConn;

fn profile_db(f: &Fixture, name: &str) -> SharedConn {
    SharedConn::open_file_keyed(&f.path.join(name).join("client.db"), Some(&"42".repeat(32)))
        .unwrap()
}
fn relay_db(f: &Fixture) -> rusqlite::Connection {
    rusqlite::Connection::open(f.path.join("realm/realm.db")).unwrap()
}
fn count(db: &rusqlite::Connection, table: &str) -> i64 {
    db.query_row(&format!("SELECT count(*) FROM {table}"), [], |r| r.get(0))
        .unwrap()
}
fn fault(f: &Fixture, name: &str, on: &str, when: &str) {
    profile_db(f, name).lock().execute_batch(&format!(
        "CREATE TRIGGER invitation_test_fault BEFORE {on} WHEN {when} BEGIN SELECT RAISE(ABORT,'injected invitation persistence fault'); END;"
    )).unwrap();
}
fn remove_fault(f: &Fixture, name: &str) {
    profile_db(f, name)
        .lock()
        .execute_batch("DROP TRIGGER invitation_test_fault")
        .unwrap();
}
fn restart(f: &mut Fixture) {
    f.stop();
    f.start();
}

/// A private child-process protocol; never prints the input, keys or profiles.
#[test]
fn invitation_fault_worker() {
    let Some(root) = std::env::var_os("ARVEIL_INVITATION_WORKER_ROOT") else {
        return;
    };
    let root = PathBuf::from(root);
    let name = std::env::var("ARVEIL_INVITATION_WORKER_PROFILE").unwrap();
    let app =
        Application::open(ProfileConfig::encrypted(root.join(name), "42".repeat(32)).unwrap())
            .unwrap();
    let mode = std::env::var("ARVEIL_INVITATION_WORKER_MODE").unwrap();
    let result = match mode.as_str() {
        "accept" => app.invitations(A::Accept {
            text: Some(fs::read_to_string(root.join("input")).unwrap()),
            name: Some("Guest".into()),
        }),
        "create" => app.invitations(A::Create),
        "revoke" => app.invitations(A::Revoke {
            id: fs::read(root.join("input")).unwrap(),
        }),
        "sync" => {
            // Sync deliberately leaves a failed auto-acceptance pending. The
            // parent checks that transaction before allowing another sync.
            app.sync(&fs::read_to_string(root.join("input")).unwrap())
                .unwrap();
            std::process::exit(85);
        }
        _ => panic!("unknown fixture mode"),
    };
    assert!(
        matches!(result, Err(arveil_app::ApplicationError::Storage { .. })),
        "injected storage fault did not interrupt the operation"
    );
    // No Application::close or Rust destructors. Reopen must recover the WAL
    // and OS profile lock, with all previous durable effects still present.
    std::process::exit(85);
}

fn interrupted(f: &Fixture, name: &str, mode: &str, input: &[u8]) {
    fs::write(f.path.join("input"), input).unwrap();
    let mut child = Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "failures::invitation_fault_worker",
            "--nocapture",
        ])
        .env("ARVEIL_INVITATION_WORKER_ROOT", &f.path)
        .env("ARVEIL_INVITATION_WORKER_PROFILE", name)
        .env("ARVEIL_INVITATION_WORKER_MODE", mode)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            assert_eq!(
                status.code(),
                Some(85),
                "fault worker did not reach its expected exit"
            );
            break;
        }
        if Instant::now() > deadline {
            child.kill().unwrap();
            child.wait().unwrap();
            panic!("fault worker timed out");
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
#[ignore = "requires the disposable Go relay binary"]
fn acceptance_recovers_across_every_persistence_boundary_after_process_exit() {
    let cases = [
        (
            "consent",
            "INSERT ON invitation_operations",
            "NEW.direction='incoming' AND NEW.state='accepting'",
        ),
        ("identity", "INSERT ON identity", "1"),
        ("device", "INSERT ON device", "1"),
        (
            "enrollment intent",
            "INSERT ON enrollment",
            "NEW.phase='redeeming'",
        ),
        (
            "redemption reply",
            "INSERT ON enrollment",
            "NEW.phase='redeemed'",
        ),
        ("endpoint confirmation", "UPDATE ON realm", "NEW.enrolled=1"),
        ("mailbox intent", "INSERT ON mailbox_request", "1"),
        ("mailbox reply", "INSERT ON mailbox_own", "1"),
        (
            "initial package batch",
            "INSERT ON initial_key_package_publication",
            "1",
        ),
        (
            "initial package reply",
            "UPDATE ON initial_key_package_publication",
            "NEW.batch IS NULL",
        ),
        (
            "enrollment completion",
            "INSERT ON enrollment",
            "NEW.phase='complete'",
        ),
        (
            "acceptance receipt",
            "INSERT ON invitation_operations",
            "NEW.state='enrolled'",
        ),
        (
            "claim intent",
            "INSERT ON invitation_operations",
            "NEW.state='enrolled' AND length(NEW.claim_key)>0",
        ),
        (
            "claim reply",
            "INSERT ON invitation_operations",
            "NEW.state='enrolled' AND length(NEW.key_package)>0",
        ),
        (
            "conversation transaction",
            "INSERT ON invitation_operations",
            "NEW.state='prepared'",
        ),
        (
            "before publication",
            "UPDATE ON outbox",
            "NEW.attempts>OLD.attempts",
        ),
        (
            "publication reply",
            "UPDATE ON outbox",
            "NEW.state='accepted'",
        ),
        (
            "completion transaction",
            "INSERT ON invitation_operations",
            "NEW.state='complete'",
        ),
    ];
    for (stage, on, when) in cases {
        let mut f = Fixture::new();
        let owner = f.owner();
        let issued = item(&owner, A::Create);
        let link = issued.link.unwrap();
        owner.close();
        drop(owner);
        let guest = f.profile("guest");
        guest.close();
        drop(guest);
        fault(&f, "guest", on, when);
        interrupted(&f, "guest", "accept", link.as_bytes());
        // Snapshot durable identity/group/encrypted envelopes before removing
        // the injected failure. Exact bytes must survive resumption unchanged.
        let (identity, group, outbox) = {
            let db = profile_db(&f, "guest");
            let c = db.lock();
            let identity = c
                .query_row("SELECT identity_id FROM identity", [], |r| {
                    r.get::<_, Vec<u8>>(0)
                })
                .ok();
            let group = c
                .query_row("SELECT group_id FROM conversations", [], |r| {
                    r.get::<_, Vec<u8>>(0)
                })
                .ok();
            let mut s = c
                .prepare("SELECT delivery_id,hpke_enc,ciphertext FROM outbox ORDER BY id")
                .unwrap();
            let outbox = s
                .query_map([], |r| {
                    Ok((
                        r.get::<_, Vec<u8>>(0)?,
                        r.get::<_, Vec<u8>>(1)?,
                        r.get::<_, Vec<u8>>(2)?,
                    ))
                })
                .unwrap()
                .collect::<Result<Vec<_>, _>>()
                .unwrap();
            if stage == "conversation transaction" {
                assert_eq!(count(&c, "conversations"), 0);
                assert_eq!(count(&c, "mls_group_state"), 0);
                assert!(outbox.is_empty());
            }
            (identity, group, outbox)
        };
        if stage == "claim reply" {
            assert_eq!(count(&relay_db(&f), "key_package_claim_receipts"), 1);
        }
        if stage == "publication reply" {
            assert_eq!(count(&relay_db(&f), "queued_envelopes"), 1);
            assert_eq!(outbox.len(), 3);
        }
        remove_fault(&f, "guest");
        restart(&mut f);
        let guest = f.profile("guest");
        let text = match guest.invitations(A::Pending).unwrap() {
            O::Pending(Some(_)) => None,
            O::Pending(None) => Some(link.clone()),
            _ => panic!("pending output"),
        };
        let done = item(&guest, A::Accept { text, name: None });
        assert_eq!(done.state, "complete", "{stage}");
        if let Some(identity) = identity {
            assert_eq!(
                guest.onboarding_status().unwrap().identity_id,
                Some(identity),
                "{stage}"
            );
        }
        if let Some(group) = group {
            assert_eq!(done.group_id, group, "{stage}");
        }
        assert_eq!(
            item(
                &guest,
                A::Accept {
                    text: Some(link),
                    name: None
                }
            )
            .group_id,
            done.group_id,
            "{stage}"
        );
        assert_eq!(guest.conversations().unwrap().len(), 1, "{stage}");
        guest.close();
        drop(guest);
        let db = profile_db(&f, "guest");
        let c = db.lock();
        for (delivery, enc, ciphertext) in outbox {
            let stored = c
                .query_row(
                    "SELECT hpke_enc,ciphertext FROM outbox WHERE delivery_id=?1",
                    [delivery],
                    |r| Ok((r.get::<_, Vec<u8>>(0)?, r.get::<_, Vec<u8>>(1)?)),
                )
                .unwrap();
            assert_eq!(stored, (enc, ciphertext), "{stage}");
        }
        assert_eq!(count(&c, "conversations"), 1, "{stage}");
        assert_eq!(count(&c, "outbox"), 3, "{stage}");
        drop(c);
        drop(db);
        let r = relay_db(&f);
        for (table, total) in [
            ("realm_memberships", 2),
            ("mailboxes", 2),
            ("key_package_claim_receipts", 1),
            ("queued_envelopes", 3),
        ] {
            assert_eq!(count(&r, table), total, "{stage}: {table}");
        }
        assert_eq!(
            r.query_row(
                "SELECT count(*) FROM key_packages WHERE consumed=1",
                [],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
            1,
            "{stage}"
        );
        drop(r);
        let owner = f.profile("owner");
        owner.sync(&f.bootstrap).unwrap();
        assert_eq!(owner.conversations().unwrap().len(), 1, "{stage}");
        assert!(
            owner.conversations().unwrap()[0].request.is_none(),
            "{stage}"
        );
        assert!(
            owner.contacts().unwrap()[0].accepted && !owner.contacts().unwrap()[0].verified,
            "{stage}"
        );
        owner.close();
        eprintln!("recovered: {stage}");
    }
}

#[test]
#[ignore = "requires the disposable Go relay binary"]
fn issuing_revoking_and_receiving_survive_unrecorded_replies() {
    for (stage, on, when) in [
        (
            "issue intent",
            "INSERT ON invitation_operations",
            "NEW.state='issuing'",
        ),
        (
            "issue reply",
            "INSERT ON invitation_operations",
            "NEW.state='pending'",
        ),
        (
            "revoke reply",
            "INSERT ON invitation_operations",
            "NEW.state='revoked'",
        ),
        (
            "receive transaction",
            "INSERT ON invitation_operations",
            "NEW.state='connected'",
        ),
    ] {
        let mut f = Fixture::new();
        let owner = f.owner();
        let issued = if matches!(stage, "revoke reply" | "receive transaction") {
            Some(item(&owner, A::Create))
        } else {
            None
        };
        owner.close();
        drop(owner);
        let (mode, input) = match &issued {
            Some(i) if stage == "revoke reply" => ("revoke", i.id.clone()),
            Some(i) => {
                let guest = f.profile("guest");
                item(
                    &guest,
                    A::Accept {
                        text: i.link.clone(),
                        name: None,
                    },
                );
                guest.close();
                ("sync", f.bootstrap.as_bytes().to_vec())
            }
            None => ("create", Vec::new()),
        };
        fault(&f, "owner", on, when);
        interrupted(&f, "owner", mode, &input);
        if stage == "receive transaction" {
            let db = profile_db(&f, "owner");
            let c = db.lock();
            assert_eq!(count(&c, "invitation_hellos"), 1);
            assert_eq!(
                c.query_row("SELECT count(*) FROM contacts WHERE accepted=1", [], |r| {
                    r.get::<_, i64>(0)
                })
                .unwrap(),
                0
            );
        }
        let old_expiry = relay_db(&f)
            .query_row("SELECT expires_at FROM issued_invitations", [], |r| {
                r.get::<_, i64>(0)
            })
            .ok();
        remove_fault(&f, "owner");
        restart(&mut f);
        let owner = f.profile("owner");
        match mode {
            "create" => {
                let done = item(&owner, A::Create);
                assert_eq!(done.state, "pending");
                assert!(done.link.is_some());
                if let Some(expiry) = old_expiry {
                    assert_eq!(done.expires_at, expiry);
                }
            }
            "revoke" => {
                let done = item(
                    &owner,
                    A::Revoke {
                        id: issued.unwrap().id,
                    },
                );
                assert_eq!(done.state, "revoked");
                assert!(done.link.is_none());
            }
            _ => {
                owner.sync(&f.bootstrap).unwrap();
                assert!(owner.conversations().unwrap()[0].request.is_none());
                assert_eq!(
                    owner
                        .contacts()
                        .unwrap()
                        .iter()
                        .filter(|c| c.accepted)
                        .count(),
                    1
                );
            }
        }
        assert_eq!(count(&relay_db(&f), "issued_invitations"), 1);
        owner.close();
        eprintln!("recovered: {stage}");
    }
}

#[test]
#[ignore = "requires the disposable Go relay binary"]
fn backup_restores_invitation_receipts_owner_policy_and_undelivered_chat() {
    let mut f = Fixture::new();
    let owner = f.owner();
    let used = item(&owner, A::Create);
    let pending = item(&owner, A::Create);
    let revoked = item(&owner, A::Create);
    let revoked_link = revoked.link.clone();
    item(
        &owner,
        A::Revoke {
            id: revoked.id.clone(),
        },
    );
    owner.close();
    drop(owner);
    let guest = f.profile("guest");
    let done = item(
        &guest,
        A::Accept {
            text: used.link.clone(),
            name: None,
        },
    );
    guest.close();
    drop(guest);
    let original_bootstrap = f.bootstrap.clone();
    let archive = f.path.join("backup.tar.gz");
    // Snapshot while the service is live and its three first-chat envelopes
    // have not yet been fetched by the emitting device.
    f.command("backup", &["-out", archive.to_str().unwrap()]);
    let refusal = Command::new(&f.binary)
        .arg("restore")
        .arg("-data-dir")
        .arg(f.path.join("realm"))
        .arg("-in")
        .arg(&archive)
        .output()
        .unwrap();
    assert!(
        !refusal.status.success(),
        "restore must never overwrite a realm"
    );
    // A client can have seen newer signed endpoints after this backup.
    restart(&mut f);
    restart(&mut f);
    let guest = f.profile("guest");
    guest.sync(&f.bootstrap).unwrap();
    guest.close();
    drop(guest);
    let sequence = fs::read(f.path.join("realm/server-secrets/endpoint-sequence")).unwrap();
    f.stop();
    fs::rename(f.path.join("realm"), f.path.join("realm-before-restore")).unwrap();
    f.command("restore", &["-in", archive.to_str().unwrap()]);
    f.start();
    let guest = f.profile("guest");
    // The existing pinned route still connects, but the signed list is refused.
    let refreshed = guest.sync(&f.bootstrap).unwrap();
    assert!(
        refreshed
            .changes
            .iter()
            .any(|c| matches!(c, arveil_app::StateChange::EndpointListRejected { .. }))
    );
    assert_eq!(
        profile_db(&f, "guest")
            .lock()
            .query_row("SELECT endpoint_sequence FROM realm", [], |r| r
                .get::<_, i64>(0))
            .unwrap(),
        3
    );
    guest.close();
    drop(guest);
    f.stop();
    // Operator procedure: retain the highest known counter for the SAME
    // signing identity before startup increments it. Never reset client pins.
    for name in ["realm-signing.key", "realm-noise.key"] {
        assert_eq!(
            fs::read(f.path.join("realm/server-secrets").join(name)).unwrap(),
            fs::read(
                f.path
                    .join("realm-before-restore/server-secrets")
                    .join(name)
            )
            .unwrap()
        );
    }
    fs::write(
        f.path.join("realm/server-secrets/endpoint-sequence"),
        sequence,
    )
    .unwrap();
    f.start();
    let guest = f.profile("guest");
    let refreshed = guest.sync(&f.bootstrap).unwrap();
    assert!(
        !refreshed
            .changes
            .iter()
            .any(|c| matches!(c, arveil_app::StateChange::EndpointListRejected { .. }))
    );
    assert_eq!(
        profile_db(&f, "guest")
            .lock()
            .query_row("SELECT endpoint_sequence FROM realm", [], |r| r
                .get::<_, i64>(0))
            .unwrap(),
        4
    );
    guest.close();
    drop(guest);
    assert_eq!(
        f.bootstrap, original_bootstrap,
        "server keys and URL changed"
    );
    assert_eq!(count(&relay_db(&f), "key_package_claim_receipts"), 1);
    assert_eq!(count(&relay_db(&f), "queued_envelopes"), 3);
    let owner = f.profile("owner");
    assert!(matches!(owner.invitations(A::Policy).unwrap(), O::Policy(p) if p.can_invite));
    let O::Items(rows) = owner.invitations(A::List { refresh: true }).unwrap() else {
        panic!("list");
    };
    for (id, state) in [
        (&used.id, "used"),
        (&pending.id, "pending"),
        (&revoked.id, "revoked"),
    ] {
        assert_eq!(rows.iter().find(|i| &i.id == id).unwrap().state, state);
    }
    owner.sync(&f.bootstrap).unwrap();
    assert_eq!(owner.conversations().unwrap().len(), 1);
    assert!(owner.conversations().unwrap()[0].request.is_none());
    assert!(owner.contacts().unwrap()[0].accepted && !owner.contacts().unwrap()[0].verified);
    let guest = f.profile("guest");
    assert_eq!(
        item(
            &guest,
            A::Accept {
                text: used.link,
                name: None
            }
        )
        .group_id,
        done.group_id
    );
    let next = f.profile("next");
    assert!(
        next.invitations(A::Accept {
            text: revoked_link,
            name: None
        })
        .is_err()
    );
    item(
        &next,
        A::Accept {
            text: pending.link,
            name: None,
        },
    );
    owner.sync(&f.bootstrap).unwrap();
    assert_eq!(owner.conversations().unwrap().len(), 2);
    assert!(
        owner
            .contacts()
            .unwrap()
            .iter()
            .all(|c| c.accepted && !c.verified)
    );
    for app in [&owner, &guest, &next] {
        app.close();
    }
}

#[test]
#[ignore = "requires the disposable Go relay binary"]
fn linked_owner_can_list_and_revoke_but_first_chat_belongs_to_emitting_device() {
    let f = Fixture::new();
    let owner = f.owner();
    let linked = f.profile("linked");
    let request = linked.create_link_request().unwrap().value.request;
    let grant = owner
        .authorize_link(&f.bootstrap, &request)
        .unwrap()
        .value
        .grant;
    linked.complete_link(&f.bootstrap, &grant).unwrap();
    assert_eq!(
        owner.onboarding_status().unwrap().identity_id,
        linked.onboarding_status().unwrap().identity_id
    );
    assert!(matches!(linked.invitations(A::Policy).unwrap(), O::Policy(p) if p.can_invite));
    let issued = item(&owner, A::Create);
    let other = item(&owner, A::Create);
    owner.close();
    drop(owner);
    let O::Items(rows) = linked.invitations(A::List { refresh: true }).unwrap() else {
        panic!("list");
    };
    assert_eq!(rows.len(), 2);
    assert!(
        rows.iter()
            .all(|i| i.link.is_none() && i.state == "pending")
    );
    assert_eq!(item(&linked, A::Revoke { id: other.id }).state, "revoked");
    let guest = f.profile("guest");
    let done = item(
        &guest,
        A::Accept {
            text: issued.link,
            name: None,
        },
    );
    linked.sync(&f.bootstrap).unwrap();
    assert!(linked.conversations().unwrap().is_empty());
    let O::Items(rows) = linked.invitations(A::List { refresh: true }).unwrap() else {
        panic!("list");
    };
    assert_eq!(
        rows.iter().find(|i| i.id == issued.id).unwrap().state,
        "used"
    );
    let owner = f.profile("owner");
    owner.sync(&f.bootstrap).unwrap();
    assert_eq!(owner.conversations().unwrap().len(), 1);
    assert_eq!(owner.conversations().unwrap()[0].group_id, done.group_id);
    assert!(owner.conversations().unwrap()[0].request.is_none());
    assert!(owner.contacts().unwrap()[0].accepted && !owner.contacts().unwrap()[0].verified);
    for app in [&owner, &linked, &guest] {
        app.close();
    }
}
