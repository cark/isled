use serde_json::Value;
use std::fs;
use std::path::Path;
use std::process::{Command, Output};
use tempfile::TempDir;

fn record(id: &str, status: &str, title: &str, relations: &str) -> String {
    format!(
        "# {id} — {title}\n\n## Metadata\n\n- **Status:** {status}\n- **Kind:** feature\n- **Created:** 2026-09-04\n{relations}\n## Statement\n\nBody deliberately excluded from trees.\n\n## Evidence\n\n- Recorded.\n\n## Outcome\n\nRecorded.\n"
    )
}

fn write(root: &Path, id: &str, slug: &str, content: String) {
    fs::write(
        root.join(".issues").join(format!("{id}-{slug}.md")),
        content,
    )
    .expect("write record");
}

fn ledger() -> TempDir {
    let root = tempfile::tempdir().expect("temporary project");
    fs::create_dir(root.path().join(".issues")).expect("create ledger");
    fs::write(root.path().join(".issues/.next-id"), b"7\n").expect("write counter");
    write(
        root.path(),
        "0001",
        "root",
        record(
            "0001",
            "open",
            "Root",
            "- **Waiting on:**\n  - #0002 — Left\n    - **Reason:** Left first.\n  - #0003 — Right\n    - **Reason:** Right first.\n  - #0005 — Historical\n    - **Reason:** Historical context.\n- **Blocking:**\n  - #0006 — Consumer\n",
        ),
    );
    write(
        root.path(),
        "0002",
        "left",
        record(
            "0002",
            "open",
            "Left",
            "- **Waiting on:**\n  - #0004 — Shared\n    - **Reason:** Shared work.\n- **Blocking:**\n  - #0001 — Root\n",
        ),
    );
    write(
        root.path(),
        "0003",
        "right",
        record(
            "0003",
            "open",
            "Right",
            "- **Waiting on:**\n  - #0004 — Shared\n    - **Reason:** Also shared.\n- **Blocking:**\n  - #0001 — Root\n",
        ),
    );
    write(
        root.path(),
        "0004",
        "shared",
        record(
            "0004",
            "open",
            "Shared",
            "- **Blocking:**\n  - #0002 — Left\n  - #0003 — Right\n  - #0005 — Historical\n",
        ),
    );
    write(
        root.path(),
        "0005",
        "historical",
        record(
            "0005",
            "closed",
            "Historical",
            "- **Waiting on:**\n  - #0004 — Shared\n    - **Reason:** Preserved old wait.\n- **Blocking:**\n  - #0001 — Root\n",
        ),
    );
    write(
        root.path(),
        "0006",
        "consumer",
        record(
            "0006",
            "open",
            "Consumer",
            "- **Waiting on:**\n  - #0001 — Root\n    - **Reason:** Needs root.\n",
        ),
    );
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
fn human_tree_is_targeted_and_marks_shared_subtrees() {
    let root = ledger();
    let output = run(root.path(), &["wait", "tree", "#1"]);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8(output.stdout).expect("UTF-8 tree");

    assert!(stdout.starts_with("Waits on:\n#0001  open/waiting  Root\n"));
    assert!(stdout.contains("├── #0002  open/waiting  Left"));
    assert!(stdout.contains("└── #0004  open/ready  Shared [shared]"));
    assert!(stdout.contains("#0005  closed  Historical"));
    assert!(!stdout.contains("Preserved old wait"));
    assert!(!stdout.contains("Body deliberately"));
}

#[test]
fn dependents_json_preserves_wait_orientation_and_optional_paths() {
    let root = ledger();
    let output = run(
        root.path(),
        &["wait", "tree", "1", "--dependents", "--json", "--with-path"],
    );
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let value: Value = serde_json::from_slice(&output.stdout).expect("valid JSON");

    assert_eq!(value["schema_version"], 2);
    assert_eq!(value["root"], "0001");
    assert_eq!(value["direction"], "dependents");
    assert_eq!(value["issues"].as_array().unwrap().len(), 2);
    assert_eq!(value["issues"][0]["id"], "0001");
    assert_eq!(value["issues"][0]["waits_on"].as_array().unwrap().len(), 0);
    assert_eq!(value["issues"][1]["id"], "0006");
    assert_eq!(value["issues"][1]["waits_on"][0]["id"], "0001");
    assert_eq!(value["issues"][1]["waits_on"][0]["reason"], "Needs root.");
    assert_eq!(value["issues"][1]["path"]["encoding"], "utf-8");
}

#[test]
fn empty_direction_has_an_explicit_leaf() {
    let root = ledger();
    let output = run(root.path(), &["wait", "tree", "4"]);
    assert!(output.status.success());
    assert_eq!(
        String::from_utf8(output.stdout).unwrap(),
        "Waits on:\n#0004  open/ready  Shared\n└── (none)\n"
    );
}

#[test]
fn tree_help_is_available_without_a_ledger() {
    let output = Command::new(env!("CARGO_BIN_EXE_isled"))
        .args(["help", "wait", "tree"])
        .output()
        .expect("render help");
    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).expect("UTF-8 help");
    assert!(stdout.contains("--dependents"));
    assert!(stdout.contains("--json"));
    assert!(stdout.contains("--with-path"));
    assert!(stdout.contains("terminal historical leaf"));
}

#[test]
fn reverse_tree_orders_siblings_and_stops_at_historical_nodes() {
    let root = ledger();
    let output = run(root.path(), &["wait", "tree", "4", "--dependents"]);
    assert!(output.status.success());
    assert_eq!(
        String::from_utf8(output.stdout).unwrap(),
        concat!(
            "Waited on by:\n#0004  open/ready  Shared\n",
            "├── #0002  open/waiting  Left\n│   reason: Shared work.\n",
            "│   └── #0001  open/waiting  Root\n│       reason: Left first.\n",
            "│       └── #0006  open/waiting  Consumer\n│           reason: Needs root.\n",
            "├── #0003  open/waiting  Right\n│   reason: Also shared.\n",
            "│   └── #0001  open/waiting  Root [shared]\n│       reason: Right first.\n",
            "└── #0005  closed  Historical\n    reason: Preserved old wait.\n",
        )
    );
}
