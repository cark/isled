use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use tempfile::TempDir;

const RECORD: &[u8] = b"# 0001 \xe2\x80\x94 Original title\n\n## Metadata\n\n- **Status:** open\n- **Kind:** feature\n- **Created:** 2026-09-03\n- **Tags:** priority-high\n\n## Statement\n\nOriginal statement.\n\n## Evidence\n\n- Pending.\n\n## Outcome\n\nPending.\n";
const CLOSED_RECORD: &[u8] = b"# 0001 \xe2\x80\x94 Original title\n\n## Metadata\n\n- **Status:** closed\n- **Kind:** feature\n- **Created:** 2026-09-03\n\n## Statement\n\nOriginal statement.\n\n## Evidence\n\n- Recorded.\n\n## Outcome\n\nRecorded.\n";

fn initialized_root() -> (TempDir, PathBuf) {
    let root = tempfile::tempdir().expect("temporary project");
    let issues = root.path().join(".issues");
    fs::create_dir(&issues).expect("create issue store");
    fs::write(issues.join(".next-id"), b"2\n").expect("write counter");
    let record = issues.join("0001-original-title.md");
    fs::write(&record, RECORD).expect("write record");
    (root, record)
}

fn run(root: &Path, arguments: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_isled"))
        .arg("--root")
        .arg(root)
        .args(arguments)
        .output()
        .expect("run isled")
}

#[test]
fn title_set_changes_only_semantic_title_and_preserves_stable_path() {
    let (root, record) = initialized_root();
    let original_suffix = &RECORD[RECORD.iter().position(|byte| *byte == b'\n').unwrap()..];

    let output = run(root.path(), &["title", "set", "#1", "Renamed café"]);
    assert_eq!(output.status.code(), Some(0));
    assert_eq!(output.stdout, b"set title for issue 0001\n");
    assert!(output.stderr.is_empty());

    assert!(record.exists());
    assert!(!root.path().join(".issues/0001-renamed-cafe.md").exists());
    let changed = fs::read(&record).expect("read renamed record");
    assert!(changed.starts_with("# 0001 — Renamed café\n".as_bytes()));
    let changed_suffix = &changed[changed.iter().position(|byte| *byte == b'\n').unwrap()..];
    assert_eq!(changed_suffix, original_suffix);

    let snapshot = run(root.path(), &["snapshot"]);
    assert_eq!(snapshot.status.code(), Some(0));
    let value: Value = serde_json::from_slice(&snapshot.stdout).expect("snapshot JSON");
    assert_eq!(value["issues"][0]["title"]["value"], "Renamed café");
    assert_eq!(
        value["issues"][0]["path"]["value"],
        record.to_str().expect("UTF-8 temporary path")
    );
    let check = run(root.path(), &["check"]);
    assert_eq!(check.status.code(), Some(0));
    assert!(check.stdout.is_empty());
    assert!(check.stderr.is_empty());
}

#[cfg(unix)]
#[test]
fn setting_the_current_title_succeeds_without_rewriting_the_record() {
    use std::os::unix::fs::MetadataExt;

    let (root, record) = initialized_root();
    let inode = fs::metadata(&record).expect("record metadata").ino();
    let output = run(root.path(), &["title", "set", "1", "Original title"]);

    assert_eq!(output.status.code(), Some(0));
    assert_eq!(output.stdout, b"set title for issue 0001\n");
    assert!(output.stderr.is_empty());
    assert_eq!(fs::metadata(&record).expect("record metadata").ino(), inode);
    assert_eq!(fs::read(&record).expect("read record"), RECORD);
}

#[test]
fn invalid_title_fails_without_changing_the_record() {
    for title in ["", "two\nlines", "tab\ttitle"] {
        let (root, record) = initialized_root();
        let output = run(root.path(), &["title", "set", "1", title]);
        assert_eq!(output.status.code(), Some(1), "title: {title:?}");
        assert!(output.stdout.is_empty(), "title: {title:?}");
        assert_eq!(
            output.stderr, b"isled: title must be one non-empty line without tabs\n",
            "title: {title:?}"
        );
        assert_eq!(fs::read(&record).expect("read record"), RECORD);
        assert!(!root.path().join(".issues/.cache/.isled-lock").exists());
    }
}

#[test]
fn closed_issue_title_remains_editable() {
    let (root, record) = initialized_root();
    fs::write(&record, CLOSED_RECORD).expect("write closed record");

    let output = run(root.path(), &["title", "set", "1", "Closed title"]);
    assert_eq!(output.status.code(), Some(0));
    assert_eq!(output.stdout, b"set title for issue 0001\n");
    assert!(
        fs::read(record)
            .expect("read record")
            .starts_with(b"# 0001 \xe2\x80\x94 Closed title\n")
    );
}

#[test]
fn title_help_documents_identity_and_no_op_contracts_without_a_project() {
    let namespace = Command::new(env!("CARGO_BIN_EXE_isled"))
        .args(["title", "--help"])
        .output()
        .expect("run title help");
    assert_eq!(namespace.status.code(), Some(0));
    assert!(String::from_utf8_lossy(&namespace.stdout).contains("creation-time filename slug"));

    let set = Command::new(env!("CARGO_BIN_EXE_isled"))
        .args(["title", "set", "--help"])
        .output()
        .expect("run title set help");
    assert_eq!(set.status.code(), Some(0));
    let help = String::from_utf8_lossy(&set.stdout);
    for expected in [
        "1-4 digits, optional #",
        "Stable IDs, filenames, slugs, relation meaning, and prose remain unchanged",
        "without rewriting the record",
    ] {
        assert!(help.contains(expected), "missing {expected:?} in {help}");
    }
}
