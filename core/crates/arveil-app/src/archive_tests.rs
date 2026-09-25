use super::*;
use rusqlite::params;

struct Fixture {
    config: ProfileConfig,
    app: Application,
}
impl Fixture {
    fn new() -> Self {
        let dir = std::env::temp_dir().join(format!(
            "arveil-archives-{}",
            hex::encode(getrandom::u64().unwrap().to_be_bytes())
        ));
        let config = ProfileConfig::encrypted(&dir, "ab".repeat(32))
            .unwrap()
            .with_manual_attachments();
        let app = Application::open(config.clone()).unwrap();
        Self { config, app }
    }
    fn client(&self) -> Client {
        open_client(&self.config).unwrap()
    }
    fn conn(&self) -> SharedConn {
        SharedConn::open_file_keyed(&self.config.dir().join("client.db"), self.config.key())
            .unwrap()
    }
    fn identity(&self) {
        self.client().identity_new().unwrap();
        self.client().device_new(onboarding::now()).unwrap();
    }
    fn restored(&self) -> Self {
        let mut f = Self::new();
        f.app.close();
        f.config = ProfileConfig::encrypted(f.config.dir(), "cd".repeat(32))
            .unwrap()
            .with_manual_attachments();
        std::fs::remove_file(f.config.dir().join("client.db")).unwrap();
        let source = self.client();
        f.client()
            .identity_restore(
                &source.root().unwrap().unwrap().signing.to_bytes(),
                &source.latest_manifest().unwrap().unwrap(),
            )
            .unwrap();
        f.app = Application::open(f.config.clone()).unwrap();
        f
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.app.close();
        let _ = std::fs::remove_dir_all(self.config.dir());
    }
}

fn record(n: u8, kind: &str, body: &[u8]) -> ArchiveRecord {
    ArchiveRecord {
        group_id: vec![3; 32],
        event_id: vec![n; 16],
        kind: kind.into(),
        body: body.to_vec(),
        created_at: 42,
        file_name: None,
        file: vec![],
        file_present: false,
    }
}
fn request(f: &Fixture, records: Vec<ArchiveRecord>) -> ArchiveImport {
    let secret = Secret::generate();
    let encrypted = recovery::archive_seal(
        &HistoryArchive {
            version: ARCHIVE_VERSION,
            identity_id: f.client().identity_id().unwrap().unwrap(),
            exported_at: 1,
            records,
        },
        &secret,
    )
    .unwrap();
    ArchiveImport {
        encrypted,
        secret: secret.to_string_once(),
    }
}

#[test]
fn history_moves_to_a_new_key_without_reviving_events_or_mls() {
    let source = Fixture::new();
    source.identity();
    let r = record(1, "received", b"private historical message");
    source
        .client()
        .delivery()
        .unwrap()
        .record_event(&r.group_id, &r.event_id, &r.kind, &r.body)
        .unwrap();
    let exported = source.app.export_archive().unwrap();
    assert!(
        !exported
            .encrypted
            .windows(r.body.len())
            .any(|w| w == r.body)
    );
    assert_eq!(format!("{exported:?}"), "ArchiveExport([redacted])");
    let target = source.restored();
    let req = ArchiveImport {
        encrypted: exported.encrypted,
        secret: exported.secret,
    };
    assert_eq!(target.app.import_archive(req.clone()).unwrap().imported, 1);
    assert_eq!(target.app.import_archive(req).unwrap().duplicates, 1);
    let page = target.app.archive_page(None, 25).unwrap();
    assert_eq!(page.entries[0].text, "private historical message");
    target.client().delivery().unwrap();
    for table in ["events", "outbox", "mls_group_state", "conversations"] {
        assert_eq!(target.conn().count(table).unwrap(), 0);
    }
    assert!(target.client().device().unwrap().is_none());
    let again = target.app.export_archive().unwrap();
    assert_eq!(again.records, 1);
    target.app.close();
    let reopened = Application::open(target.config.clone()).unwrap();
    assert_eq!(reopened.archive_page(None, 1).unwrap().entries.len(), 1);
    reopened.close();
}

#[test]
fn invalid_inputs_and_storage_failure_leave_no_partial_import() {
    let f = Fixture::new();
    f.identity();
    let other = Fixture::new();
    other.identity();
    let valid = request(
        &f,
        vec![record(1, "received", b"one"), record(2, "sent", b"two")],
    );
    assert!(other.app.import_archive(valid.clone()).is_err());
    let mut wrong = valid.clone();
    wrong.secret = Secret::generate().to_string_once();
    assert!(f.app.import_archive(wrong).is_err());
    let mut corrupt = valid.clone();
    *corrupt.encrypted.last_mut().unwrap() ^= 1;
    assert!(f.app.import_archive(corrupt).is_err());
    assert!(
        f.app
            .import_archive(request(
                &f,
                vec![record(1, "received", b"one"), record(2, "unknown", b"two")]
            ))
            .is_err()
    );
    f.conn().lock().execute_batch("CREATE TRIGGER fail_archive BEFORE INSERT ON archived_events WHEN NEW.kind='sent' BEGIN SELECT RAISE(ABORT,'fixture failure'); END;").unwrap();
    assert!(f.app.import_archive(valid.clone()).is_err());
    assert_eq!(f.conn().count("archived_events").unwrap(), 0);
    f.conn()
        .lock()
        .execute_batch("DROP TRIGGER fail_archive")
        .unwrap();
    assert_eq!(f.app.import_archive(valid).unwrap().imported, 2);
}

#[test]
fn files_stay_in_encrypted_storage_and_duplicate_import_never_overwrites() {
    let f = Fixture::new();
    f.identity();
    let mut file = record(1, "received-file", b"old local path");
    file.file_name = Some("../../fixture.txt".into());
    file.file = b"file content".to_vec();
    let mut empty = record(2, "sent-file", b"");
    empty.file_name = Some("empty.txt".into());
    empty.file_present = true;
    let mut missing = record(3, "file-pending", b"descriptor with capability");
    missing.file_name = Some("missing.txt".into());
    f.app
        .import_archive(request(&f, vec![file.clone(), empty, missing]))
        .unwrap();
    assert!(!f.config.dir().join("downloads").exists());
    let page = f.app.archive_page(None, 2).unwrap();
    assert_eq!(page.entries.len(), 2);
    assert!(page.next.is_some());
    assert_eq!(page.entries[0].file_size, None);
    assert_eq!(page.entries[1].file_size, Some(0));
    let last = f.app.archive_page(page.next, 2).unwrap();
    assert_eq!(last.entries[0].file_name.as_deref(), Some("fixture.txt"));
    assert_eq!(last.next, None);
    assert_eq!(
        f.app
            .archive_file(file.group_id.clone(), file.event_id.clone())
            .unwrap(),
        file.file
    );
    file.file = b"replacement".to_vec();
    assert_eq!(
        f.app
            .import_archive(request(&f, vec![file.clone()]))
            .unwrap()
            .duplicates,
        1
    );
    assert_eq!(
        f.app.archive_file(file.group_id, file.event_id).unwrap(),
        b"file content"
    );
    let export = f.app.export_archive().unwrap();
    assert_eq!((export.files, export.unavailable_files), (2, 1));
    let decoded =
        recovery::archive_open(&export.encrypted, &Secret::parse(&export.secret).unwrap()).unwrap();
    assert!(
        decoded
            .records
            .iter()
            .all(|r| !String::from_utf8_lossy(&r.body).contains("capability"))
    );
}

#[test]
fn live_managed_file_is_verified_before_export() {
    let f = Fixture::new();
    f.identity();
    let d = f.client().delivery().unwrap();
    let r = record(9, "received-file", b"");
    d.record_event(&r.group_id, &r.event_id, &r.kind, &r.body)
        .unwrap();
    let encrypted = attachments::encrypt(b"verified content").unwrap();
    let descriptor = FileDescriptor {
        version: attachments::VERSION,
        name: "note.txt".into(),
        mime: "text/plain".into(),
        size: 16,
        blob_id: vec![1; 16],
        read_capability: vec![2; 32],
        file_key: encrypted.file_key,
        nonce: encrypted.nonce,
        ciphertext_hash: encrypted.ciphertext_hash,
    };
    d.attachment_create(
        &r.event_id,
        &arveil_core::delivery::AttachmentRow {
            outgoing: false,
            name: "note.txt".into(),
            size: 16,
            state: "ready".into(),
            descriptor: descriptor.encode().unwrap(),
            offset: 32,
            committed: true,
            expires_at: None,
        },
    )
    .unwrap();
    d.attachment_chunk(&r.event_id, 0, &encrypted.ciphertext)
        .unwrap();
    assert_eq!(f.app.export_archive().unwrap().files, 1);
    f.conn()
        .lock()
        .execute(
            "UPDATE attachment_chunks SET data=?1",
            params![b"broken".as_slice()],
        )
        .unwrap();
    assert!(f.app.export_archive().is_err());
}

#[test]
fn archive_limits_reject_the_whole_request() {
    let f = Fixture::new();
    f.identity();
    let oversized = ArchiveImport {
        encrypted: vec![0; MAX_ARCHIVE_BYTES + 1],
        secret: Secret::generate().to_string_once(),
    };
    assert!(f.app.import_archive(oversized).is_err());
    let records = vec![record(1, "received", b"one"); recovery::MAX_ARCHIVE_RECORDS + 1];
    assert!(f.app.import_archive(request(&f, records)).is_err());
    let long_text = record(2, "received", &vec![b'x'; 1024 * 1024 + 1]);
    assert!(f.app.import_archive(request(&f, vec![long_text])).is_err());
    assert_eq!(f.conn().count("archived_events").unwrap(), 0);
    f.client().delivery().unwrap();
    f.conn().lock().execute_batch(
        "WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<10001)
         INSERT INTO events(group_id,event_id,kind,body) SELECT X'01',randomblob(16),'received',X'78' FROM n;"
    ).unwrap();
    assert!(f.app.export_archive().is_err());
}
