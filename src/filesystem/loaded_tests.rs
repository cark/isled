//! Held-lock reuse and publication consistency, including remembered failures.
use super::*;
use crate::{cache::Cache, issue::IssueId, mutation, record::RecordDocument};
use std::fs;

fn fixture() -> (tempfile::TempDir, ProjectRoot) {
    let temp = tempfile::tempdir().unwrap();
    fs::create_dir(temp.path().join(".issues")).unwrap();
    fs::write(temp.path().join(".issues/.next-id"), "2\n").unwrap();
    fs::write(
        temp.path().join(".issues/0001-example.md"),
        crate::record::tests::RECORD,
    )
    .unwrap();
    let root = ProjectRoot::explicit(temp.path()).unwrap();
    (temp, root)
}

#[test]
fn successful_creation_invalidates_the_retained_inventory() {
    use crate::issue::{CreatedDate, Name};
    let (_temp, root) = fixture();
    let lock = root.acquire_lock().unwrap();
    let first = lock.issue_entries().unwrap();
    assert!(std::rc::Rc::ptr_eq(&first, &lock.issue_entries().unwrap()));
    assert_eq!(lock.read_identities().unwrap().len(), 1);
    let replacement = mutation::add_record_validated(
        IssueId::new(2).unwrap(),
        &Name::parse(b"new").unwrap(),
        &Name::parse(b"feature").unwrap(),
        &mutation::TitleText::parse("New").unwrap(),
        &mutation::AddStatementText::parse("A new record.").unwrap(),
        &CreatedDate::try_parse(b"2026-09-07").unwrap(),
        &[],
    );
    lock.add(&replacement).unwrap();
    assert!(!std::rc::Rc::ptr_eq(&first, &lock.issue_entries().unwrap()));
    assert_eq!(lock.read_identities().unwrap().len(), 2);
    assert_eq!(lock.next_available_id().unwrap(), IssueId::new(3).unwrap());
}

#[cfg(unix)]
#[test]
fn inventory_reuse_preserves_snapshot_identity_safety_checks() {
    use std::os::unix::{ffi::OsStringExt, fs::symlink};
    for damage in ["symlink", "invalid-utf8", "invalid-identity"] {
        // macOS rejects this filename at creation; Linux exercises its recovery.
        if damage == "invalid-utf8" && cfg!(target_os = "macos") {
            continue;
        }
        let (temp, root) = fixture();
        let directory = temp.path().join(".issues");
        match damage {
            "symlink" => symlink("0001-example.md", directory.join("0002-link.md")).unwrap(),
            "invalid-utf8" => fs::write(
                directory.join(std::ffi::OsString::from_vec(vec![0xff])),
                b"bad",
            )
            .unwrap(),
            _ => fs::write(directory.join("0000-bad.md"), b"bad").unwrap(),
        }
        let expected = root.read_identities().unwrap_err().to_string();
        let lock = root.acquire_lock().unwrap();
        drop(Cache::open_for_refresh(&lock, None).unwrap());
        let Err(error) = lock.read_snapshot_records() else {
            panic!("unsafe identity accepted");
        };
        assert_eq!(error.to_string(), expected);
    }
}

#[test]
fn cache_cleanup_policy_preserves_lock_release_on_finish_and_early_return() {
    for policy in [CacheCleanup::Drop, CacheCleanup::LeaveToProcessExit] {
        for finish in [true, false] {
            let (temp, root) = fixture();
            let root = root.with_cache_cleanup(policy);
            let lock = root.acquire_lock().unwrap();
            let records = lock.read_records().unwrap();
            records[0].issue().unwrap();
            let observed = records[0].weak_state();
            drop(records);
            let result = finish_or_fail(lock, finish);
            assert_eq!(result.is_ok(), finish);
            assert!(!temp.path().join(".issues/.cache/.isled-lock").exists());
            assert_eq!(
                observed.upgrade().is_some(),
                policy == CacheCleanup::LeaveToProcessExit
            );
            root.acquire_lock().unwrap().finish().unwrap();
        }
    }
}

fn finish_or_fail(lock: StoreLock<'_>, finish: bool) -> Result<(), &'static str> {
    if !finish {
        return Err("early command failure");
    }
    lock.finish().unwrap();
    Ok(())
}

#[test]
fn ordinary_roots_release_cached_records_across_repeated_requests() {
    let (_temp, root) = fixture();
    for _ in 0..3 {
        let observed = {
            let lock = root.acquire_lock().unwrap();
            let records = lock.read_records().unwrap();
            records[0].weak_state()
        };
        assert!(observed.upgrade().is_none());
    }
}

#[test]
fn refresh_rebuild_and_mutation_reuse_loaded_record_and_publish_consistent_state() {
    let (temp, root) = fixture();
    let lock = root.acquire_lock().unwrap();
    let records = lock.read_issue_records(IssueId::new(1).unwrap()).unwrap();
    records[0].header().unwrap();
    let mut cache = Cache::open(&lock).unwrap();
    cache.refresh(None).unwrap();
    drop(cache);
    drop(Cache::rebuild(&lock).unwrap());
    assert_eq!(lock.files_read(), 1);
    assert_eq!(records[0].parse_counts(), [1, 1, 1]);
    let text = mutation::StatementText::parse("A corrected statement.").unwrap();
    let plan = mutation::statement_mutate(
        &records,
        IssueId::new(1).unwrap(),
        mutation::StatementAction::Set,
        &text,
    )
    .unwrap();
    lock.publish(&plan).unwrap();
    let corrected = lock.read_issue_records(IssueId::new(1).unwrap()).unwrap();
    let bytes = fs::read(temp.path().join(".issues/0001-example.md")).unwrap();
    assert_eq!(corrected[0].bytes(), bytes);
    assert_eq!(
        corrected[0].document().unwrap(),
        &RecordDocument::parse(corrected[0].filename(), &bytes).unwrap()
    );
    assert_eq!(corrected[0].parse_counts(), [0, 0, 0]);
    assert_eq!(lock.files_read(), 1);
    assert_eq!(records[0].parse_counts(), [1, 1, 1]);
}

#[test]
fn failures_are_remembered_and_a_new_command_can_observe_external_repairs() {
    let (temp, root) = fixture();
    let path = temp.path().join(".issues/0001-example.md");
    fs::write(&path, b"bad").unwrap();
    let lock = root.acquire_lock().unwrap();
    let first = lock
        .load_file(b"0001-example.md")
        .unwrap()
        .record()
        .unwrap();
    assert!(first.document().is_err());
    fs::write(&path, crate::record::tests::RECORD).unwrap();
    let again = lock
        .load_file(b"0001-example.md")
        .unwrap()
        .record()
        .unwrap();
    assert!(again.document().is_err());
    assert_eq!(again.parse_counts(), [1, 0, 0]);
    for _ in 0..2 {
        assert!(
            matches!(lock.load_file(b"0002-missing.md"), Err(FilesystemError::Io(error)) if error.kind() == std::io::ErrorKind::NotFound)
        );
    }
    fs::write(temp.path().join(".issues/0002-missing.md"), b"new").unwrap();
    assert!(lock.load_file(b"0002-missing.md").is_err());
    assert_eq!(lock.files_read(), 1);
    lock.finish().unwrap();
    let lock = root.acquire_lock().unwrap();
    assert!(
        lock.load_file(b"0001-example.md")
            .unwrap()
            .record()
            .unwrap()
            .document()
            .is_ok()
    );
}

#[test]
fn failed_publication_keeps_original_loaded_bytes_and_parse() {
    let (temp, root) = fixture();
    let lock = root.acquire_lock().unwrap();
    let records = lock.read_records().unwrap();
    let plan = mutation::statement_mutate(
        &records,
        IssueId::new(1).unwrap(),
        mutation::StatementAction::Set,
        &mutation::StatementText::parse("Changed.").unwrap(),
    )
    .unwrap();
    fs::write(
        temp.path()
            .join(format!(".issues/.isled-rewrite-{}", std::process::id())),
        b"occupied",
    )
    .unwrap();
    assert!(lock.publish(&plan).is_err());
    let retained = lock.read_records().unwrap();
    assert_eq!(retained, records);
    assert_eq!(retained[0].document(), records[0].document());
    assert_eq!(lock.files_read(), 1);
}

#[test]
fn snapshot_reuses_shared_neighbors_bad_records_and_copied_title_corrections() {
    use crate::snapshot::{Snapshot, SnapshotSource};
    let (temp, root) = fixture();
    let template = std::str::from_utf8(crate::record::tests::RECORD).unwrap();
    // Both other issues refer to #0001; #0001 also refers to both of them.
    fs::write(
        temp.path().join(".issues/0002-foundation.md"),
        template
            .replace("# 0001 — Example", "# 0002 — Renamed foundation")
            .replace(
                "  - #0002 — Foundation\n    - **Reason:** Needed first.\n",
                "",
            )
            .replace("- **Waiting on:**\n", "")
            .replace("#0003 — Consumer", "#0001 — Example"),
    )
    .unwrap();
    fs::write(
        temp.path().join(".issues/0003-consumer.md"),
        template
            .replace("# 0001 — Example", "# 0003 — Consumer")
            .replace("#0002 — Foundation", "#0001 — Example")
            .replace("- **Blocking:**\n  - #0003 — Consumer\n", ""),
    )
    .unwrap();
    fs::write(temp.path().join(".issues/0004-bad.md"), "broken").unwrap();
    let lock = root.acquire_lock().unwrap();
    let originals = lock.read_records().unwrap();
    drop(Cache::open_for_refresh(&lock, None).unwrap());
    let reads = lock.read_snapshot_records().unwrap();
    let sources = reads
        .iter()
        .map(|read| {
            SnapshotSource::record(read.content.as_ref().unwrap(), read.identity.filename())
        })
        .collect::<Vec<_>>();
    let snapshot = Snapshot::build(b"root", &sources).unwrap();
    assert_eq!(snapshot.issues().len(), 3);
    assert_eq!(snapshot.unavailable().len(), 1);
    assert!(
        snapshot
            .issues()
            .iter()
            .all(|issue| issue.warnings().is_empty())
    );
    assert!(
        String::from_utf8_lossy(snapshot.issues()[0].content())
            .contains("#0002 — Renamed foundation")
    );
    for original in &originals[..3] {
        assert_eq!(original.parse_counts(), [1, 1, 1]);
    }
    assert_eq!(originals[3].parse_counts(), [1, 0, 0]);
    assert_eq!(reads[0].content.as_ref().unwrap().parse_counts(), [0, 0, 0]);
    // A second build and full refresh use current retained values, not original bytes.
    let again = Snapshot::build(b"root", &sources).unwrap();
    assert_eq!(snapshot, again);
    drop(Cache::open_for_refresh(&lock, None).unwrap());
    assert_eq!(lock.files_read(), 4);
}

#[cfg(unix)]
#[test]
fn a_failed_content_read_is_not_retried_after_permissions_change() {
    use std::os::unix::fs::PermissionsExt;
    let (temp, root) = fixture();
    let path = temp.path().join(".issues/0001-example.md");
    fs::set_permissions(&path, fs::Permissions::from_mode(0o0)).unwrap();
    let lock = root.acquire_lock().unwrap();
    let first = lock.load_file(b"0001-example.md").unwrap().record();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
    if let Err(first_error) = first {
        // Privileged runners can bypass file mode bits.
        let again = lock
            .load_file(b"0001-example.md")
            .unwrap()
            .record()
            .unwrap_err();
        assert_eq!(first_error.to_string(), again.to_string());
        assert_eq!(lock.files_read(), 1);
        lock.finish().unwrap();
        let next = root.acquire_lock().unwrap();
        assert!(next.load_file(b"0001-example.md").unwrap().record().is_ok());
    }
}

#[test]
fn partial_publication_updates_only_the_successfully_renamed_record() {
    let (temp, root) = fixture();
    let second = temp.path().join(".issues/0002-second.md");
    let text = std::str::from_utf8(crate::record::tests::RECORD)
        .unwrap()
        .replace("# 0001 — Example", "# 0002 — Second")
        .replace("#0002 — Foundation", "#0001 — Example");
    fs::write(&second, text).unwrap();
    let lock = root.acquire_lock().unwrap();
    let original = lock.read_records().unwrap();
    let plan = mutation::title_set(
        &original,
        IssueId::new(1).unwrap(),
        &mutation::TitleText::parse("Changed").unwrap(),
    )
    .unwrap();
    assert_eq!(plan.replacements().len(), 2);
    // Force the second rename to fail after the first succeeds.
    fs::remove_file(&second).unwrap();
    fs::create_dir(&second).unwrap();
    assert!(lock.publish(&plan).is_err());
    let first = lock
        .load_file(original[0].filename())
        .unwrap()
        .record()
        .unwrap();
    let second = lock
        .load_file(original[1].filename())
        .unwrap()
        .record()
        .unwrap();
    assert_eq!(first.bytes(), plan.replacements()[0].bytes());
    assert_eq!(first.document().unwrap().issue.title(), b"Changed");
    assert_eq!(first.parse_counts(), [0, 0, 0]);
    assert_eq!(second, original[1]);
    assert_eq!(second.document(), original[1].document());
    assert_eq!(lock.files_read(), 2);
    assert!(temp.path().join(".issues/.cache/pending").is_file());
}
