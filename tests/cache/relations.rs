use super::fixture::{fixture, record, run, run_successfully};
use std::fs;

#[test]
fn automatic_titles_are_bounded_idempotent_and_explicit_repairs_clear_both_sides() {
    let temp = fixture();
    run_successfully(temp.path(), &["list"]);
    let dir = temp.path().join(".issues");
    let first = fs::read_to_string(dir.join("0001-first.md"))
        .unwrap()
        .replace("# 0001 — First", "# 0001 — First renamed");
    let second = fs::read_to_string(dir.join("0002-second.md"))
        .unwrap()
        .replace("# 0002 — Second", "# 0002 — Second renamed");
    fs::write(dir.join("0001-first.md"), &first).unwrap();
    fs::write(dir.join("0002-second.md"), &second).unwrap();
    run_successfully(temp.path(), &["show", "1"]);
    assert_eq!(
        fs::read_to_string(dir.join("0001-first.md")).unwrap(),
        first.replace("#0002 — Second", "#0002 — Second renamed")
    );
    assert_eq!(
        fs::read_to_string(dir.join("0002-second.md")).unwrap(),
        second.replace("#0001 — First", "#0001 — First renamed")
    );
    let modified = fs::metadata(dir.join("0001-first.md"))
        .unwrap()
        .modified()
        .unwrap();
    run_successfully(temp.path(), &["snapshot"]);
    assert_eq!(
        fs::metadata(dir.join("0001-first.md"))
            .unwrap()
            .modified()
            .unwrap(),
        modified
    );
    assert!(!dir.join(".cache/.isled-lock").exists());
    fs::write(
        dir.join("0002-second.md"),
        record(2, "Second renamed", "", "", ""),
    )
    .unwrap();
    let snapshot: serde_json::Value =
        serde_json::from_str(&run_successfully(temp.path(), &["snapshot"])).unwrap();
    assert_eq!(
        snapshot["issues"][0]["warnings"][0]["code"],
        "RELATION_RECIPROCAL"
    );
    assert_eq!(
        snapshot["issues"][1]["warnings"][0]["code"],
        "RELATION_RECIPROCAL"
    );
    run_successfully(temp.path(), &["wait", "repair", "complete", "1", "2"]);
    assert!(run(temp.path(), &["check"]).status.success());
    run_successfully(temp.path(), &["wait", "repair", "remove", "1", "2"]);
    assert!(run_successfully(temp.path(), &["list", "--ready"]).contains("First renamed"));
    fs::write(
        dir.join("0002-second.md"),
        record(
            2,
            "Second renamed",
            "",
            "",
            "- **Blocking:**\n  - #0001 — First renamed\n",
        ),
    )
    .unwrap();
    run_successfully(temp.path(), &["cache", "refresh"]);
    assert!(!run_successfully(temp.path(), &["list", "--ready"]).contains("First renamed"));
    run_successfully(
        temp.path(),
        &[
            "wait",
            "repair",
            "complete",
            "1",
            "2",
            "--reason",
            "Explicitly recovered.",
        ],
    );
    assert!(run(temp.path(), &["check"]).status.success());
    fs::remove_file(dir.join("0002-second.md")).unwrap();
    run_successfully(temp.path(), &["wait", "repair", "remove", "1", "2"]);
    assert!(run(temp.path(), &["check"]).status.success());
}

#[test]
fn local_relation_warnings_preserve_raw_show_and_clear_after_external_repair() {
    let temp = fixture();
    run_successfully(temp.path(), &["list"]);
    let path = temp.path().join(".issues/0002-second.md");
    fs::write(&path, record(2, "Renamed", "", "", "")).unwrap();
    let original = fs::read(temp.path().join(".issues/0001-first.md")).unwrap();
    let out = run(temp.path(), &["show", "1"]);
    assert!(out.status.success());
    assert_eq!(
        out.stdout,
        String::from_utf8(original.clone())
            .unwrap()
            .replace("#0002 — Second", "#0002 — Renamed")
            .as_bytes()
    );
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(!stderr.contains("RELATION_TITLE"));
    assert!(stderr.contains("RELATION_RECIPROCAL"));
    let snapshot: serde_json::Value =
        serde_json::from_str(&run_successfully(temp.path(), &["snapshot"])).unwrap();
    assert_eq!(
        snapshot["issues"][0]["warnings"].as_array().unwrap().len(),
        1
    );
    assert_eq!(
        snapshot["issues"][0]["warnings"][0]["related_ids"][0],
        "0002"
    );
    fs::write(
        &path,
        record(2, "Second", "", "", "- **Blocking:**\n  - #0001 — First\n"),
    )
    .unwrap();
    let out = run(temp.path(), &["show", "1"]);
    assert!(out.status.success());
    assert!(out.stderr.is_empty());
    fs::write(&path, "malformed record").unwrap();
    let out = run(temp.path(), &["show", "1"]);
    assert!(out.status.success());
    assert_eq!(out.stdout, original);
    assert!(String::from_utf8_lossy(&out.stderr).contains("RELATION_UNREADABLE"));
    fs::remove_file(&path).unwrap();
    let out = run(temp.path(), &["show", "1"]);
    assert!(out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("RELATION_MISSING"));
    let snapshot: serde_json::Value =
        serde_json::from_str(&run_successfully(temp.path(), &["snapshot"])).unwrap();
    assert_eq!(
        snapshot["issues"][0]["warnings"][0]["code"],
        "RELATION_MISSING"
    );
    assert_eq!(snapshot["issues"][0]["ready"], false);
}

#[test]
fn one_sided_external_relations_are_not_silently_repaired_or_invented() {
    let temp = fixture();
    run_successfully(temp.path(), &["list"]);
    let path = temp.path().join(".issues/0002-second.md");
    let without_mirror = record(2, "Second", "", "", "");
    fs::write(&path, &without_mirror).unwrap();
    run_successfully(temp.path(), &["cache", "refresh", "2"]);
    assert!(!run_successfully(temp.path(), &["list", "--ready"]).contains("First"));
    let audit = run(temp.path(), &["check"]);
    assert_eq!(audit.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&audit.stdout).contains("RELATION_RECIPROCAL"));
    assert_eq!(fs::read_to_string(&path).unwrap(), without_mirror);

    // Either surviving half blocks conservatively without changing Markdown.
    fs::write(
        &path,
        record(2, "Second", "", "", "- **Blocking:**\n  - #0001 — First\n"),
    )
    .unwrap();
    fs::write(
        temp.path().join(".issues/0001-first.md"),
        record(1, "First", "", "", ""),
    )
    .unwrap();
    run_successfully(temp.path(), &["cache", "refresh"]);
    assert!(!run_successfully(temp.path(), &["list", "--ready"]).contains("First"));
    assert!(run_successfully(temp.path(), &["list", "--waiting-on", "2"]).contains("First"));
    let audit = run(temp.path(), &["check"]);
    assert_eq!(audit.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&audit.stdout).contains("RELATION_RECIPROCAL"));
}

#[test]
fn external_cycle_is_finite_in_tree_and_reported_by_audit() {
    let temp = fixture();
    run_successfully(temp.path(), &["list"]);
    let dir = temp.path().join(".issues");
    let first = record(
        1,
        "First",
        "",
        "- **Waiting on:**\n  - #0002 — Second\n    - **Reason:** Needed.\n",
        "- **Blocking:**\n  - #0002 — Second\n",
    );
    let second = record(
        2,
        "Second",
        "",
        "- **Waiting on:**\n  - #0001 — First\n    - **Reason:** External cycle.\n",
        "- **Blocking:**\n  - #0001 — First\n",
    );
    fs::write(dir.join("0001-first.md"), &first).unwrap();
    fs::write(dir.join("0002-second.md"), &second).unwrap();
    // Tree inspection itself refreshes the neighborhood, without a full refresh.
    let tree: serde_json::Value = serde_json::from_str(&run_successfully(
        temp.path(),
        &["wait", "tree", "1", "--json"],
    ))
    .unwrap();
    let issues = tree["issues"].as_array().unwrap();
    assert_eq!(issues.len(), 2);
    assert_eq!(issues[0]["waits_on"][0]["id"], "0002");
    assert_eq!(issues[1]["waits_on"][0]["id"], "0001");
    assert!(issues.iter().all(|issue| issue["ready"] == false));
    let audit = run(temp.path(), &["check"]);
    assert_eq!(audit.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&audit.stdout).contains("WAIT_CYCLE"));
    assert_eq!(
        fs::read_to_string(dir.join("0001-first.md")).unwrap(),
        first
    );
    assert_eq!(
        fs::read_to_string(dir.join("0002-second.md")).unwrap(),
        second
    );
}

#[test]
fn malformed_issue_is_reported_without_stale_metadata_or_lost_incoming_edges() {
    let temp = fixture();
    run_successfully(temp.path(), &["list"]);
    fs::write(temp.path().join(".issues/0002-second.md"), "bad record").unwrap();
    let refresh = run(temp.path(), &["cache", "refresh", "2"]);
    assert!(refresh.status.success());
    assert!(String::from_utf8_lossy(&refresh.stderr).contains("incomplete"));
    let listing = run(temp.path(), &["list"]);
    assert!(listing.status.success());
    assert!(!String::from_utf8_lossy(&listing.stdout).contains("Second"));
    assert!(String::from_utf8_lossy(&listing.stdout).contains("Third"));
    assert!(!run_successfully(temp.path(), &["list", "--ready"]).contains("First"));
    let db = rusqlite::Connection::open(temp.path().join(".issues/.cache/ledger.sqlite")).unwrap();
    let count: i64 = db
        .query_row(
            "SELECT count(*) FROM dependencies WHERE blocking_issue_id=2",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(count, 1);

    let output = run(temp.path(), &["snapshot"]);
    assert!(output.status.success());
    let view: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(view["unavailable"][0]["id"], "0002");
    assert_eq!(
        view["issues"][0]["warnings"][0]["code"],
        "RELATION_UNREADABLE"
    );
    assert_eq!(view["issues"][0]["ready"], false);
}

#[test]
fn repair_requires_an_existing_half_and_preserves_files_on_missing_reason() {
    let temp = fixture();
    let one = temp.path().join(".issues/0001-first.md");
    let two = temp.path().join(".issues/0002-second.md");
    let before = fs::read(&one).unwrap();
    let second = fs::read(&two).unwrap();
    let output = run(
        temp.path(),
        &[
            "wait",
            "repair",
            "complete",
            "3",
            "2",
            "--reason",
            "Unexpected",
        ],
    );
    assert!(!output.status.success());
    assert_eq!(fs::read(&one).unwrap(), before);
    assert_eq!(fs::read(&two).unwrap(), second);
    fs::write(&one, record(1, "First", "", "", "")).unwrap();
    let output = run(temp.path(), &["wait", "repair", "complete", "1", "2"]);
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("--reason"));
    assert_eq!(fs::read(&two).unwrap(), second);
    assert!(!temp.path().join(".issues/.cache/.isled-lock").exists());
}
