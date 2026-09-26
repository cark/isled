use std::fs;
use std::path::Path;
use std::process::{Command, Output};
use tempfile::TempDir;

fn root() -> TempDir {
    let root = tempfile::tempdir().unwrap();
    fs::create_dir(root.path().join(".issues")).unwrap();
    fs::write(root.path().join(".issues/.next-id"), b"3\n").unwrap();
    write(
        root.path(),
        "0001-source.md",
        "# 0001 — Source\n\n## Metadata\n\n- **Status:** open\n- **Kind:** feature\n- **Created:** 2026-09-04\n\n## Statement\n\nSource statement.\n\n## Evidence\n\n- Verified.\n\n## Outcome\n\nPending.\n",
    );
    write(
        root.path(),
        "0002-target.md",
        "# 0002 — Target\n\n## Metadata\n\n- **Status:** open\n- **Kind:** feature\n- **Created:** 2026-09-04\n\n## Statement\n\nTarget statement.\n\n## Evidence\n\n- Verified.\n\n## Outcome\n\nPending.\n",
    );
    root
}

fn write(root: &Path, filename: &str, content: &str) {
    fs::write(root.join(".issues").join(filename), content).unwrap();
}

fn run(root: &Path, arguments: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_isled"))
        .arg("--root")
        .arg(root)
        .args(arguments)
        .output()
        .unwrap()
}

#[test]
fn relations_are_mirrored_preserved_and_status_driven() {
    let root = root();
    assert!(
        run(root.path(), &["wait", "add", "1", "2", "Needed first."])
            .status
            .success()
    );
    let source = fs::read_to_string(root.path().join(".issues/0001-source.md")).unwrap();
    let target = fs::read_to_string(root.path().join(".issues/0002-target.md")).unwrap();
    assert!(
        source.contains("- **Waiting on:**\n  - #0002 — Target\n    - **Reason:** Needed first.")
    );
    assert!(target.contains("- **Blocking:**\n  - #0001 — Source"));
    assert_eq!(
        String::from_utf8(run(root.path(), &["list", "--ready"]).stdout).unwrap(),
        "0002\topen\tfeature\tTarget\n"
    );

    assert!(
        run(root.path(), &["title", "set", "1", "Renamed source"])
            .status
            .success()
    );
    let target = fs::read_to_string(root.path().join(".issues/0002-target.md")).unwrap();
    assert!(target.contains("#0001 — Renamed source"));

    assert!(
        run(root.path(), &["close", "--outcome", "Implemented.", "2"])
            .status
            .success()
    );
    let source = fs::read_to_string(root.path().join(".issues/0001-source.md")).unwrap();
    let target = fs::read_to_string(root.path().join(".issues/0002-target.md")).unwrap();
    assert!(source.contains("#0002 — Target"));
    assert!(target.contains("#0001 — Renamed source"));
    assert_eq!(
        String::from_utf8(run(root.path(), &["list", "--ready"]).stdout).unwrap(),
        "0001\topen\tfeature\tRenamed source\n"
    );
    assert!(run(root.path(), &["check"]).status.success());

    assert!(
        run(root.path(), &["wait", "remove", "1", "2"])
            .status
            .success()
    );
    assert!(
        !fs::read_to_string(root.path().join(".issues/0001-source.md"))
            .unwrap()
            .contains("Waiting on")
    );
    assert!(
        !fs::read_to_string(root.path().join(".issues/0002-target.md"))
            .unwrap()
            .contains("Blocking")
    );
}

#[test]
fn check_reports_stale_and_unmirrored_relations() {
    let root = root();
    let source = "# 0001 — Source\n\n## Metadata\n\n- **Status:** open\n- **Kind:** feature\n- **Created:** 2026-09-04\n- **Waiting on:**\n  - #0002 — Old target\n    - **Reason:** Needed.\n\n## Statement\n\nSource.\n\n## Evidence\n\n- Pending.\n\n## Outcome\n\nPending.\n";
    write(root.path(), "0001-source.md", source);
    let output = run(root.path(), &["check"]);
    assert_eq!(output.status.code(), Some(1));
    let findings = String::from_utf8(output.stdout).unwrap();
    assert!(findings.contains("RELATION_TITLE"));
    assert!(findings.contains("RELATION_RECIPROCAL"));
}

#[test]
fn check_accumulates_independent_findings_without_changing_files() {
    let root = root();
    let ledger = root.path().join(".issues");
    let source = fs::read_to_string(ledger.join("0001-source.md"))
        .unwrap()
        .replace(
            "\n\n## Statement",
            "\n- **Waiting on:**\n  - #0009 — Missing\n    - **Reason:** Needed.\n\n## Statement",
        );
    let target = fs::read_to_string(ledger.join("0002-target.md"))
        .unwrap()
        .replace("**Status:** open", "**Status:** closed")
        .replace(
            "\n\n## Statement",
            "\n- **Tags:** priority-high\n\n## Statement",
        )
        .replace("- Verified.", "- Pending.");
    write(root.path(), "0001-source.md", &source);
    write(root.path(), "0002-target.md", &target);
    fs::write(ledger.join(".next-id"), b"1\n").unwrap();
    let before: Vec<_> = [".next-id", "0001-source.md", "0002-target.md"]
        .map(|name| (name, fs::read(ledger.join(name)).unwrap()))
        .into();

    let output = run(root.path(), &["check"]);
    assert_eq!(output.status.code(), Some(1));
    assert!(output.stderr.is_empty());
    assert_eq!(
        String::from_utf8(output.stdout).unwrap(),
        concat!(
            ".next-id\tNEXT_ID_BEHIND\t.next-id is 1; expected at least 3\n",
            "0001-source.md\tWAIT_MISSING_TARGET\twait target 0009 does not exist\n",
            "0002-target.md\tCLOSED_PRIORITY\tclosed issue retains a priority tag\n",
            "0002-target.md\tEVIDENCE_PENDING\tclosed issue retains pending evidence\n",
            "0002-target.md\tOUTCOME_PENDING\tclosed issue retains pending outcome\n",
        )
    );
    assert_eq!(fs::read_dir(&ledger).unwrap().count(), before.len());
    for (name, bytes) in before {
        assert_eq!(fs::read(ledger.join(name)).unwrap(), bytes);
    }
}
