use super::fixture::{fixture, id, record, run, run_successfully};
use isled::cache::Cache;
use isled::filesystem::ProjectRoot;
use isled::query::Filters;
use std::fs;

#[cfg(unix)]
#[test]
fn title_repair_failure_keeps_records_readable_and_releases_the_existing_lock() {
    let temp = fixture();
    // Initial indexing is a preceding command. This command starts with no
    // loaded contents, so its explicit refresh observes the external edit.
    run_successfully(temp.path(), &["list"]);
    let root = ProjectRoot::explicit(temp.path()).unwrap();
    {
        let lock = root.acquire_lock().unwrap();
        let mut cache = Cache::open(&lock).unwrap();
        fs::write(
            temp.path().join(".issues/0002-second.md"),
            record(2, "Changed", "", "", "- **Blocking:**\n  - #0001 — First\n"),
        )
        .unwrap();
        std::os::unix::fs::symlink("/dev/null", temp.path().join(".issues/.cache/pending"))
            .unwrap();
        cache.refresh(Some(id(1))).unwrap();
        assert!(
            cache
                .warnings()
                .iter()
                .any(|w| w.contains("copied-title repair failed"))
        );
        assert_eq!(cache.summaries(&Filters::default()).unwrap().len(), 3);
    }
    assert!(!temp.path().join(".issues/.cache/.isled-lock").exists());
}

#[test]
fn damaged_pending_and_schema_or_row_corruption_recover() {
    let temp = fixture();
    run_successfully(temp.path(), &["list"]);
    fs::write(temp.path().join(".issues/.cache/pending"), [0xff]).unwrap();
    let out = run(temp.path(), &["list"]);
    assert!(out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("damaged pending"));
    assert!(!temp.path().join(".issues/.cache/pending").exists());
    for sql in [
        "DROP TABLE issue_tags",
        "UPDATE issues SET title='' WHERE id=3",
    ] {
        {
            let db = rusqlite::Connection::open(temp.path().join(".issues/.cache/ledger.sqlite"))
                .unwrap();
            db.execute_batch(sql).unwrap();
        }
        let out = run(temp.path(), &["list"]);
        assert!(out.status.success(), "{out:?}");
        assert!(String::from_utf8_lossy(&out.stderr).contains("corrupt cache"));
        assert!(String::from_utf8_lossy(&out.stdout).contains("Third"));
    }
}

#[test]
fn own_edits_synchronize_and_failed_cache_updates_do_not_undo_or_repeat_edits() {
    let temp = fixture();
    run_successfully(temp.path(), &["list"]);
    run_successfully(temp.path(), &["tag", "add", "3", "fresh"]);
    assert!(run_successfully(temp.path(), &["list", "--tags", "fresh"]).contains("Third"));
    let db = temp.path().join(".issues/.cache/ledger.sqlite");
    fs::remove_file(&db).unwrap();
    fs::create_dir(&db).unwrap();
    let edit = run(
        temp.path(),
        &["statement", "append", "3", "Saved exactly once."],
    );
    assert!(edit.status.success(), "{edit:?}");
    assert!(String::from_utf8_lossy(&edit.stderr).contains("edit saved; cache update failed"));
    assert!(temp.path().join(".issues/.cache/pending").is_file());
    fs::remove_dir(&db).unwrap();
    run_successfully(temp.path(), &["list"]);
    assert!(!temp.path().join(".issues/.cache/pending").exists());
    let body = fs::read_to_string(temp.path().join(".issues/0003-third.md")).unwrap();
    assert_eq!(body.matches("Saved exactly once.").count(), 1);
}

#[test]
fn incompatible_and_corrupt_cache_rebuild_without_changing_markdown() {
    let temp = fixture();
    run_successfully(temp.path(), &["list"]);
    let path = temp.path().join(".issues/0001-first.md");
    let before = fs::read(&path).unwrap();
    let db = temp.path().join(".issues/.cache/ledger.sqlite");
    {
        let connection = rusqlite::Connection::open(&db).unwrap();
        connection.execute_batch("PRAGMA user_version=99").unwrap();
    }
    assert!(run_successfully(temp.path(), &["list"]).contains("First"));
    fs::write(&db, "not a SQLite database").unwrap();
    let out = run(temp.path(), &["list"]);
    assert!(out.status.success(), "{out:?}");
    assert!(String::from_utf8_lossy(&out.stderr).contains("corrupt cache"));
    assert_eq!(fs::read(&path).unwrap(), before);
    assert!(run(temp.path(), &["check"]).status.success());
}

#[test]
fn interrupted_publication_pending_set_is_reconciled_on_next_read() {
    let temp = fixture();
    run_successfully(temp.path(), &["list"]);
    fs::write(
        temp.path().join(".issues/.cache/pending"),
        "0003-third.md\n",
    )
    .unwrap();
    fs::write(
        temp.path().join(".issues/0003-third.md"),
        record(3, "Changed", "- **Tags:** changed\n", "", ""),
    )
    .unwrap();
    assert!(run_successfully(temp.path(), &["list", "--tags", "changed"]).contains("Changed"));
    assert!(!temp.path().join(".issues/.cache/pending").exists());
}

#[test]
fn lock_contention_is_bounded_and_help_has_no_filesystem_effects() {
    let temp = fixture();
    let root = ProjectRoot::explicit(temp.path()).unwrap();
    let lock = root.acquire_lock().unwrap();
    let out = run(temp.path(), &["list"]);
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("locked"));
    drop(lock);
    let empty = tempfile::tempdir().unwrap();
    assert!(
        run_successfully(empty.path(), &["help", "cache", "refresh"]).contains("entire ledger")
    );
    assert!(!empty.path().join(".issues").exists());
}

#[cfg(unix)]
#[test]
fn cache_and_pending_symlinks_are_not_followed() {
    use std::os::unix::fs::symlink;
    let temp = fixture();
    let elsewhere = tempfile::tempdir().unwrap();
    symlink(elsewhere.path(), temp.path().join(".issues/.cache")).unwrap();
    assert!(!run(temp.path(), &["list"]).status.success());
    assert_eq!(fs::read_dir(elsewhere.path()).unwrap().count(), 0);
    fs::remove_file(temp.path().join(".issues/.cache")).unwrap();
    run_successfully(temp.path(), &["list"]);
    let victim = elsewhere.path().join("victim");
    fs::write(&victim, "unchanged").unwrap();
    symlink(&victim, temp.path().join(".issues/.cache/pending")).unwrap();
    let record_path = temp.path().join(".issues/0003-third.md");
    let before = fs::read(&record_path).unwrap();
    assert!(
        !run(temp.path(), &["tag", "add", "3", "new"])
            .status
            .success()
    );
    assert_eq!(fs::read(record_path).unwrap(), before);
    assert_eq!(fs::read_to_string(victim).unwrap(), "unchanged");
}
