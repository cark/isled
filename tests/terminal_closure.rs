use std::fs;
use std::path::Path;
use std::process::{Command, Output};

const CLOSED_RECORD: &[u8] = b"# 0001 \xe2\x80\x94 Finished before\n\nStatus: closed\nKind: feature\nCreated: 2026-09-03\nTag: rust\n\nOriginal statement.\n\nEvidence:\n- Tests passed.\n\nOutcome:\n- Implemented previously.\n";

fn run(root: &Path, arguments: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_isled"))
        .arg("--root")
        .arg(root)
        .args(arguments)
        .output()
        .expect("run isled")
}

#[test]
fn reopen_is_absent_and_cannot_change_a_closed_record() {
    let root = tempfile::tempdir().expect("temporary project");
    let issues = root.path().join(".issues");
    fs::create_dir(&issues).expect("create issue store");
    fs::write(issues.join(".next-id"), b"2\n").expect("write counter");
    let record = issues.join("0001-finished-before.md");
    fs::write(&record, CLOSED_RECORD).expect("write record");

    let output = run(root.path(), &["reopen", "0001"]);

    assert_eq!(output.status.code(), Some(1));
    assert!(output.stdout.is_empty());
    assert!(String::from_utf8_lossy(&output.stderr).contains("unrecognized subcommand 'reopen'"));
    assert_eq!(fs::read(record).expect("read record"), CLOSED_RECORD);
    assert!(!issues.join(".cache/.isled-lock").exists());
}

#[test]
fn top_level_help_does_not_advertise_reopening() {
    let output = Command::new(env!("CARGO_BIN_EXE_isled"))
        .arg("--help")
        .output()
        .expect("run top-level help");

    assert_eq!(output.status.code(), Some(0));
    assert!(output.stderr.is_empty());
    assert!(!String::from_utf8_lossy(&output.stdout).contains("reopen"));
}

#[test]
fn close_help_explains_terminal_lifecycle() {
    let output = Command::new(env!("CARGO_BIN_EXE_isled"))
        .args(["close", "--help"])
        .output()
        .expect("run close help");

    assert_eq!(output.status.code(), Some(0));
    assert!(output.stderr.is_empty());
    let help = String::from_utf8_lossy(&output.stdout);
    assert!(help.contains("Closure is terminal"));
    assert!(help.contains("add a new issue"));
}
