use std::fs;
use std::path::Path;
use std::process::{Command, Output};

fn run(root: &Path, arguments: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_isled"))
        .arg("--root")
        .arg(root)
        .args(arguments)
        .output()
        .expect("run isled")
}

#[test]
fn handlers_validate_inputs_before_discovering_the_root_where_required() {
    let directory = tempfile::tempdir().unwrap();
    let missing = directory.path().join("missing");
    let cases: &[(&[&str], &str)] = &[
        (&["cache", "refresh", "bad"], "issue ID must be"),
        (&["wait", "show", "bad"], "issue ID must be"),
        (&["title", "set", "bad", "Title"], "issue ID must be"),
        (&["statement", "set", "bad", "Text"], "issue ID must be"),
        (&["evidence", "add", "bad", "Text"], "issue ID must be"),
        (&["outcome", "set", "bad", "Text"], "issue ID must be"),
        (&["tag", "add", "bad", "rust"], "issue ID must be"),
        (&["priority", "set", "bad", "high"], "issue ID must be"),
        (&["close", "bad"], "issue ID must be"),
        (
            &["add", "Title", "Text", "--kind", "INVALID"],
            "add requires a lowercase hyphenated --kind",
        ),
        (&["list", "--status", "invalid"], "invalid status"),
    ];
    for (arguments, message) in cases {
        let output = run(&missing, arguments);
        assert_eq!(output.status.code(), Some(1), "{arguments:?}");
        assert!(output.stdout.is_empty(), "{arguments:?}");
        let stderr = String::from_utf8(output.stderr).unwrap();
        assert!(stderr.contains(message), "{arguments:?}: {stderr}");
    }
    assert!(!missing.exists());
}

#[test]
fn show_and_path_discover_first_and_check_keeps_its_operational_exit() {
    let directory = tempfile::tempdir().unwrap();
    let missing = directory.path().join("missing");
    let ordinary = run(&missing, &["show", "1"]);
    assert_eq!(ordinary.status.code(), Some(1));
    assert!(ordinary.stdout.is_empty());
    assert!(!ordinary.stderr.is_empty());
    for arguments in [["show", "bad"], ["path", "bad"]] {
        let output = run(&missing, &arguments);
        assert_eq!(output.status.code(), Some(1));
        assert!(output.stdout.is_empty());
        assert_eq!(output.stderr, ordinary.stderr);
    }
    let check = run(&missing, &["check"]);
    assert_eq!(check.status.code(), Some(2));
    assert!(check.stdout.is_empty());
    assert_eq!(check.stderr, ordinary.stderr);
    assert!(!missing.exists());
}

fn locked_ledger() -> tempfile::TempDir {
    let temp = tempfile::tempdir().unwrap();
    fs::create_dir_all(temp.path().join(".issues/.cache/.isled-lock")).unwrap();
    fs::write(temp.path().join(".issues/.next-id"), b"2\n").unwrap();
    temp
}

// Separate fixtures let the test harness overlap independent lock timeouts.
#[test]
fn show_retains_missing_lookup_error_ahead_of_lock_failure() {
    let temp = locked_ledger();
    let missing = run(temp.path(), &["show", "1"]);
    assert!(String::from_utf8_lossy(&missing.stderr).contains("not found"));
}

#[test]
fn show_retains_encoding_error_ahead_of_lock_failure() {
    let temp = locked_ledger();
    fs::write(temp.path().join(".issues/0001-bad.md"), [0xff]).unwrap();
    let invalid = run(temp.path(), &["show", "1"]);
    assert!(String::from_utf8_lossy(&invalid.stderr).contains("UTF-8"));
}

#[test]
fn show_reports_lock_failure_for_inspectable_malformed_text() {
    let temp = locked_ledger();
    fs::write(
        temp.path().join(".issues/0001-bad.md"),
        "inspectable malformed text",
    )
    .unwrap();
    let locked = run(temp.path(), &["show", "1"]);
    assert!(String::from_utf8_lossy(&locked.stderr).contains("locked"));
}
