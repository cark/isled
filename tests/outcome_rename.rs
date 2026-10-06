//! Clean Outcome identity and legacy-format rejection boundaries.
use std::{fs, path::Path, process::Command};

fn run(root: &Path, args: &[&str]) -> std::process::Output {
    Command::new(env!("CARGO_BIN_EXE_isled"))
        .arg("--root")
        .arg(root)
        .args(args)
        .output()
        .unwrap()
}

fn success(root: &Path, args: &[&str]) -> Vec<u8> {
    let output = run(root, args);
    assert!(output.status.success(), "{:?}: {:?}", args, output);
    assert!(output.stderr.is_empty(), "{:?}", output);
    output.stdout
}

#[test]
fn new_name_preserves_prose_and_closure_semantics() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    success(root, &["init"]);
    success(
        root,
        &[
            "add",
            "Example",
            "--kind",
            "maintenance",
            "Disposition is historical prose: café #1.",
        ],
    );
    let path = root.join(".issues/0001-example.md");
    assert!(
        fs::read_to_string(&path)
            .unwrap()
            .contains("## Outcome\n\nPending.")
    );
    assert!(
        !run(root, &["close", "1", "--outcome", "Done."])
            .status
            .success()
    );
    success(root, &["evidence", "add", "1", "Verified."]);
    success(
        root,
        &["outcome", "set", "1", "Kept disposition prose; see #1."],
    );
    let before = fs::read(&path).unwrap();
    assert!(
        !run(root, &["close", "1", "--outcome", "Replacement."])
            .status
            .success()
    );
    assert_eq!(fs::read(&path).unwrap(), before);
    success(root, &["close", "1"]);
    success(root, &["close", "1"]);
    let content = fs::read_to_string(&path).unwrap();
    assert!(content.contains("Disposition is historical prose: café #1."));
    assert!(content.contains("## Outcome\n\nKept disposition prose; see #1."));
    let snapshot: serde_json::Value =
        serde_json::from_slice(&success(root, &["snapshot"])).unwrap();
    assert_eq!(snapshot["schema_version"], 4);
    let reference = &snapshot["issues"][0]["references"][1];
    assert_eq!(reference["field"], "outcome");
    let byte_start = reference["byte_start"].as_u64().unwrap() as usize;
    let character_start = reference["character_start"].as_u64().unwrap() as usize;
    assert_eq!(&content.as_bytes()[byte_start..byte_start + 2], b"#1");
    assert_eq!(
        content
            .chars()
            .skip(character_start)
            .take(2)
            .collect::<String>(),
        "#1"
    );
    success(root, &["check"]);
}

#[test]
fn old_commands_options_and_heading_are_not_aliases() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    success(root, &["init"]);
    success(root, &["add", "Example", "--kind", "maintenance", "Body."]);
    let path = root.join(".issues/0001-example.md");
    let current = fs::read(&path).unwrap();
    for args in [
        vec!["disposition", "set", "1", "Old command."],
        vec!["close", "1", "--disposition", "Old option."],
    ] {
        assert!(!run(root, &args).status.success());
        assert_eq!(fs::read(&path).unwrap(), current);
    }
    let legacy = String::from_utf8(current)
        .unwrap()
        .replace("## Outcome", "## Disposition");
    fs::write(&path, &legacy).unwrap();
    let check = run(root, &["check"]);
    assert!(!check.status.success());
    assert!(
        String::from_utf8(check.stdout)
            .unwrap()
            .contains("invalid or out-of-order record sections")
    );
    assert!(
        !run(root, &["outcome", "set", "1", "No automatic migration."])
            .status
            .success()
    );
    assert_eq!(fs::read(&path).unwrap(), legacy.as_bytes());
}
