//! Human batch inspection, failure attribution, and shared physical reads.
#[path = "cache/fixture.rs"]
#[allow(dead_code)]
mod fixture;
use isled::{cache::Cache, filesystem::ProjectRoot};
use std::fs;

#[test]
fn order_duplicates_unicode_and_only_needed_newlines_are_preserved() {
    let dir = fixture::fixture();
    let path = dir.path().join(".issues/0003-third.md");
    let third = fixture::record(3, "Café 日本語", "", "", "")
        .trim_end_matches('\n')
        .to_owned();
    fs::write(&path, &third).unwrap();
    let first = fs::read(dir.path().join(".issues/0001-first.md")).unwrap();
    let output = fixture::run(dir.path(), &["show", "#3", "01", "003"]);
    assert!(output.status.success(), "{output:?}");
    assert!(output.stderr.is_empty(), "{output:?}");
    assert_eq!(
        output.stdout,
        [third.as_bytes(), b"\n", &first, third.as_bytes()].concat()
    );
    assert_eq!(fs::read(path).unwrap(), third.as_bytes());
}

#[test]
fn malformed_missing_and_bad_utf8_are_omitted_without_stopping_the_batch() {
    let dir = fixture::fixture();
    fs::write(dir.path().join(".issues/0001-first.md"), "broken café").unwrap();
    fs::write(dir.path().join(".issues/0002-second.md"), [0xff]).unwrap();
    let third = fs::read(dir.path().join(".issues/0003-third.md")).unwrap();
    let output = fixture::run(dir.path(), &["show", "3", "1", "99", "2", "3"]);
    assert_eq!(output.status.code(), Some(1));
    assert_eq!(output.stdout, [&third[..], &third].concat());
    let errors = String::from_utf8(output.stderr).unwrap();
    let lines: Vec<_> = errors.lines().collect();
    assert_eq!(lines.len(), 3, "{errors}");
    assert!(lines[0].starts_with("isled: issue #0001: error:"));
    assert!(lines[0].contains("invalid or out-of-order record sections"));
    assert!(lines[1].contains("issue #0099: error: issue not found: 0099"));
    assert!(lines[2].contains("issue #0002: error:") && lines[2].contains("UTF-8"));
    assert!(!dir.path().join(".issues/.cache/.isled-lock").exists());
}

#[test]
fn repeated_id_still_selects_batch_validation_but_single_show_stays_raw() {
    let dir = fixture::fixture();
    let bytes = b"malformed\r\nwithout final newline";
    fs::write(dir.path().join(".issues/0003-third.md"), bytes).unwrap();
    let single = fixture::run(dir.path(), &["show", "3"]);
    assert!(single.status.success());
    assert_eq!(single.stdout, bytes);
    let batch = fixture::run(dir.path(), &["show", "3", "#003"]);
    assert_eq!(batch.status.code(), Some(1));
    assert!(batch.stdout.is_empty());
    let errors = String::from_utf8(batch.stderr).unwrap();
    assert_eq!(errors.lines().count(), 2);
    assert!(
        errors
            .lines()
            .all(|line| line.starts_with("isled: issue #0003: error:"))
    );
}

#[test]
fn relation_warnings_keep_both_endpoints_visible_and_do_not_fail() {
    let dir = fixture::fixture();
    fs::write(
        dir.path().join(".issues/0002-second.md"),
        fixture::record(2, "Second", "", "", ""),
    )
    .unwrap();
    let output = fixture::run(dir.path(), &["show", "2", "1"]);
    assert!(output.status.success(), "{output:?}");
    let errors = String::from_utf8(output.stderr).unwrap();
    let lines: Vec<_> = errors.lines().collect();
    assert_eq!(lines.len(), 2, "{errors}");
    assert!(lines[0].contains("issue #0002: warning [RELATION_RECIPROCAL]"));
    assert!(lines[1].contains("issue #0001: warning [RELATION_RECIPROCAL]"));
    assert!(
        lines
            .iter()
            .all(|line| line.contains("Issue #0002 lacks reciprocal Blocking #0001."))
    );
    let second = fs::read(dir.path().join(".issues/0002-second.md")).unwrap();
    let first = fs::read(dir.path().join(".issues/0001-first.md")).unwrap();
    assert_eq!(output.stdout, [second, first].concat());
}

#[test]
fn shared_neighbors_are_read_once_and_unrelated_content_is_not_loaded() {
    let dir = fixture::fixture();
    fixture::run_successfully(dir.path(), &["cache", "refresh"]);
    fs::write(
        dir.path().join(".issues/0003-third.md"),
        "unrelated broken edit",
    )
    .unwrap();
    let root = ProjectRoot::discover(dir.path()).unwrap();
    let lock = root.acquire_lock().unwrap();
    let mut cache = Cache::open(&lock).unwrap();
    let selected = [fixture::id(1), fixture::id(2)].into_iter().collect();
    let first = cache.show_batch(&selected).unwrap();
    assert_eq!(cache.files_read(), 2);
    let again = cache.show_batch(&selected).unwrap();
    assert_eq!(cache.files_read(), 2);
    for id in selected {
        // The retained parsed Issue itself is reused, not merely equal output.
        assert!(std::ptr::eq(
            first[&id].content().unwrap().issue().unwrap(),
            again[&id].content().unwrap().issue().unwrap()
        ));
    }
    drop(cache);
    lock.finish().unwrap();
}

#[test]
fn copied_title_repair_is_visible_in_each_repeated_result() {
    let dir = fixture::fixture();
    fixture::run_successfully(dir.path(), &["cache", "refresh"]);
    let path = dir.path().join(".issues/0002-second.md");
    let renamed = fs::read_to_string(&path)
        .unwrap()
        .replacen("— Second", "— Renamed", 1);
    fs::write(path, renamed).unwrap();
    let output = fixture::run(dir.path(), &["show", "1", "1"]);
    assert!(output.status.success(), "{output:?}");
    assert!(output.stderr.is_empty(), "{output:?}");
    let first = fs::read(dir.path().join(".issues/0001-first.md")).unwrap();
    assert!(String::from_utf8_lossy(&first).contains("#0002 — Renamed"));
    assert_eq!(output.stdout, [&first[..], &first].concat());
}

#[test]
fn duplicate_file_identity_is_an_error_not_a_missing_record() {
    let dir = fixture::fixture();
    fs::write(dir.path().join(".issues/0003-duplicate.md"), "malformed").unwrap();
    let output = fixture::run(dir.path(), &["show", "3", "1"]);
    assert_eq!(output.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&output.stderr).contains(
        "issue #0003: error: Cannot establish issue identity: multiple issue files found for 0003"
    ));
    assert_eq!(
        output.stdout,
        fs::read(dir.path().join(".issues/0001-first.md")).unwrap()
    );
}

#[test]
fn invalid_argument_and_unavailable_ledger_are_command_errors() {
    let dir = fixture::fixture();
    let output = fixture::run(dir.path(), &["show", "1", "bad", "3"]);
    assert_eq!(output.status.code(), Some(1));
    assert!(output.stdout.is_empty());
    assert!(String::from_utf8_lossy(&output.stderr).starts_with("isled: issue ID must be"));
    let missing = dir.path().join("missing");
    let batch = fixture::run(&missing, &["show", "1", "bad"]);
    let single = fixture::run(&missing, &["show", "1"]);
    assert_eq!(batch.status.code(), Some(1));
    assert!(batch.stdout.is_empty());
    assert_eq!(batch.stderr, single.stderr);
}

#[test]
fn missing_and_unreadable_neighbors_warn_on_the_requested_record() {
    let dir = fixture::fixture();
    fs::write(dir.path().join(".issues/0002-second.md"), "broken").unwrap();
    let first = fixture::record(
        1,
        "First",
        "",
        "- **Waiting on:**\n  - #0002 — Second\n    - **Reason:** Needed.\n  - #0099 — Missing\n    - **Reason:** Also needed.\n",
        "",
    );
    fs::write(dir.path().join(".issues/0001-first.md"), &first).unwrap();
    let output = fixture::run(dir.path(), &["show", "1", "3"]);
    assert!(output.status.success(), "{output:?}");
    assert!(output.stdout.starts_with(first.as_bytes()));
    let errors = String::from_utf8(output.stderr).unwrap();
    assert_eq!(errors.lines().count(), 2, "{errors}");
    assert!(
        errors
            .lines()
            .all(|line| line.starts_with("isled: issue #0001: warning"))
    );
    assert!(errors.contains("[RELATION_UNREADABLE]: Waiting on refers to unreadable issue #0002"));
    assert!(errors.contains("[RELATION_MISSING]: Waiting on refers to missing issue #0099"));
}

#[test]
fn corruption_during_batch_preparation_retries_without_duplicate_output() {
    let dir = fixture::fixture();
    fixture::run_successfully(dir.path(), &["cache", "refresh"]);
    let db = rusqlite::Connection::open(dir.path().join(".issues/.cache/ledger.sqlite")).unwrap();
    db.execute("UPDATE issues SET filename='9999-wrong.md' WHERE id=1", [])
        .unwrap();
    drop(db);
    let output = fixture::run(dir.path(), &["show", "3", "1"]);
    assert!(output.status.success(), "{output:?}");
    assert!(String::from_utf8_lossy(&output.stderr).contains("rebuilding once"));
    let expected = [
        fs::read(dir.path().join(".issues/0003-third.md")).unwrap(),
        fs::read(dir.path().join(".issues/0001-first.md")).unwrap(),
    ]
    .concat();
    assert_eq!(output.stdout, expected);
}

#[test]
fn merged_streams_keep_records_and_issue_errors_in_request_order() {
    use std::process::{Command, Stdio};
    let dir = fixture::fixture();
    let third = fixture::record(3, "Third", "", "", "")
        .trim_end_matches('\n')
        .to_owned();
    fs::write(dir.path().join(".issues/0003-third.md"), &third).unwrap();
    let merged = tempfile::NamedTempFile::new().unwrap();
    let out = merged.reopen().unwrap();
    let status = Command::new(env!("CARGO_BIN_EXE_isled"))
        .arg("--root")
        .arg(dir.path())
        .args(["show", "3", "99", "1"])
        .stdout(Stdio::from(out.try_clone().unwrap()))
        .stderr(Stdio::from(out))
        .status()
        .unwrap();
    assert_eq!(status.code(), Some(1));
    let first = fs::read(dir.path().join(".issues/0001-first.md")).unwrap();
    assert_eq!(
        fs::read(merged.path()).unwrap(),
        [
            third.as_bytes(),
            b"isled: issue #0099: error: issue not found: 0099\n",
            b"\n",
            &first
        ]
        .concat()
    );
}
