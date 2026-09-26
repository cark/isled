//! Fingerprint reuse must bound real writes without bypassing source validation.
use super::fixture::{fixture, run, run_successfully};
use rusqlite::Connection;
use std::{fs, path::Path, time::Duration};

fn observed_cache(root: &Path) -> Connection {
    run_successfully(root, &["cache", "refresh"]);
    let db = Connection::open(root.join(".issues/.cache/ledger.sqlite")).unwrap();
    db.execute_batch("CREATE TABLE observed_writes (table_name TEXT, operation TEXT, id INTEGER)")
        .unwrap();
    for (table, key) in [
        ("issues", "id"),
        ("issue_tags", "issue_id"),
        ("dependencies", "owner_issue_id"),
        ("cache_state", "singleton"),
    ] {
        for (operation, alias) in [("INSERT", "NEW"), ("DELETE", "OLD"), ("UPDATE", "NEW")] {
            db.execute_batch(&format!(
                "CREATE TRIGGER observe_{table}_{operation} AFTER {operation} ON {table}
                 BEGIN INSERT INTO observed_writes VALUES ('{table}', '{operation}', {alias}.{key}); END"
            )).unwrap();
        }
    }
    db
}

fn writes(db: &Connection) -> Vec<(String, String, i64)> {
    db.prepare(
        "SELECT table_name,operation,id FROM observed_writes ORDER BY table_name,operation,id",
    )
    .unwrap()
    .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))
    .unwrap()
    .map(Result::unwrap)
    .collect()
}

fn clear_writes(db: &Connection) {
    db.execute("DELETE FROM observed_writes", []).unwrap();
}

fn stored_hash(db: &Connection, id: i64) -> Option<i64> {
    db.query_row("SELECT content_hash FROM issues WHERE id=?1", [id], |row| {
        row.get(0)
    })
    .unwrap()
}

#[test]
fn unchanged_snapshots_and_refreshes_write_no_rows() {
    let temp = fixture();
    let db = observed_cache(temp.path());
    for args in [
        vec!["snapshot"],
        vec!["cache", "refresh"],
        vec!["cache", "refresh", "1"],
    ] {
        run_successfully(temp.path(), &args);
        assert!(writes(&db).is_empty(), "{args:?}: {:?}", writes(&db));
    }
}

#[test]
fn identical_bytes_with_new_timestamps_only_update_file_metadata() {
    let temp = fixture();
    let db = observed_cache(temp.path());
    let path = temp.path().join(".issues/0001-first.md");
    let before = stored_hash(&db, 1);
    let modified = fs::metadata(&path).unwrap().modified().unwrap() + Duration::from_secs(10);
    fs::File::options()
        .write(true)
        .open(&path)
        .unwrap()
        .set_modified(modified)
        .unwrap();
    run_successfully(temp.path(), &["cache", "refresh"]);
    assert_eq!(writes(&db), [("issues".into(), "UPDATE".into(), 1)]);
    assert_eq!(stored_hash(&db, 1), before);
    clear_writes(&db);
    run_successfully(temp.path(), &["snapshot"]);
    assert!(writes(&db).is_empty());
}

#[test]
fn same_size_and_mtime_edits_rebuild_only_the_changed_projection() {
    let temp = fixture();
    let db = observed_cache(temp.path());
    let path = temp.path().join(".issues/0001-first.md");
    let modified = fs::metadata(&path).unwrap().modified().unwrap();
    let before = stored_hash(&db, 1);
    fs::write(
        &path,
        fs::read_to_string(&path).unwrap().replace("Body.", "Edit."),
    )
    .unwrap();
    fs::File::options()
        .write(true)
        .open(&path)
        .unwrap()
        .set_modified(modified)
        .unwrap();
    run_successfully(temp.path(), &["cache", "refresh"]);
    assert_ne!(stored_hash(&db, 1), before);
    assert_eq!(
        writes(&db),
        [
            ("dependencies".into(), "DELETE".into(), 1),
            ("dependencies".into(), "INSERT".into(), 1),
            ("issue_tags".into(), "DELETE".into(), 1),
            ("issue_tags".into(), "INSERT".into(), 1),
            ("issues".into(), "DELETE".into(), 1),
            ("issues".into(), "INSERT".into(), 1),
        ]
    );
}

#[test]
fn malformed_contents_cannot_use_a_matching_fingerprint_to_keep_valid_rows() {
    let temp = fixture();
    let db = observed_cache(temp.path());
    let path = temp.path().join(".issues/0001-first.md");
    let original = fs::read_to_string(&path).unwrap();
    let broken = original.replace("## Evidence", "## Broken");
    fs::write(&path, &broken).unwrap();
    // Even a matching hash is not permission to skip complete-record validation.
    let fingerprint = xxhash_rust::xxh3::xxh3_64(broken.as_bytes()).cast_signed();
    db.execute(
        "UPDATE issues SET content_hash=?1 WHERE id=1",
        [fingerprint],
    )
    .unwrap();
    let result = run(temp.path(), &["snapshot"]);
    assert!(result.status.success());
    assert!(String::from_utf8_lossy(&result.stderr).contains("incomplete"));
    assert_eq!(stored_hash(&db, 1), None);
    assert_eq!(
        db.query_row(
            "SELECT count(*) FROM issue_tags WHERE issue_id=1",
            [],
            |r| r.get::<_, i64>(0)
        )
        .unwrap(),
        0
    );
    fs::write(&path, original).unwrap();
    run_successfully(temp.path(), &["snapshot"]);
    assert!(stored_hash(&db, 1).is_some());
    assert_eq!(
        db.query_row(
            "SELECT count(*) FROM issue_tags WHERE issue_id=1",
            [],
            |r| r.get::<_, i64>(0)
        )
        .unwrap(),
        1
    );
}

#[test]
fn copied_title_corrections_store_the_published_fingerprint() {
    let temp = fixture();
    let db = observed_cache(temp.path());
    let path = temp.path().join(".issues/0002-second.md");
    fs::write(
        &path,
        fs::read_to_string(&path)
            .unwrap()
            .replace("Second", "Changed"),
    )
    .unwrap();
    run_successfully(temp.path(), &["snapshot"]);
    for (id, name) in [(1, "0001-first.md"), (2, "0002-second.md")] {
        let bytes = fs::read(temp.path().join(".issues").join(name)).unwrap();
        assert_eq!(
            stored_hash(&db, id),
            Some(xxhash_rust::xxh3::xxh3_64(&bytes).cast_signed())
        );
    }
    // The correction replaces a file, so first reconcile the new directory hint.
    run_successfully(temp.path(), &["snapshot"]);
    clear_writes(&db);
    run_successfully(temp.path(), &["snapshot"]);
    assert!(writes(&db).is_empty());
}

#[test]
fn failed_projection_write_rolls_back_the_fingerprint_and_retries() {
    let temp = fixture();
    let db = observed_cache(temp.path());
    let before = stored_hash(&db, 1);
    db.execute_batch("CREATE TRIGGER reject_tag BEFORE INSERT ON issue_tags BEGIN SELECT RAISE(ABORT, 'injected write failure'); END").unwrap();
    let path = temp.path().join(".issues/0001-first.md");
    fs::write(
        &path,
        fs::read_to_string(&path)
            .unwrap()
            .replace("Body.", "Changed."),
    )
    .unwrap();
    let result = run(temp.path(), &["cache", "refresh"]);
    assert!(!result.status.success());
    assert_eq!(stored_hash(&db, 1), before);
    assert!(writes(&db).is_empty());
    db.execute_batch("DROP TRIGGER reject_tag").unwrap();
    run_successfully(temp.path(), &["cache", "refresh"]);
    assert_ne!(stored_hash(&db, 1), before);
}
