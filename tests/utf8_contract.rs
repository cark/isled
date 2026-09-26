use std::fs;
use std::path::Path;
use std::process::{Command, Output};
use tempfile::TempDir;

const VALID_RECORD: &[u8] = b"# 0001 \xe2\x80\x94 Valid\n\n## Metadata\n\n- **Status:** open\n- **Kind:** feature\n- **Created:** 2026-09-03\n\n## Statement\n\nCaf\xc3\xa9.\n\n## Evidence\n\n- Pending.\n\n## Outcome\n\nPending.\n";

fn initialized_root() -> TempDir {
    let root = tempfile::tempdir().expect("temporary project");
    fs::create_dir(root.path().join(".issues")).expect("create issue store");
    fs::write(root.path().join(".issues/.next-id"), b"3\n").expect("write counter");
    fs::write(root.path().join(".issues/0001-valid.md"), VALID_RECORD).expect("write valid record");
    root
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
fn command_scope_isolates_unrelated_invalid_prose() {
    let root = initialized_root();
    let invalid_path = root.path().join(".issues/0002-invalid-content.md");
    let invalid = b"# 0002 \xe2\x80\x94 Invalid\n\n## Metadata\n\n- **Status:** open\n- **Kind:** feature\n- **Created:** 2026-09-03\n\n## Statement\n\nBad \xff text.\n\n## Evidence\n\n- Pending.\n\n## Outcome\n\nPending.\n";
    fs::write(&invalid_path, invalid).expect("write invalid record");

    for arguments in [
        vec!["list"],
        vec!["show", "0001"],
        vec!["path", "0002"],
        vec!["wait", "show", "0001"],
        vec!["title", "set", "0001", "Updated title"],
        vec!["statement", "set", "0001", "Updated statement."],
        vec!["evidence", "add", "0001", "Observed."],
        vec!["outcome", "set", "0001", "Accepted."],
        vec!["tag", "add", "0001", "rust"],
        vec!["priority", "set", "0001", "high"],
        vec![
            "add",
            "--kind",
            "feature",
            "Created after corruption",
            "Created without reading unrelated prose.",
        ],
    ] {
        let output = run(root.path(), &arguments);
        assert_eq!(output.status.code(), Some(0), "arguments: {arguments:?}");
        assert!(
            String::from_utf8_lossy(&output.stderr).contains("unreadable"),
            "arguments: {arguments:?}"
        );
    }

    for arguments in [vec!["show", "0002"], vec!["search", "Valid"]] {
        let output = run(root.path(), &arguments);
        assert_eq!(output.status.code(), Some(1), "arguments: {arguments:?}");
        assert!(output.stdout.is_empty(), "arguments: {arguments:?}");
        assert!(
            String::from_utf8_lossy(&output.stderr)
                .contains("0002-invalid-content.md: issue record is not valid UTF-8"),
            "arguments: {arguments:?}; stderr: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    let snapshot = run(root.path(), &["snapshot"]);
    assert!(snapshot.status.success());
    let view: serde_json::Value = serde_json::from_slice(&snapshot.stdout).unwrap();
    assert_eq!(view["unavailable"][0]["id"], "0002");
    assert!(
        view["unavailable"][0]["error"]
            .as_str()
            .unwrap()
            .contains("UTF-8")
    );

    assert_eq!(
        fs::read(&invalid_path).expect("read invalid record"),
        invalid
    );
    let target = fs::read(root.path().join(".issues/0001-valid.md")).expect("read valid record");
    assert!(target.starts_with(b"# 0001 \xe2\x80\x94 Updated title\n"));
    assert!(
        target
            .windows(b"Updated statement.".len())
            .any(|part| part == b"Updated statement.")
    );
    assert!(
        target
            .windows(b"priority-high".len())
            .any(|part| part == b"priority-high")
    );
    assert!(target.windows(b"rust".len()).any(|part| part == b"rust"));
    assert!(
        target
            .windows(b"- Observed.".len())
            .any(|part| part == b"- Observed.")
    );
    assert!(
        target
            .windows(b"Accepted.".len())
            .any(|part| part == b"Accepted.")
    );
    assert!(!root.path().join(".issues/.cache/.isled-lock").exists());

    let check = run(root.path(), &["check"]);
    assert_eq!(check.status.code(), Some(1));
    assert!(check.stderr.is_empty());
    let findings = String::from_utf8(check.stdout).expect("UTF-8 check findings");
    assert!(
        findings
            .contains("0002-invalid-content.md\tCONTENT_UTF8\tissue record is not valid UTF-8\n")
    );
}

#[test]
fn relation_mutations_read_headers_and_participating_records() {
    let root = initialized_root();
    let invalid = b"# 0002 \xe2\x80\x94 Invalid\n\n## Metadata\n\n- **Status:** open\n- **Kind:** feature\n- **Created:** 2026-09-03\n\n## Statement\n\nBad \xff text.\n\n## Evidence\n\n- Pending.\n\n## Outcome\n\nPending.\n";
    let blocker = b"# 0003 \xe2\x80\x94 Blocker\n\n## Metadata\n\n- **Status:** open\n- **Kind:** feature\n- **Created:** 2026-09-03\n\n## Statement\n\nReady to close.\n\n## Evidence\n\n- Implemented.\n\n## Outcome\n\nPending.\n";
    fs::write(root.path().join(".issues/0002-invalid-content.md"), invalid)
        .expect("write invalid record");
    fs::write(root.path().join(".issues/0003-blocker.md"), blocker).expect("write blocker record");
    fs::write(root.path().join(".issues/.next-id"), b"4\n").expect("update counter");

    let add = run(
        root.path(),
        &["wait", "add", "0001", "0003", "Needs blocker."],
    );
    assert_eq!(add.status.code(), Some(0));
    assert!(String::from_utf8_lossy(&add.stderr).contains("unreadable"));

    let close = run(root.path(), &["close", "--outcome", "Completed.", "0003"]);
    assert_eq!(close.status.code(), Some(0));
    assert!(String::from_utf8_lossy(&close.stderr).contains("unreadable"));

    assert_eq!(
        fs::read(root.path().join(".issues/0002-invalid-content.md")).expect("read invalid record"),
        invalid
    );
    let source = fs::read(root.path().join(".issues/0001-valid.md")).expect("read source");
    assert!(
        !source
            .windows(b"Waits: ".len())
            .any(|part| part == b"Waits: ")
    );
    let blocker = fs::read(root.path().join(".issues/0003-blocker.md")).expect("read blocker");
    assert!(
        blocker
            .windows(b"**Status:** closed".len())
            .any(|part| part == b"**Status:** closed")
    );
}

#[cfg(unix)]
#[test]
fn invalid_filename_is_escaped_in_recovery_output() {
    use std::ffi::OsString;
    use std::os::unix::ffi::OsStringExt;

    let root = initialized_root();
    let invalid_name = OsString::from_vec(b"0002-bad-\xff.md".to_vec());
    fs::write(root.path().join(".issues").join(invalid_name), VALID_RECORD)
        .expect("write invalid filename");

    let list = run(root.path(), &["list"]);
    assert_eq!(list.status.code(), Some(0));
    assert!(String::from_utf8_lossy(&list.stdout).contains("Valid"));
    assert!(String::from_utf8_lossy(&list.stderr).contains("invalid UTF-8 filename"));

    let check = run(root.path(), &["check"]);
    assert_eq!(check.status.code(), Some(1));
    assert!(check.stderr.is_empty());
    let findings = String::from_utf8(check.stdout).expect("escaped UTF-8 findings");
    assert!(
        findings.contains("0002-bad-\\xFF.md\tFILENAME_UTF8\tissue filename is not valid UTF-8\n")
    );
}
