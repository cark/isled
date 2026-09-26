//! Disposable ledger data and bounded CLI execution shared by cache tests.
use isled::issue::IssueId;
use std::{
    fs,
    path::Path,
    process::{Command, Output},
};

pub(super) fn record(id: u16, title: &str, tags: &str, waits: &str, blocking: &str) -> String {
    format!(
        "# {id:04} — {title}\n\n## Metadata\n\n- **Status:** open\n- **Kind:** feature\n- **Created:** 2026-09-05\n{tags}{waits}{blocking}\n## Statement\n\nBody.\n\n## Evidence\n\n- Observed.\n\n## Outcome\n\nPending.\n"
    )
}
pub(super) fn fixture() -> tempfile::TempDir {
    let temp = tempfile::tempdir().unwrap();
    let dir = temp.path().join(".issues");
    fs::create_dir(&dir).unwrap();
    fs::write(dir.join(".next-id"), "4\n").unwrap();
    fs::write(
        dir.join("0001-first.md"),
        record(
            1,
            "First",
            "- **Tags:** rust\n",
            "- **Waiting on:**\n  - #0002 — Second\n    - **Reason:** Needed.\n",
            "",
        ),
    )
    .unwrap();
    fs::write(
        dir.join("0002-second.md"),
        record(2, "Second", "", "", "- **Blocking:**\n  - #0001 — First\n"),
    )
    .unwrap();
    fs::write(dir.join("0003-third.md"), record(3, "Third", "", "", "")).unwrap();
    temp
}
pub(super) fn run(root: &Path, args: &[&str]) -> Output {
    let mut child = Command::new(env!("CARGO_BIN_EXE_isled"))
        .arg("--root")
        .arg(root)
        .args(args)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    while child.try_wait().unwrap().is_none() {
        if std::time::Instant::now() >= deadline {
            child.kill().unwrap();
            child.wait().unwrap();
            panic!("command timed out (possible deadlock): {args:?}");
        }
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    child.wait_with_output().unwrap()
}
pub(super) fn run_successfully(root: &Path, args: &[&str]) -> String {
    let out = run(root, args);
    assert!(out.status.success(), "{args:?}: {out:?}");
    String::from_utf8(out.stdout).unwrap()
}
pub(super) fn id(n: u16) -> IssueId {
    IssueId::new(n).unwrap()
}
