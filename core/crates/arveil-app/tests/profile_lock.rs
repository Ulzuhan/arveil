use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use arveil_app::{Application, ApplicationOpenError, ProfileConfig};

const PROFILE_ENV: &str = "ARVEIL_PROFILE_LOCK_TEST_PROFILE";
const RELEASE_FILE: &str = "release-owner";
const READY_FILE: &str = "owner-ready";

static NEXT_PROFILE: AtomicUsize = AtomicUsize::new(1);

fn test_profile(label: &str) -> PathBuf {
    std::env::temp_dir().join(format!(
        "arveil-profile-lock-{label}-{}-{}",
        std::process::id(),
        NEXT_PROFILE.fetch_add(1, Ordering::Relaxed)
    ))
}

struct OwnerProcess {
    child: Child,
    release: PathBuf,
    finished: bool,
}

impl OwnerProcess {
    fn spawn(profile: &Path) -> Self {
        let ready = profile.join(READY_FILE);
        let release = profile.join(RELEASE_FILE);
        let child = Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "helper_holds_profile", "--nocapture"])
            .env(PROFILE_ENV, profile)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .spawn()
            .unwrap();
        let mut owner = Self {
            child,
            release,
            finished: false,
        };
        let deadline = Instant::now() + Duration::from_secs(5);
        while !ready.exists() {
            if let Some(status) = owner.child.try_wait().unwrap() {
                panic!("profile owner exited before acquiring the lock: {status}");
            }
            assert!(
                Instant::now() < deadline,
                "profile owner did not become ready"
            );
            std::thread::sleep(Duration::from_millis(10));
        }
        owner
    }

    fn close(&mut self) {
        std::fs::write(&self.release, b"release").unwrap();
        let status = self.child.wait().unwrap();
        self.finished = true;
        assert!(status.success(), "profile owner failed: {status}");
    }

    fn crash(&mut self) {
        self.child.kill().unwrap();
        self.child.wait().unwrap();
        self.finished = true;
    }
}

impl Drop for OwnerProcess {
    fn drop(&mut self) {
        if !self.finished {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }
}

#[test]
fn helper_holds_profile() {
    let Ok(profile) = std::env::var(PROFILE_ENV) else {
        return;
    };
    let profile = PathBuf::from(profile);
    let _application = Application::open(ProfileConfig::unencrypted(&profile)).unwrap();
    std::fs::write(profile.join(READY_FILE), b"ready").unwrap();
    while !profile.join(RELEASE_FILE).exists() {
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn second_process_is_rejected_then_can_open_after_normal_close() {
    let profile = test_profile("normal-close");
    let mut owner = OwnerProcess::spawn(&profile);

    assert!(matches!(
        Application::open(ProfileConfig::unencrypted(&profile)),
        Err(ApplicationOpenError::ProfileInUse { path })
            if path == profile.canonicalize().unwrap()
    ));

    owner.close();
    let application = Application::open(ProfileConfig::unencrypted(&profile)).unwrap();
    drop(application);
    std::fs::remove_dir_all(profile).ok();
}

#[test]
fn profile_lock_is_released_after_owner_process_crashes() {
    let profile = test_profile("crash");
    let mut owner = OwnerProcess::spawn(&profile);
    owner.crash();

    let application = Application::open(ProfileConfig::unencrypted(&profile)).unwrap();
    drop(application);
    std::fs::remove_dir_all(profile).ok();
}

#[test]
fn different_profiles_can_be_open_in_different_processes() {
    let first_profile = test_profile("first");
    let second_profile = test_profile("second");
    let mut owner = OwnerProcess::spawn(&first_profile);

    let second = Application::open(ProfileConfig::unencrypted(&second_profile)).unwrap();
    assert!(matches!(
        Application::open(ProfileConfig::unencrypted(&first_profile)),
        Err(ApplicationOpenError::ProfileInUse { .. })
    ));

    drop(second);
    owner.close();
    std::fs::remove_dir_all(first_profile).ok();
    std::fs::remove_dir_all(second_profile).ok();
}

#[test]
#[cfg(unix)]
fn symbolic_paths_cannot_bypass_the_process_lock() {
    use std::os::unix::fs::symlink;

    let root = test_profile("symbolic");
    let profile = root.join("real");
    let symbolic = root.join("symbolic");
    std::fs::create_dir_all(&profile).unwrap();
    symlink(&profile, &symbolic).unwrap();
    let mut owner = OwnerProcess::spawn(&profile);

    assert!(matches!(
        Application::open(ProfileConfig::unencrypted(&symbolic)),
        Err(ApplicationOpenError::ProfileInUse { path })
            if path == profile.canonicalize().unwrap()
    ));

    owner.close();
    let reopened = Application::open(ProfileConfig::unencrypted(&symbolic)).unwrap();
    drop(reopened);
    std::fs::remove_dir_all(root).ok();
}
