use std::fs;
use std::path::Path;
use std::process::{Command, Output};
use tempfile::TempDir;

const WARNING: &[u8] = b"warning: issue 0001 is closed; updating historical record\n";

fn record(id: u16, status: &str, relations: &str) -> String {
    format!(
        "# {id:04} — Original\n\n## Metadata\n\n- **Status:** {status}\n- **Kind:** bug\n- **Created:** 2026-09-05\n{relations}\n## Statement\n\nOriginal.\n\n## Evidence\n\n- Verified.\n\n## Outcome\n\nDone.\n"
    )
}

fn fixture(status: &str) -> TempDir {
    let root = tempfile::tempdir().unwrap();
    fs::create_dir(root.path().join(".issues")).unwrap();
    fs::write(root.path().join(".issues/.next-id"), b"3\n").unwrap();
    fs::write(
        root.path().join(".issues/0001-original.md"),
        record(1, status, ""),
    )
    .unwrap();
    root
}

fn run(root: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_isled"))
        .arg("--root")
        .arg(root)
        .args(args)
        .output()
        .unwrap()
}

#[test]
fn all_content_commands_warn_only_for_successful_closed_changes() {
    for status in ["open", "closed"] {
        for (command, action, stdout, changed) in [
            (
                "title",
                "set",
                "set title for issue 0001\n",
                "# 0001 — New text",
            ),
            (
                "statement",
                "set",
                "set statement for issue 0001\n",
                "## Statement\n\nNew text\n",
            ),
            (
                "statement",
                "append",
                "appended statement to issue 0001\n",
                "Original.\n\nNew text\n",
            ),
            (
                "evidence",
                "add",
                "added evidence to issue 0001\n",
                "- Verified.\n- New text\n",
            ),
            (
                "outcome",
                "set",
                "set outcome for issue 0001\n",
                "## Outcome\n\nNew text\n",
            ),
        ] {
            let root = fixture(status);
            let output = run(root.path(), &[command, action, "#1", "New text"]);
            assert!(output.status.success(), "{command} {action}: {output:?}");
            assert_eq!(output.stdout, stdout.as_bytes());
            assert_eq!(
                output.stderr,
                if status == "closed" { WARNING } else { b"" }
            );
            let content = fs::read_to_string(root.path().join(".issues/0001-original.md")).unwrap();
            assert!(content.contains(changed), "{content}");
            assert!(run(root.path(), &["check"]).status.success());
        }
    }
}

#[test]
fn closed_no_ops_do_not_warn() {
    for (command, text) in [
        ("title", "Original"),
        ("statement", "Original."),
        ("outcome", "Done."),
    ] {
        let root = fixture("closed");
        let path = root.path().join(".issues/0001-original.md");
        let before = fs::read(&path).unwrap();
        let output = run(root.path(), &[command, "set", "1", text]);
        assert!(output.status.success());
        assert!(output.stderr.is_empty(), "{output:?}");
        assert_eq!(fs::read(path).unwrap(), before);
    }
}

#[test]
fn rejected_content_commands_do_not_emit_a_success_warning() {
    for (command, action) in [
        ("title", "set"),
        ("statement", "set"),
        ("statement", "append"),
        ("evidence", "add"),
        ("outcome", "set"),
    ] {
        let root = fixture("closed");
        let path = root.path().join(".issues/0001-original.md");
        let before = fs::read(&path).unwrap();
        let output = run(root.path(), &[command, action, "1", ""]);
        assert!(!output.status.success());
        assert!(output.stdout.is_empty());
        assert!(!String::from_utf8_lossy(&output.stderr).contains("warning:"));
        assert_eq!(fs::read(path).unwrap(), before);
    }
}

#[test]
fn renamed_issue_alone_determines_warning_even_with_a_closed_neighbor() {
    for status in ["open", "closed"] {
        let root = fixture(status);
        let ledger = root.path().join(".issues");
        fs::write(
            ledger.join("0001-original.md"),
            record(
                1,
                status,
                "- **Waiting on:**\n  - #0002 — Original\n    - **Reason:** Needed.\n",
            ),
        )
        .unwrap();
        fs::write(
            ledger.join("0002-original.md"),
            record(2, "closed", "- **Blocking:**\n  - #0001 — Original\n"),
        )
        .unwrap();
        let output = run(root.path(), &["title", "set", "1", "Renamed"]);
        assert!(output.status.success(), "{output:?}");
        assert_eq!(output.stdout, b"set title for issue 0001\n");
        assert_eq!(
            output.stderr,
            if status == "closed" { WARNING } else { b"" }
        );
        assert!(
            fs::read_to_string(ledger.join("0002-original.md"))
                .unwrap()
                .contains("#0001 — Renamed")
        );
        assert!(run(root.path(), &["check"]).status.success());
    }
}

#[test]
fn each_content_leaf_documents_the_warning_without_project_discovery() {
    for (command, action) in [
        ("title", "set"),
        ("statement", "set"),
        ("statement", "append"),
        ("evidence", "add"),
        ("outcome", "set"),
    ] {
        let root = tempfile::tempdir().unwrap();
        let output = run(root.path(), &[command, action, "--help"]);
        assert!(output.status.success());
        assert!(output.stderr.is_empty());
        let help = String::from_utf8(output.stdout).unwrap();
        for expected in ["explicitly selected", "stderr", "no-ops", "copied-title"] {
            assert!(help.contains(expected), "{command} {action}: {help}");
        }
    }
}
