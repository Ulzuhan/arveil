//! Full Rust ↔ Go interoperability on a disposable local relay. Run with
//! ARVEIL_TEST_RELAY=<built binary> cargo test -p arveil-app --test invitations -- --ignored
use arveil_app::{
    Application, InvitationAction as A, InvitationOutput as O, InvitationView, ProfileConfig,
};
use std::{
    fs,
    io::Read,
    net::TcpListener,
    path::PathBuf,
    process::{Child, Command, Stdio},
    time::{Duration, Instant},
};

struct Fixture {
    path: PathBuf,
    binary: PathBuf,
    process: Option<Child>,
    port: u16,
    bootstrap: String,
}
impl Fixture {
    fn new() -> Self {
        let binary = PathBuf::from(
            std::env::var_os("ARVEIL_TEST_RELAY")
                .expect("build the Go relay and set ARVEIL_TEST_RELAY"),
        );
        assert!(binary.is_absolute());
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        drop(listener);
        let mut random = [0; 8];
        getrandom::fill(&mut random).unwrap();
        let path = std::env::temp_dir().join(format!("arveil-invitations-{}", hex::encode(random)));
        fs::create_dir(&path).unwrap();
        let mut f = Self {
            path,
            binary,
            process: None,
            port,
            bootstrap: String::new(),
        };
        f.start();
        f
    }
    fn start(&mut self) {
        let output = fs::File::create(self.path.join("relay.log")).unwrap();
        self.process = Some(
            Command::new(&self.binary)
                .arg("-data-dir")
                .arg(self.path.join("realm"))
                .arg("-listen")
                .arg(format!("127.0.0.1:{}", self.port))
                .stdout(output)
                .stderr(Stdio::null())
                .spawn()
                .unwrap(),
        );
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let mut text = String::new();
            fs::File::open(self.path.join("relay.log"))
                .unwrap()
                .read_to_string(&mut text)
                .unwrap();
            if let Some(line) = text.lines().find_map(|s| s.strip_prefix("bootstrap: ")) {
                self.bootstrap = line.to_string();
                break;
            }
            assert!(Instant::now() < deadline, "local relay startup timed out");
            assert!(
                self.process.as_mut().unwrap().try_wait().unwrap().is_none(),
                "local relay exited"
            );
            std::thread::sleep(Duration::from_millis(20));
        }
    }
    fn stop(&mut self) {
        if let Some(mut p) = self.process.take() {
            p.kill().unwrap();
            p.wait().unwrap();
        }
    }
    fn command(&self, command: &str, extra: &[&str]) -> String {
        let o = Command::new(&self.binary)
            .arg(command)
            .arg("-data-dir")
            .arg(self.path.join("realm"))
            .args(extra)
            .output()
            .unwrap();
        assert!(o.status.success(), "fixture command failed");
        String::from_utf8(o.stdout).unwrap()
    }
    fn profile(&self, name: &str) -> Application {
        Application::open(ProfileConfig::encrypted(self.path.join(name), "42".repeat(32)).unwrap())
            .unwrap()
    }
    fn enroll(&self, app: &Application) -> Vec<u8> {
        let result = self.command("invite", &["-qr", "never"]);
        let token = result
            .lines()
            .find_map(|s| s.strip_prefix("invite: "))
            .unwrap();
        app.enroll(&self.bootstrap, token)
            .unwrap()
            .value
            .identity_id
    }
    fn owner(&self) -> Application {
        let app = self.profile("owner");
        let id = self.enroll(&app);
        self.command("make-owner", &["-identity", &hex::encode(id)]);
        app.set_card_name(Some("Ana")).unwrap();
        app
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.stop();
        let _ = fs::remove_dir_all(&self.path);
    }
}
fn item(app: &Application, a: A) -> InvitationView {
    match app.invitations(a).unwrap() {
        O::Item(i) => i,
        _ => panic!("wrong output"),
    }
}

#[test]
#[ignore = "requires the disposable Go relay binary"]
fn new_person_installs_reopens_accepts_and_connects_with_offline_inviter() {
    let mut f = Fixture::new();
    let owner = f.owner();
    let issued = item(&owner, A::Create);
    let link = issued.link.clone().unwrap();
    assert!(link.contains("/join#"));
    let policy = owner.invitations(A::Policy).unwrap();
    assert!(matches!(policy,O::Policy(p) if p.can_invite));
    owner.close();
    drop(owner); // Issuer stays offline throughout admission and first send.
    f.stop();
    f.start(); // All relay receipts and policy survive an actual process restart.
    let guest = f.profile("guest");
    let accepted = item(
        &guest,
        A::Accept {
            text: Some(link.clone()),
            name: Some("Berta".into()),
        },
    );
    assert_eq!(accepted.state, "complete");
    assert!(!accepted.group_id.is_empty());
    assert_eq!(guest.contacts().unwrap().len(), 1);
    assert!(!guest.contacts().unwrap()[0].verified);
    assert!(guest.contacts().unwrap()[0].accepted);
    assert!(matches!(guest.invitations(A::Policy).unwrap(),O::Policy(p) if !p.can_invite));
    guest.close();
    drop(guest);
    let guest = f.profile("guest");
    let again = item(
        &guest,
        A::Accept {
            text: Some(link),
            name: None,
        },
    );
    assert_eq!(again.group_id, accepted.group_id);
    assert_eq!(guest.conversations().unwrap().len(), 1);
    let owner = f.profile("owner");
    owner.sync(&f.bootstrap).unwrap();
    assert_eq!(owner.contacts().unwrap().len(), 1);
    assert!(!owner.contacts().unwrap()[0].verified);
    assert!(owner.contacts().unwrap()[0].accepted);
    assert_eq!(owner.conversations().unwrap().len(), 1);
    assert!(owner.conversations().unwrap()[0].request.is_none());
    let O::Items(rows) = owner.invitations(A::List { refresh: true }).unwrap() else {
        panic!("list")
    };
    assert_eq!(rows[0].state, "connected");
    assert!(rows[0].link.is_none());
    assert_eq!(rows[0].group_id, accepted.group_id);
    guest.close();
    owner.close();
}

#[test]
#[ignore = "requires the disposable Go relay binary"]
fn rejected_invitation_can_be_replaced_and_existing_member_keeps_identity() {
    let f = Fixture::new();
    let owner = f.owner();
    let old = item(&owner, A::Create);
    let old_link = old.link.clone().unwrap();
    item(&owner, A::Revoke { id: old.id });
    let guest = f.profile("guest");
    assert!(
        guest
            .invitations(A::Accept {
                text: Some(old_link),
                name: None
            })
            .is_err()
    );
    assert!(
        matches!(guest.invitations(A::Pending).unwrap(), O::Pending(None)),
        "definitive rejection must not trap a profile"
    );
    let identity = guest.onboarding_status().unwrap().identity_id;
    let fresh = item(&owner, A::Create);
    item(
        &guest,
        A::Accept {
            text: fresh.link,
            name: None,
        },
    );
    assert_eq!(
        guest.onboarding_status().unwrap().identity_id,
        identity,
        "replace token, not identity"
    );
    let existing = f.profile("member");
    let id = f.enroll(&existing);
    let more = item(&owner, A::Create);
    let accepted = item(
        &existing,
        A::Accept {
            text: more.link.clone(),
            name: None,
        },
    );
    assert_eq!(existing.onboarding_status().unwrap().identity_id, Some(id));
    let replay = item(
        &existing,
        A::Accept {
            text: more.link,
            name: None,
        },
    );
    assert_eq!(replay.group_id, accepted.group_id);
    let O::Policy(policy) = existing.invitations(A::Policy).unwrap() else {
        panic!("policy")
    };
    assert!(!policy.can_invite);
    existing.close();
    guest.close();
    owner.close();
}

#[test]
#[ignore = "requires the disposable Go relay binary"]
fn network_failure_then_reopen_and_overlapping_retries_create_one_chat() {
    let mut f = Fixture::new();
    let owner = f.owner();
    let issued = item(&owner, A::Create);
    let link = issued.link.unwrap();
    owner.close();
    let guest = f.profile("guest");
    f.stop();
    assert!(
        guest
            .invitations(A::Accept {
                text: Some(link),
                name: None
            })
            .is_err()
    );
    assert!(matches!(
        guest.invitations(A::Pending).unwrap(),
        O::Pending(Some(_))
    ));
    guest.close();
    drop(guest);
    f.start();
    let guest = f.profile("guest");
    // This uses real concurrent application calls, not sequential button mocks.
    std::thread::scope(|s| {
        let calls: Vec<_> = (0..2)
            .map(|_| {
                s.spawn(|| {
                    guest.invitations(A::Accept {
                        text: None,
                        name: None,
                    })
                })
            })
            .collect();
        let mut successes = 0;
        for c in calls {
            if c.join().unwrap().is_ok() {
                successes += 1;
            }
        }
        assert!(successes >= 1);
    });
    assert_eq!(guest.conversations().unwrap().len(), 1);
    assert!(matches!(
        guest.invitations(A::Pending).unwrap(),
        O::Pending(None)
    ));
    guest.close();
}

#[test]
#[ignore = "requires the disposable Go relay binary"]
fn a_pruned_invitation_receipt_does_not_block_other_invitation_completion() {
    let mut f = Fixture::new();
    let owner = f.owner();
    let first = item(&owner, A::Create);
    let second = item(&owner, A::Create);
    owner.close();
    drop(owner);
    let mut completed = Vec::new();
    for (name, issued) in [("guest-one", first), ("guest-two", second)] {
        let guest = f.profile(name);
        let accepted = item(
            &guest,
            A::Accept {
                text: issued.link,
                name: None,
            },
        );
        assert_eq!(accepted.state, "complete");
        completed.push((accepted.group_id, issued.id));
        guest.close();
    }
    f.stop();
    // Candidates are visited in group-id order. Remove the first receipt so a
    // failed lookup must not prevent the second legitimate auto-acceptance.
    completed.sort();
    let db = rusqlite::Connection::open(f.path.join("realm/realm.db")).unwrap();
    db.execute(
        "DELETE FROM issued_invitations WHERE token_hash=?1",
        [&completed[0].1],
    )
    .unwrap();
    drop(db);
    f.start();
    let owner = f.profile("owner");
    owner.sync(&f.bootstrap).unwrap();
    owner.sync(&f.bootstrap).unwrap();
    let contacts = owner.contacts().unwrap();
    assert_eq!(contacts.iter().filter(|c| c.accepted).count(), 1);
    assert!(contacts.iter().all(|c| !c.verified));
    let conversations = owner.conversations().unwrap();
    assert_eq!(
        conversations.iter().filter(|c| c.request.is_some()).count(),
        1
    );
    owner.close();
}

#[test]
#[ignore = "requires the disposable Go relay binary"]
fn refreshing_after_offline_revocation_preserves_intent_and_hides_the_link() {
    let mut f = Fixture::new();
    let owner = f.owner();
    let issued = item(&owner, A::Create);
    f.stop();
    assert!(
        owner
            .invitations(A::Revoke {
                id: issued.id.clone()
            })
            .is_err()
    );
    owner.close();
    drop(owner);
    f.start();
    let owner = f.profile("owner");
    let O::Items(rows) = owner.invitations(A::List { refresh: true }).unwrap() else {
        panic!("list");
    };
    assert_eq!(rows[0].state, "revoke-pending");
    assert!(rows[0].link.is_none());
    let revoked = item(&owner, A::Revoke { id: issued.id });
    assert_eq!(revoked.state, "revoked");
    assert!(revoked.link.is_none());
    owner.close();
}

#[path = "support/invitation_failures.rs"]
mod failures;
