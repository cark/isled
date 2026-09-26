use std::fs;
use std::path::Path;
use std::process::{Command, Output};
use tempfile::TempDir;

fn run(root: &Path, arguments: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_isled"))
        .arg("--root")
        .arg(root)
        .args(arguments)
        .output()
        .expect("run isled")
}

fn ledger() -> TempDir {
    let root = tempfile::tempdir().expect("temporary ledger");
    for arguments in [
        vec!["init"],
        vec!["add", "--kind", "bug", "Target", "Original text."],
    ] {
        let output = run(root.path(), &arguments);
        assert!(output.status.success(), "{output:?}");
    }
    root
}

fn assert_failure(output: Output, diagnostic: &str) {
    assert_eq!(output.status.code(), Some(1));
    assert!(output.stdout.is_empty());
    let stderr = String::from_utf8(output.stderr).expect("UTF-8 error");
    assert!(stderr.contains(diagnostic), "{stderr}");
}

#[test]
fn show_preserves_bytes_without_requiring_markdown() {
    let root = ledger();
    let path = root.path().join(".issues/0001-target.md");
    let original = fs::read_to_string(&path).unwrap();
    for content in [
        String::new(),
        "Arbitrary café text\r\n\twithout a final newline".into(),
        original.replace("# 0001", "# 0002"),
        original.replace("**Status:** open", "**Status:** broken"),
    ] {
        fs::write(&path, &content).unwrap();
        let output = run(root.path(), &["show", "1"]);
        assert!(output.status.success(), "{output:?}");
        assert!(String::from_utf8_lossy(&output.stderr).contains("unreadable"));
        assert_eq!(output.stdout, content.as_bytes());
    }
}

#[test]
fn mutations_report_parse_errors_and_preserve_the_target() {
    let root = ledger();
    let path = root.path().join(".issues/0001-target.md");
    let original = fs::read_to_string(&path).unwrap();
    let counter = fs::read(root.path().join(".issues/.next-id")).unwrap();
    for (content, diagnostic) in [
        (
            "Broken record".into(),
            "invalid or out-of-order record sections",
        ),
        (
            original.replace("# 0001", "# 0002"),
            "invalid issue title heading",
        ),
        (
            original.replace("**Status:** open", "**Status:** broken"),
            "invalid Status field",
        ),
    ] {
        fs::write(&path, &content).unwrap();
        for arguments in [
            vec!["statement", "set", "1", "Replacement"],
            vec!["evidence", "add", "1", "Observed"],
            vec!["outcome", "set", "1", "Concluded"],
            vec!["tag", "add", "1", "rust"],
            vec!["tag", "remove", "1", "rust"],
            vec!["priority", "set", "1", "high"],
            vec!["priority", "clear", "1"],
            vec!["close", "1"],
        ] {
            assert_failure(run(root.path(), &arguments), diagnostic);
            assert_eq!(fs::read(&path).unwrap(), content.as_bytes());
            assert_eq!(
                fs::read(root.path().join(".issues/.next-id")).unwrap(),
                counter
            );
            assert!(!root.path().join(".issues/.cache/.isled-lock").exists());
        }
    }
}

#[test]
fn malformed_records_do_not_hide_duplicate_identities() {
    let root = ledger();
    let first = root.path().join(".issues/0001-target.md");
    let second = root.path().join(".issues/0001-z-other.md");
    let valid = fs::read(&first).unwrap();
    let broken = b"Broken record".to_vec();
    for (left, right) in [(&valid, &broken), (&broken, &valid), (&broken, &broken)] {
        fs::write(&first, left).unwrap();
        fs::write(&second, right).unwrap();
        for arguments in [
            vec!["show", "1"],
            vec!["statement", "set", "1", "Replacement"],
        ] {
            assert_failure(
                run(root.path(), &arguments),
                "multiple issue files found for 0001",
            );
            assert_eq!(fs::read(&first).unwrap(), *left);
            assert_eq!(fs::read(&second).unwrap(), *right);
        }
    }
}

#[test]
fn a_truly_absent_identity_still_reports_missing() {
    let root = ledger();
    for arguments in [
        vec!["show", "2"],
        vec!["statement", "set", "2", "Replacement"],
    ] {
        assert_failure(run(root.path(), &arguments), "issue not found: 0002");
    }
}
