use std::fs;
use std::path::Path;
use std::process::{Command, Output};
use tempfile::TempDir;

fn initialized_root() -> TempDir {
    let root = tempfile::tempdir().expect("temporary project");
    let issues = root.path().join(".issues");
    fs::create_dir(&issues).expect("create issue store");
    fs::write(issues.join(".next-id"), b"4\n").expect("write counter");
    fs::write(
        issues.join("0001-alpha.md"),
        b"# 0001 \xe2\x80\x94 Alpha\n\n## Metadata\n\n- **Status:** open\n- **Kind:** feature\n- **Created:** 2026-09-03\n- **Tags:** needs-design, priority-high\n- **Waiting on:**\n  - #0002 \xe2\x80\x94 Beta\n    - **Reason:** Needs beta.\n\n## Statement\n\nAlpha statement.\n\n## Evidence\n\n- Pending.\n\n## Outcome\n\nPending.\n",
    )
    .expect("write alpha");
    fs::write(
        issues.join("0002-beta.md"),
        b"# 0002 \xe2\x80\x94 Beta\n\n## Metadata\n\n- **Status:** open\n- **Kind:** feature\n- **Created:** 2026-09-03\n- **Blocking:**\n  - #0001 \xe2\x80\x94 Alpha\n\n## Statement\n\nBeta statement.\n\n## Evidence\n\n- Recorded.\n\n## Outcome\n\nRecorded.\n",
    )
    .expect("write beta");
    fs::write(
        issues.join("0003-gamma.md"),
        b"# 0003 \xe2\x80\x94 Gamma\n\n## Metadata\n\n- **Status:** open\n- **Kind:** feature\n- **Created:** 2026-09-03\n\n## Statement\n\nGamma statement.\n\n## Evidence\n\n- Pending.\n\n## Outcome\n\nPending.\n",
    )
    .expect("write gamma");
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
fn every_cli_id_position_accepts_ergonomic_spelling_and_renders_canonically() {
    let cases = vec![
        vec!["show", "1"],
        vec!["path", "#1", "02", "#0003"],
        vec!["list", "--all", "--waiting-on", "2"],
        vec!["search", "--waiting-on", "#02", "Alpha"],
        vec!["wait", "show", "#1"],
        vec!["wait", "tree", "#1"],
        vec!["wait", "add", "01", "#3", "Also needs gamma."],
        vec!["wait", "remove", "#0001", "2"],
        vec!["tag", "add", "1", "reviewed"],
        vec!["tag", "remove", "#01", "needs-design"],
        vec!["priority", "set", "001", "normal"],
        vec!["priority", "clear", "#1"],
        vec!["statement", "set", "01", "Replacement."],
        vec!["statement", "append", "#001", "Supporting paragraph."],
        vec!["evidence", "add", "1", "Verified."],
        vec!["outcome", "set", "#0001", "Accepted."],
        vec!["close", "2"],
    ];

    for arguments in cases {
        let root = initialized_root();
        let output = run(root.path(), &arguments);
        assert_eq!(
            output.status.code(),
            Some(0),
            "arguments: {arguments:?}; stderr: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(output.stderr.is_empty(), "arguments: {arguments:?}");
        let stdout = String::from_utf8(output.stdout).expect("UTF-8 output");
        assert!(
            stdout.contains("0001") || stdout.contains("0002"),
            "arguments: {arguments:?}; stdout: {stdout}"
        );
    }
}

#[test]
fn cli_rejects_non_id_spellings_with_one_actionable_diagnostic() {
    let root = initialized_root();
    for invalid in [
        "#", "0", "0000", "#0000", "00001", "#00001", "+1", "1.0", "issue-1", "\u{0661}",
    ] {
        let output = run(root.path(), &["show", invalid]);
        assert_eq!(output.status.code(), Some(1), "input: {invalid:?}");
        assert!(output.stdout.is_empty(), "input: {invalid:?}");
        let stderr = String::from_utf8(output.stderr).expect("UTF-8 diagnostic");
        assert_eq!(
            stderr,
            format!(
                "isled: issue ID must be 1-4 ASCII digits, optionally prefixed by # (1-9999): {invalid}\n"
            )
        );
    }
}
