//! Current-state age and queue selection agree across CLI, cache and frontends.
use isled::{
    filesystem::ProjectRoot,
    query::{self, Filters, SearchSnippets},
};
use serde_json::{Value, json};
use std::{
    fs,
    io::Write,
    path::PathBuf,
    process::{Command, Output, Stdio},
};
use tempfile::TempDir;

fn command(root: &TempDir, args: &[&str]) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_isled"));
    command.arg("--root").arg(root.path()).args(args);
    command
}
fn run(root: &TempDir, args: &[&str]) -> Output {
    let output = command(root, args).output().unwrap();
    assert!(
        output.status.success(),
        "{args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    output
}
fn fixture(count: usize) -> TempDir {
    let root = tempfile::tempdir().unwrap();
    run(&root, &["init"]);
    for id in 1..=count {
        run(
            &root,
            &[
                "add",
                &format!("Issue {id}"),
                "Shared needle.",
                "--kind",
                "feature",
            ],
        );
        run(
            &root,
            &["statement", "append", &id.to_string(), "Second match."],
        );
    }
    root
}
fn path(root: &TempDir, id: &str) -> PathBuf {
    PathBuf::from(
        String::from_utf8(run(root, &["path", id]).stdout)
            .unwrap()
            .trim()
            .rsplit('\t')
            .next()
            .unwrap(),
    )
}
fn source(root: &TempDir, id: &str) -> String {
    fs::read_to_string(path(root, id)).unwrap()
}
fn report(root: &TempDir, id: &str) -> Value {
    serde_json::from_slice(
        &run(
            root,
            &["work", "show", id, "--json", "--at", "2026-10-06 12:00:00"],
        )
        .stdout,
    )
    .unwrap()
}
fn request(root: &TempDir, value: Value) -> Value {
    let mut child = command(root, &["frontend", "--stdin"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(value.to_string().as_bytes())
        .unwrap();
    let output = child.wait_with_output().unwrap();
    assert!(output.status.success());
    serde_json::from_slice(&output.stdout).unwrap()
}
fn ids(output: &[u8]) -> Vec<String> {
    String::from_utf8_lossy(output)
        .lines()
        .filter(|line| !line.starts_with("  "))
        .map(|line| line.split('\t').next().unwrap().into())
        .collect()
}
fn view_ids(value: &Value) -> Vec<String> {
    value["view"]["issues"]
        .as_array()
        .unwrap()
        .iter()
        .map(|issue| issue["id"].as_str().unwrap().into())
        .collect()
}
fn queue(root: &TempDir, id: &str, at: &str) {
    run(root, &["work", "queue", id, "--at", at]);
}

#[test]
fn timestamps_follow_real_transitions_and_survive_clock_pauses() {
    let root = fixture(1);
    assert!(report(&root, "1")["since"].is_null());
    queue(&root, "1", "2026-10-06 08:00:00");
    let queued = source(&root, "1");
    queue(&root, "1", "2026-10-06 08:30:00");
    assert_eq!(source(&root, "1"), queued);
    assert_eq!(report(&root, "1")["since"], "2026-10-06 08:00:00");
    run(
        &root,
        &["work", "start", "1", "--at", "2026-10-06 09:00:00"],
    );
    run(
        &root,
        &["work", "pause", "1", "--at", "2026-10-06 09:10:00"],
    );
    run(
        &root,
        &["work", "start", "1", "--at", "2026-10-06 10:00:00"],
    );
    assert_eq!(report(&root, "1")["since"], "2026-10-06 09:00:00");
    run(
        &root,
        &[
            "work",
            "start",
            "1",
            "--no-clock",
            "--at",
            "2026-10-06 10:10:00",
        ],
    );
    let value = report(&root, "1");
    assert_eq!(value["since"], "2026-10-06 09:00:00");
    assert_eq!(value["recorded_seconds"], 1200);
    assert!(value["running_since"].is_null());
    run(
        &root,
        &[
            "work",
            "await",
            "1",
            "--reason",
            "review",
            "--at",
            "2026-10-06 11:00:00",
        ],
    );
    assert_eq!(report(&root, "1")["since"], "2026-10-06 11:00:00");
    run(
        &root,
        &[
            "work",
            "await",
            "1",
            "--reason",
            "clarification",
            "--question",
            "First?",
            "--at",
            "2026-10-06 11:05:00",
        ],
    );
    run(
        &root,
        &[
            "work",
            "await",
            "1",
            "--reason",
            "clarification",
            "--question",
            "Updated?",
            "--at",
            "2026-10-06 11:10:00",
        ],
    );
    assert_eq!(report(&root, "1")["since"], "2026-10-06 11:05:00");
    assert_eq!(report(&root, "1")["question"], "Updated?");
    run(&root, &["work", "unqueue", "1"]);
    assert!(report(&root, "1")["since"].is_null());
    queue(&root, "1", "2026-10-06 11:30:00");
    assert_eq!(report(&root, "1")["since"], "2026-10-06 11:30:00");
}

#[test]
fn legacy_states_keep_unknown_age_until_a_state_or_reason_change() {
    let root = fixture(1);
    for (state, action) in [
        ("queued", vec!["work", "queue", "1"]),
        ("in-progress", vec!["work", "start", "1", "--no-clock"]),
        (
            "awaiting-owner\n  - **Reason:** review",
            vec!["work", "await", "1", "--reason", "review"],
        ),
    ] {
        run(&root, &["work", "unqueue", "1"]);
        let original = source(&root, "1");
        let created = original
            .lines()
            .find(|line| line.starts_with("- **Created:**"))
            .unwrap();
        let legacy = original.replace(created, &format!("{created}\n- **Work state:** {state}"));
        fs::write(path(&root, "1"), &legacy).unwrap();
        run(&root, &["cache", "refresh", "1"]);
        assert!(report(&root, "1")["since"].is_null());
        run(&root, &action);
        assert_eq!(source(&root, "1"), legacy);
    }
    run(
        &root,
        &[
            "work",
            "await",
            "1",
            "--reason",
            "clarification",
            "--question",
            "Which one?",
            "--at",
            "2026-10-06 10:00:00",
        ],
    );
    assert_eq!(report(&root, "1")["since"], "2026-10-06 10:00:00");
}

fn ordered_fixture() -> TempDir {
    let root = fixture(5);
    queue(&root, "1", "2026-10-06 10:00:00");
    queue(&root, "2", "2026-10-06 09:00:00");
    queue(&root, "3", "2026-10-06 09:00:00");
    for id in ["4", "5"] {
        queue(&root, id, "2026-10-06 08:00:00");
        let legacy = source(&root, id).replace("  - **Since:** 2026-10-06 08:00:00\n", "");
        fs::write(path(&root, id), legacy).unwrap();
    }
    run(&root, &["cache", "refresh"]);
    root
}

#[test]
fn fifo_breaks_ties_by_id_and_puts_unknowns_last_across_query_paths() {
    let root = ordered_fixture();
    let expected = ["0002", "0003", "0001", "0004", "0005"];
    assert_eq!(
        ids(&run(&root, &["list", "--oldest-first"]).stdout),
        expected
    );
    assert_eq!(
        ids(&run(&root, &["list"]).stdout),
        ["0001", "0002", "0003", "0004", "0005"]
    );
    let root_model = ProjectRoot::explicit(root.path()).unwrap();
    let filters = Filters {
        oldest_first: true,
        ..Filters::default()
    };
    assert_eq!(
        ids(&query::list(&root_model.read_records().unwrap(), &filters).unwrap()),
        expected
    );
    assert_eq!(
        ids(&query::list_headers(&root_model.read_headers().unwrap(), &filters).unwrap()),
        expected
    );
    let snippets = SearchSnippets::parse(vec!["needle".into()]).unwrap();
    assert_eq!(
        ids(
            &query::search_parsed(&root_model.read_records().unwrap(), &filters, &snippets)
                .unwrap()
        ),
        expected
    );
    let value = request(
        &root,
        json!({"schema_version":5,"mode":"view","filter":{"oldest_first":true}}),
    );
    assert_eq!(view_ids(&value), expected);
    assert!(value["view"]["issues"][3]["work"]["since"].is_null());
    let unchanged = request(
        &root,
        json!({"schema_version":5,"mode":"view","filter":{"oldest_first":true},"view_hash":value["view_hash"]}),
    );
    assert!(unchanged["view"].is_null());
}

#[test]
fn limits_follow_readiness_tags_and_every_text_match_and_count_issues() {
    let root = ordered_fixture();
    run(&root, &["wait", "add", "2", "1", "Needed first."]);
    run(&root, &["tag", "add", "3", "rust"]);
    run(&root, &["statement", "append", "1", "Unique phrase."]);
    assert_eq!(
        ids(&run(
            &root,
            &[
                "list",
                "--work-state",
                "queued",
                "--ready",
                "--oldest-first",
                "--limit",
                "1"
            ]
        )
        .stdout),
        ["0003"]
    );
    assert_eq!(
        ids(&run(
            &root,
            &["list", "--tags", "rust", "--oldest-first", "--limit", "1"]
        )
        .stdout),
        ["0003"]
    );
    let value = request(
        &root,
        json!({"schema_version":5,"mode":"view","filter":{"oldest_first":true,"limit":1,"text":["Unique phrase"]}}),
    );
    assert_eq!(view_ids(&value), ["0001"]);
    let searched = run(
        &root,
        &[
            "search",
            "--oldest-first",
            "--limit",
            "1",
            "Unique phrase",
            "Second match",
        ],
    );
    assert_eq!(ids(&searched.stdout), ["0001"]);
    assert_eq!(
        String::from_utf8_lossy(&searched.stdout)
            .lines()
            .filter(|line| line.starts_with("  "))
            .count(),
        2
    );
    assert!(
        run(&root, &["list", "--oldest-first", "--limit", "0"])
            .stdout
            .is_empty()
    );
    assert!(
        run(
            &root,
            &["search", "--oldest-first", "--limit", "0", "needle"]
        )
        .stdout
        .is_empty()
    );
    for value in ["-1", "no"] {
        assert!(
            !command(&root, &["list", "--limit", value])
                .output()
                .unwrap()
                .status
                .success()
        );
    }
}

#[test]
fn review_and_question_queues_are_distinct_and_completion_ignores_caps() {
    let root = fixture(3);
    run(
        &root,
        &[
            "work",
            "await",
            "1",
            "--reason",
            "review",
            "--at",
            "2026-10-06 10:00:00",
        ],
    );
    run(
        &root,
        &[
            "work",
            "await",
            "2",
            "--reason",
            "clarification",
            "--question",
            "Which one?",
        ],
    );
    run(
        &root,
        &[
            "work",
            "await",
            "3",
            "--reason",
            "review",
            "--at",
            "2026-10-06 09:00:00",
        ],
    );
    assert_eq!(
        ids(&run(
            &root,
            &[
                "list",
                "--work-state",
                "awaiting-owner",
                "--work-reason",
                "review",
                "--oldest-first",
                "--limit",
                "1"
            ]
        )
        .stdout),
        ["0003"]
    );
    assert_eq!(
        ids(&run(
            &root,
            &["search", "--work-reason", "clarification", "needle"]
        )
        .stdout),
        ["0002"]
    );
    let value = request(
        &root,
        json!({"schema_version":5,"mode":"view","filter":{"work_reason":"review","oldest_first":true,"limit":1}}),
    );
    assert_eq!(view_ids(&value), ["0003"]);
    let choices = request(
        &root,
        json!({"schema_version":5,"mode":"choices","choice_filter":{"work_reason":"review","limit":0}}),
    );
    assert!(
        choices["choices"]
            .as_array()
            .unwrap()
            .contains(&json!("r:clarification"))
    );
    assert!(request(&root, json!({"schema_version":5,"mode":"view","filter":{"work_state":"queued","work_reason":"review"}}))["view"]["issues"].as_array().unwrap().is_empty());
}

#[test]
fn graph_uses_the_same_limited_membership_and_keeps_dependency_order() {
    let root = ordered_fixture();
    run(&root, &["wait", "add", "2", "3", "Needed first."]);
    let value = request(
        &root,
        json!({"schema_version":5,"mode":"view","filter":{"oldest_first":true,"limit":2},"graph":{"direction":"prerequisites"}}),
    );
    assert_eq!(view_ids(&value), ["0002", "0003"]);
    let rows = value["graph"]["plan"]["rows"].as_array().unwrap();
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0]["id"], "0003");
    assert_eq!(rows[1]["id"], "0002");
    let empty = request(
        &root,
        json!({"schema_version":5,"mode":"view","filter":{"limit":0},"graph":{"direction":"prerequisites"}}),
    );
    assert!(empty["view"]["issues"].as_array().unwrap().is_empty());
    assert!(
        empty["graph"]["plan"]["rows"]
            .as_array()
            .unwrap()
            .is_empty()
    );
}

#[test]
fn malformed_since_is_rejected_without_inventing_work_metadata() {
    let root = fixture(1);
    let original = source(&root, "1");
    let created = original
        .lines()
        .find(|line| line.starts_with("- **Created:**"))
        .unwrap();
    for field in [
        "  - **Since:** 2026-10-06 09:00:00",
        "- **Work state:** not-queued\n  - **Since:** 2026-10-06 09:00:00",
        "- **Work state:** queued\n  - **Since:** 2026-02-30 09:00:00",
        "- **Work state:** queued\n  - **Since:** 2026-10-06T09:00:00Z",
        "- **Work state:** queued\n  - **Since:** 2026-10-06 09:00:00\n  - **Since:** 2026-10-06 10:00:00",
    ] {
        fs::write(
            path(&root, "1"),
            original.replace(created, &format!("{created}\n{field}")),
        )
        .unwrap();
        assert!(
            !command(&root, &["check"])
                .output()
                .unwrap()
                .status
                .success(),
            "{field}"
        );
        fs::write(root.path().join(".issues/0001-issue-1.md"), &original).unwrap();
    }
    assert!(
        isled::frontend::request::Request::parse(br#"{"schema_version":4,"mode":"view"}"#).is_err()
    );
    assert_eq!(
        isled::editor::respond(
            &ProjectRoot::explicit(root.path()).unwrap(),
            br#"{"schema_version":3,"mode":"load","id":"0001"}"#
        )["ok"],
        false
    );
}
