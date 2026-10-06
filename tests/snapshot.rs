use serde_json::Value;
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

fn write_record(root: &Path, filename: &str, bytes: &[u8]) {
    fs::write(root.join(".issues").join(filename), bytes).expect("write issue record");
}

fn initialized_root() -> TempDir {
    let root = tempfile::tempdir().expect("temporary project");
    fs::create_dir(root.path().join(".issues")).expect("create ledger");
    fs::write(root.path().join(".issues/.next-id"), b"2\n").expect("write counter");
    root
}

fn record(id: &str, status: &str, title: &str, metadata: &str, statement: &str) -> String {
    format!(
        "# {id} — {title}\n\n## Metadata\n\n- **Status:** {status}\n- **Kind:** feature\n- **Created:** 2026-09-03\n{metadata}\n## Statement\n\n{statement}\n\n## Evidence\n\n- Recorded.\n\n## Outcome\n\nRecorded.\n"
    )
}

#[test]
fn empty_snapshot_has_a_stable_versioned_shape() {
    let root = initialized_root();

    let output = run(root.path(), &["snapshot"]);

    assert!(output.status.success());
    assert!(output.stderr.is_empty());
    let value: Value = serde_json::from_slice(&output.stdout).expect("valid JSON");
    assert_eq!(value["schema_version"], 4);
    assert_eq!(value["root"]["encoding"], "utf-8");
    let canonical_root = root.path().canonicalize().expect("canonical root");
    assert_eq!(
        value["root"]["value"],
        canonical_root.to_str().expect("UTF-8 temporary path")
    );
    assert_eq!(value["issues"], serde_json::json!([]));
    assert_eq!(value["unavailable"], serde_json::json!([]));
}

#[cfg(unix)]
#[test]
fn unreadable_file_reports_the_actual_io_error_and_keeps_other_issues() {
    use std::os::unix::fs::PermissionsExt;
    let root = initialized_root();
    write_record(
        root.path(),
        "0001-first.md",
        record("0001", "open", "First", "", "Text.").as_bytes(),
    );
    write_record(
        root.path(),
        "0002-second.md",
        record("0002", "open", "Second", "", "Text.").as_bytes(),
    );
    let path = root.path().join(".issues/0002-second.md");
    fs::set_permissions(&path, fs::Permissions::from_mode(0o0)).unwrap();
    let read = fs::read(&path);
    let output = run(root.path(), &["snapshot"]);
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
    if let Err(error) = read {
        // Privileged test runners can bypass mode bits.
        assert!(output.status.success(), "{output:?}");
        let view: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(view["issues"].as_array().unwrap().len(), 1);
        assert_eq!(view["unavailable"][0]["id"], "0002");
        assert_eq!(view["unavailable"][0]["error"], error.to_string());
    }
}

#[test]
fn snapshot_is_ordered_readable_and_lossless() {
    let root = initialized_root();
    let closed = record("0002", "closed", "Closed", "", "Done.")
        .replace("**Kind:** feature", "**Kind:** custom-kind-2");
    let utf8 = record("0001", "open", "Unicode", "", "Café.");
    write_record(root.path(), "0002-closed.md", closed.as_bytes());
    write_record(root.path(), "0001-unicode.md", utf8.as_bytes());

    let output = run(root.path(), &["snapshot"]);

    assert!(output.status.success());
    assert!(output.stderr.is_empty());
    let value: Value = serde_json::from_slice(&output.stdout).expect("valid JSON");
    assert_eq!(value["schema_version"], 4);
    assert_eq!(value["root"]["encoding"], "utf-8");
    assert_eq!(value["issues"][0]["id"], "0001");
    assert_eq!(value["issues"][1]["id"], "0002");
    assert_eq!(value["issues"][0]["kind"], "feature");
    assert_eq!(value["issues"][1]["kind"], "custom-kind-2");
    assert_eq!(value["issues"][0]["ready"], true);
    assert_eq!(value["issues"][1]["ready"], false);
    assert_eq!(value["issues"][0]["title"]["value"], "Unicode");
    assert_eq!(value["issues"][0]["content"]["encoding"], "utf-8");
    assert_eq!(value["issues"][0]["content"]["value"], utf8);
    assert_eq!(value["issues"][1]["content"]["encoding"], "utf-8");
}

#[test]
fn snapshot_exposes_typed_inline_references_with_file_relative_offsets() {
    let root = initialized_root();
    let first = "# 0001 — First\n\n## Metadata\n\n- **Status:** open\n- **Kind:** feature\n- **Created:** 2026-09-03\n\n## Statement\n\nCafé #2 and #0002.\n\n## Evidence\n\n- Missing #3.\n\n## Outcome\n\nKeep [linked #2](issue.md) inert.\n";
    let second = record("0002", "open", "Second", "", "No references.");
    write_record(root.path(), "0001-first.md", first.as_bytes());
    write_record(root.path(), "0002-second.md", second.as_bytes());

    let output = run(root.path(), &["snapshot"]);

    assert!(output.status.success());
    assert!(output.stderr.is_empty());
    let value: Value = serde_json::from_slice(&output.stdout).expect("valid JSON");
    let references = value["issues"][0]["references"]
        .as_array()
        .expect("reference array");
    assert_eq!(references.len(), 3);
    assert_eq!(references[0]["field"], "statement");
    assert_eq!(references[0]["entry"], 0);
    assert_eq!(references[0]["authored"], "#2");
    assert_eq!(references[0]["target_id"], "0002");
    assert_eq!(references[0]["resolution"], "resolved");
    assert_eq!(references[1]["authored"], "#0002");
    assert_eq!(references[2]["field"], "evidence");
    assert_eq!(references[2]["authored"], "#3");
    assert_eq!(references[2]["target_id"], "0003");
    assert_eq!(references[2]["resolution"], "missing");
    assert!(
        value["issues"][1]["references"]
            .as_array()
            .expect("reference array")
            .is_empty()
    );

    for reference in references {
        let authored = reference["authored"].as_str().expect("authored text");
        let byte_start = reference["byte_start"].as_u64().expect("byte start") as usize;
        let byte_length = reference["byte_length"].as_u64().expect("byte length") as usize;
        let character_start = reference["character_start"]
            .as_u64()
            .expect("character start") as usize;
        let character_length = reference["character_length"]
            .as_u64()
            .expect("character length") as usize;
        assert_eq!(&first[byte_start..byte_start + byte_length], authored);
        assert_eq!(
            first
                .chars()
                .skip(character_start)
                .take(character_length)
                .collect::<String>(),
            authored
        );
    }
}

#[test]
fn snapshot_readiness_matches_the_ready_list_filter() {
    let root = initialized_root();
    let waiting = record(
        "0001",
        "open",
        "Waiting",
        "- **Waiting on:**\n  - #0002 — Ready\n    - **Reason:** Needed first.\n",
        "Waiting.",
    );
    let ready = record(
        "0002",
        "open",
        "Ready",
        "- **Blocking:**\n  - #0001 — Waiting\n",
        "Ready.",
    );
    write_record(root.path(), "0001-waiting.md", waiting.as_bytes());
    write_record(root.path(), "0002-ready.md", ready.as_bytes());

    let snapshot = run(root.path(), &["snapshot"]);
    let ready_list = run(root.path(), &["list", "--ready"]);

    assert!(snapshot.status.success());
    assert!(ready_list.status.success());
    let value: Value = serde_json::from_slice(&snapshot.stdout).expect("valid JSON");
    assert_eq!(value["issues"][0]["ready"], false);
    assert_eq!(value["issues"][1]["ready"], true);
    assert_eq!(
        String::from_utf8(ready_list.stdout).unwrap(),
        "0002\topen\tfeature\tReady\n"
    );
}

#[test]
fn malformed_record_is_reported_separately_without_inventing_an_issue() {
    let root = initialized_root();
    write_record(
        root.path(),
        "0001-bad.md",
        b"# 0001 \xe2\x80\x94 Bad\n\nStatus: open\nStatus: open\nKind: feature\nCreated: 2026-09-02\n",
    );

    let output = run(root.path(), &["snapshot"]);

    assert!(output.status.success());
    let wire: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert!(wire["issues"].as_array().unwrap().is_empty());
    assert_eq!(wire["unavailable"][0]["id"], "0001");
    assert!(wire["unavailable"][0]["error"].as_str().is_some());
}

#[test]
fn snapshot_help_documents_the_wire_contract() {
    let output = Command::new(env!("CARGO_BIN_EXE_isled"))
        .args(["help", "snapshot"])
        .output()
        .expect("run snapshot help");

    assert!(output.status.success());
    assert!(output.stderr.is_empty());
    let help = String::from_utf8(output.stdout).expect("UTF-8 help");
    let root = initialized_root();
    let snapshot = run(root.path(), &["snapshot"]);
    assert!(snapshot.status.success());
    let wire: Value = serde_json::from_slice(&snapshot.stdout).expect("valid JSON");
    let schema = format!("schema_version {}", wire["schema_version"]);
    assert!(help.contains(&schema), "missing {schema:?} from help");
    for expected in [
        "ascending-ID",
        "readiness (open with all blockers closed)",
        "issue-reference",
        "warnings array",
        "related_ids",
        "complete UTF-8 record",
        "base64",
        "Unsafe paths and duplicate identities",
    ] {
        assert!(help.contains(expected), "missing {expected:?} from help");
    }
}

#[cfg(unix)]
#[test]
fn snapshot_preserves_paths_that_tsv_output_rejects() {
    let parent = tempfile::tempdir().expect("temporary parent");
    let root = parent.path().join("project\nname");
    fs::create_dir_all(root.join(".issues")).expect("create ledger");
    fs::write(root.join(".issues/.next-id"), b"2\n").expect("write counter");
    write_record(
        &root,
        "0001-path.md",
        record("0001", "open", "Path", "", "Statement.").as_bytes(),
    );

    let snapshot = run(&root, &["snapshot"]);
    let path = run(&root, &["path", "0001"]);

    assert!(snapshot.status.success());
    let value: Value = serde_json::from_slice(&snapshot.stdout).expect("valid JSON");
    assert_eq!(value["issues"][0]["path"]["encoding"], "utf-8");
    assert!(
        value["issues"][0]["path"]["value"]
            .as_str()
            .expect("path string")
            .contains("project\nname")
    );
    assert_eq!(path.status.code(), Some(1));
    assert!(path.stdout.is_empty());
}
