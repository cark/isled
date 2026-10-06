//! Work tracking survives real CLI handoffs, cache queries and draft saves.
use serde_json::{Value, json};
use std::{
    fs,
    process::{Command, Output},
};
use tempfile::TempDir;
use unicode_width::UnicodeWidthStr;

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
fn fixture() -> TempDir {
    let root = tempfile::tempdir().unwrap();
    run(&root, &["init"]);
    run(
        &root,
        &[
            "add",
            "Track work",
            "A human-readable concern.",
            "--kind",
            "feature",
        ],
    );
    root
}
fn report(root: &TempDir) -> Value {
    serde_json::from_slice(
        &run(
            root,
            &["work", "show", "1", "--json", "--at", "2026-10-06 12:00:00"],
        )
        .stdout,
    )
    .unwrap()
}
fn source(root: &TempDir) -> String {
    fs::read_to_string(root.path().join(".issues/0001-track-work.md")).unwrap()
}
fn request(root: &TempDir, namespace: &str, request: Value) -> Value {
    use std::io::Write;
    let mut child = command(root, &[namespace, "--stdin"])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(request.to_string().as_bytes())
        .unwrap();
    let output = child.wait_with_output().unwrap();
    assert!(output.status.success());
    serde_json::from_slice(&output.stdout).unwrap()
}

#[test]
fn default_reads_do_not_convert_existing_records() {
    let root = fixture();
    let original = source(&root);
    let work = report(&root);
    assert_eq!(work["schema_version"], 2);
    assert_eq!(work["state"], "not-queued");
    assert_eq!(work["total_seconds"], 0);
    assert_eq!(work["spans"], json!([]));
    assert_eq!(source(&root), original);
    let snapshot: Value = serde_json::from_slice(&run(&root, &["snapshot"]).stdout).unwrap();
    assert_eq!(snapshot["schema_version"], 5);
    assert_eq!(snapshot["issues"][0]["work"]["state"], "not-queued");
    assert_eq!(source(&root), original);
}

#[test]
fn timed_work_pauses_resumes_and_waits_without_counting_idle_time() {
    let root = fixture();
    run(&root, &["work", "queue", "1"]);
    assert_eq!(report(&root)["spans"], json!([]));
    run(
        &root,
        &[
            "work",
            "start",
            "1",
            "--at",
            "2026-10-06 09:00:00",
            "--activity",
            "Implementation",
        ],
    );
    let started = source(&root);
    run(
        &root,
        &["work", "start", "1", "--at", "2026-10-06 09:10:00"],
    );
    assert_eq!(source(&root), started);
    run(
        &root,
        &["work", "pause", "1", "--at", "2026-10-06 09:30:00"],
    );
    let paused = source(&root);
    run(
        &root,
        &["work", "pause", "1", "--at", "2026-10-06 09:40:00"],
    );
    assert_eq!(source(&root), paused);
    assert_eq!(report(&root)["state"], "in-progress");
    run(
        &root,
        &[
            "work",
            "start",
            "1",
            "--at",
            "2026-10-06 10:00:00",
            "--activity",
            "Review",
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
            "Should this run offline?",
            "--at",
            "2026-10-06 10:15:00",
        ],
    );
    let work = report(&root);
    assert_eq!(work["total_seconds"], 2700);
    assert_eq!(work["reason"], "clarification");
    assert_eq!(work["question"], "Should this run offline?");
    assert!(work["running_since"].is_null());
    assert_eq!(work["spans"].as_array().unwrap().len(), 2);
    assert!(source(&root).contains("- **Work state:** awaiting-owner\n  - **Reason:** clarification\n  - **Question:** Should this run offline?"));
    run(&root, &["work", "await", "1", "--reason", "review"]);
    assert_eq!(report(&root)["reason"], "review");
    assert!(report(&root)["question"].is_null());
    assert_eq!(report(&root)["total_seconds"], 2700);
}

#[test]
fn state_tracking_can_be_used_without_ever_creating_a_log() {
    let root = fixture();
    run(&root, &["work", "start", "1", "--no-clock"]);
    run(&root, &["work", "await", "1", "--reason", "review"]);
    assert_eq!(report(&root)["total_seconds"], 0);
    assert!(!source(&root).contains("## Work log"));
    run(&root, &["work", "unqueue", "1"]);
    assert!(!source(&root).contains("Work state"));
}

#[test]
fn forgotten_clock_can_be_stopped_and_history_corrected_explicitly() {
    let root = fixture();
    run(
        &root,
        &["work", "start", "1", "--at", "2026-10-06 09:00:00"],
    );
    assert_eq!(report(&root)["total_seconds"], 10800);
    run(
        &root,
        &["work", "pause", "1", "--at", "2026-10-06 09:30:00"],
    );
    run(
        &root,
        &["work", "start", "1", "--at", "2026-10-06 10:00:00"],
    );
    run(
        &root,
        &["work", "correct", "1", "2", "--stop", "2026-10-06 10:10:00"],
    );
    run(
        &root,
        &["work", "correct", "1", "1", "--stop", "2026-10-06 09:20:00"],
    );
    assert_eq!(report(&root)["total_seconds"], 1800);
    let before = source(&root);
    let failed = command(
        &root,
        &["work", "correct", "1", "1", "--stop", "2026-10-06 10:01:00"],
    )
    .output()
    .unwrap();
    assert!(!failed.status.success());
    assert_eq!(source(&root), before);
}

#[test]
fn metadata_and_complete_draft_edits_preserve_work_data_and_prose() {
    let root = fixture();
    run(
        &root,
        &[
            "work",
            "start",
            "1",
            "--at",
            "2026-10-06 09:00:00",
            "--activity",
            "Repair",
        ],
    );
    let before = report(&root);
    run(&root, &["tag", "add", "1", "rust"]);
    run(
        &root,
        &["statement", "append", "1", "A separate paragraph."],
    );
    assert_eq!(report(&root)["spans"], before["spans"]);
    let loaded = request(
        &root,
        "editor",
        json!({"schema_version":4,"mode":"load","id":"0001"}),
    );
    assert_eq!(loaded["record"]["work"]["spans"], before["spans"]);
    let mut draft = loaded["record"]["draft"].clone();
    draft["title"] = json!("Keep the clock");
    let saved = request(
        &root,
        "editor",
        json!({"schema_version":4,"mode":"save","id":"0001","expected":loaded["record"]["version"],"draft":draft}),
    );
    assert_eq!(saved["ok"], true);
    assert_eq!(report(&root)["spans"], before["spans"]);
    assert_eq!(report(&root)["state"], "in-progress");
    assert_eq!(report(&root), before);
    assert!(
        source(&root).contains("A human-readable concern.\n\nA separate paragraph.\n\n## Work log")
    );
    let old = request(
        &root,
        "editor",
        json!({"schema_version":2,"mode":"load","id":"0001"}),
    );
    assert_eq!(old["ok"], false);
}

#[test]
fn closure_stops_the_clock_and_retains_history_without_current_state() {
    let root = fixture();
    run(
        &root,
        &["work", "start", "1", "--at", "2020-01-01 09:00:00"],
    );
    run(&root, &["evidence", "add", "1", "Checked."]);
    run(&root, &["close", "1", "--outcome", "Complete."]);
    assert!(!source(&root).contains("Work state"));
    assert!(!report(&root)["spans"][0]["stopped"].is_null());
    assert!(report(&root)["running_since"].is_null());
    let output = run(
        &root,
        &["work", "correct", "1", "1", "--stop", "2020-01-01 09:10:00"],
    );
    assert!(String::from_utf8_lossy(&output.stderr).contains("historical record"));
    assert_eq!(report(&root)["total_seconds"], 600);
    assert!(
        !command(&root, &["work", "start", "1"])
            .output()
            .unwrap()
            .status
            .success()
    );
    assert!(run(&root, &["check"]).stdout.is_empty());
}

#[test]
fn filters_and_bounded_views_use_work_state_without_changing_readiness() {
    let root = fixture();
    run(
        &root,
        &[
            "work",
            "await",
            "1",
            "--reason",
            "clarification",
            "--question",
            "Which target?",
        ],
    );
    assert!(
        run(&root, &["list", "--work-state", "queued"])
            .stdout
            .is_empty()
    );
    assert!(
        !run(
            &root,
            &["list", "--work-state", "awaiting-owner", "--ready"]
        )
        .stdout
        .is_empty()
    );
    let view = request(
        &root,
        "frontend",
        json!({"schema_version":5,"mode":"view","filter":{"work_state":"awaiting-owner"}}),
    );
    assert_eq!(
        view["view"]["issues"][0]["work"]["question"],
        "Which target?"
    );
    assert_eq!(view["view"]["issues"][0]["ready"], true);
    run(&root, &["work", "queue", "1"]);
    assert!(
        !run(&root, &["list", "--work-state", "queued"])
            .stdout
            .is_empty()
    );
    assert!(
        run(&root, &["list", "--work-state", "awaiting-owner"])
            .stdout
            .is_empty()
    );
}

#[test]
fn concurrent_starts_keep_one_span_and_rejections_do_not_publish() {
    let root = fixture();
    let mut first = command(&root, &["work", "start", "1"])
        .stdout(std::process::Stdio::null())
        .spawn()
        .unwrap();
    let mut second = command(&root, &["work", "start", "1"])
        .stdout(std::process::Stdio::null())
        .spawn()
        .unwrap();
    assert!(first.wait().unwrap().success());
    assert!(second.wait().unwrap().success());
    assert_eq!(report(&root)["spans"].as_array().unwrap().len(), 1);
    let before = source(&root);
    for args in [
        vec!["work", "await", "1", "--reason", "clarification"],
        vec!["work", "start", "1", "--activity", "A different activity"],
        vec!["work", "pause", "1", "--at", "not a date"],
    ] {
        assert!(!command(&root, &args).output().unwrap().status.success());
        assert_eq!(source(&root), before);
    }
}

#[test]
fn malformed_logs_are_reported_and_activity_is_not_reference_prose() {
    let root = fixture();
    run(
        &root,
        &[
            "work",
            "start",
            "1",
            "--at",
            "2026-10-06 09:00:00",
            "--activity",
            "See #9999",
        ],
    );
    let snapshot: Value = serde_json::from_slice(&run(&root, &["snapshot"]).stdout).unwrap();
    assert_eq!(snapshot["issues"][0]["references"], json!([]));
    let path = root.path().join(".issues/0001-track-work.md");
    fs::write(path, source(&root).replace("in-progress", "queued")).unwrap();
    let output = command(&root, &["check"]).output().unwrap();
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stdout).contains("Work log"));
}

#[test]
fn state_only_transitions_stop_clocks_and_preserve_completed_history() {
    for (action, state) in [
        (vec!["start", "--no-clock"], "in-progress"),
        (vec!["queue"], "queued"),
        (vec!["unqueue"], "not-queued"),
    ] {
        let root = fixture();
        run(
            &root,
            &["work", "start", "1", "--at", "2026-10-06 09:00:00"],
        );
        let mut args = vec!["work", action[0], "1"];
        args.extend_from_slice(&action[1..]);
        args.extend(["--at", "2026-10-06 09:15:00"]);
        run(&root, &args);
        let work = report(&root);
        assert_eq!(work["state"], state);
        assert_eq!(work["total_seconds"], 900);
        assert!(work["running_since"].is_null());
        assert_eq!(work["spans"].as_array().unwrap().len(), 1);
    }
}

#[test]
fn a_work_action_rejects_a_stale_draft_and_editor_closure_stops_timing() {
    let root = fixture();
    let loaded = request(
        &root,
        "editor",
        json!({"schema_version":4,"mode":"load","id":"0001"}),
    );
    run(
        &root,
        &["work", "start", "1", "--at", "2020-01-01 09:00:00"],
    );
    let before = source(&root);
    let stale = request(
        &root,
        "editor",
        json!({"schema_version":4,"mode":"save","id":"0001",
        "expected":loaded["record"]["version"],"draft":loaded["record"]["draft"]}),
    );
    assert_eq!(stale["code"], "conflict");
    assert_eq!(source(&root), before);
    assert_eq!(stale["current"]["work"]["state"], "in-progress");
    let mut draft = stale["current"]["draft"].clone();
    draft["evidence"] = json!(["Verified."]);
    draft["outcome"] = json!("Complete.");
    let closed = request(
        &root,
        "editor",
        json!({"schema_version":4,"mode":"save","id":"0001",
        "expected":stale["current"]["version"],"draft":draft,"close":true}),
    );
    assert_eq!(closed["ok"], true);
    assert_eq!(closed["record"]["status"], "closed");
    assert_eq!(closed["record"]["work"]["state"], "not-queued");
    assert!(closed["record"]["work"]["since"].is_null());
    assert!(closed["record"]["work"]["running_since"].is_null());
    assert!(!closed["record"]["work"]["spans"][0]["stopped"].is_null());
}

#[test]
fn unrelated_mutations_preserve_authored_table_padding_and_contextual_choices() {
    let root = fixture();
    run(
        &root,
        &["work", "start", "1", "--at", "2026-10-06 09:00:00"],
    );
    let path = root.path().join(".issues/0001-track-work.md");
    let padded = source(&root).replace(
        "| 2026-10-06 09:00:00 |                     |                |",
        "|2026-10-06 09:00:00| |  |",
    );
    assert_ne!(padded, source(&root));
    fs::write(path, &padded).unwrap();
    run(&root, &["tag", "add", "1", "rust"]);
    assert_eq!(
        source(&root).split("## Work log").nth(1),
        padded.split("## Work log").nth(1)
    );
    let choices = request(
        &root,
        "frontend",
        json!({"schema_version":5,"mode":"choices",
        "choice_filter":{"work_state":"queued","tags":["rust"]}}),
    );
    assert_eq!(choices["choices"], json!(["w:in-progress"]));
}

#[test]
fn generated_work_tables_align_long_unicode_and_empty_cells_without_changing_spans() {
    let root = fixture();
    for (start, stop, activity) in [
        (
            "2026-10-06 07:11:02",
            "2026-10-06 07:36:15",
            "Implementation",
        ),
        (
            "2026-10-06 07:59:03",
            "2026-10-06 08:16:14",
            "Emacs interaction fixes",
        ),
        (
            "2026-10-06 09:00:00",
            "2026-10-06 09:10:00",
            "界".repeat(12).as_str(),
        ),
        (
            "2026-10-06 09:20:00",
            "2026-10-06 09:30:00",
            "Cafe\u{301} review",
        ),
    ] {
        run(
            &root,
            &["work", "start", "1", "--at", start, "--activity", activity],
        );
        run(&root, &["work", "pause", "1", "--at", stop]);
    }
    let completed = report(&root);
    run(
        &root,
        &["work", "start", "1", "--at", "2026-10-06 10:00:00"],
    );
    let running = report(&root);
    assert_eq!(
        &running["spans"].as_array().unwrap()[..4],
        completed["spans"].as_array().unwrap()
    );
    assert_eq!(running["recorded_seconds"], 3744);
    assert_eq!(running["spans"][4]["activity"], "");
    assert!(running["spans"][4]["stopped"].is_null());

    let source = source(&root);
    let table: Vec<_> = source
        .lines()
        .filter(|line| line.starts_with('|'))
        .collect();
    assert_eq!(table.len(), 7);
    let columns = |line: &str| {
        line.match_indices('|')
            .map(|(index, _)| line[..index].width())
            .collect::<Vec<_>>()
    };
    for row in &table {
        assert_eq!(columns(row), vec![0, 22, 44, 71], "{row}");
    }
    assert!(source.contains("A human-readable concern.\n\n## Work log"));
    assert!(run(&root, &["check"]).stdout.is_empty());
    assert_eq!(report(&root), running);
}
