use std::{fs, process::Command};

#[test]
fn explicit_workflow_is_complete_and_initialization_preserves_edits() {
    let project = tempfile::tempdir().unwrap();
    let run = |args: &[&str], success: bool| {
        let output = Command::new(env!("CARGO_BIN_EXE_isled"))
            .arg("--root")
            .arg(project.path())
            .args(args)
            .output()
            .unwrap();
        assert_eq!(output.status.success(), success, "{args:?}: {output:?}");
        String::from_utf8(output.stdout).unwrap()
    };
    run(&["init"], true);
    let file = project.path().join(".issues/workflow.toml");
    let defaults = run(&["workflow", "show"], true);
    assert!(!file.exists());
    run(&["workflow", "init"], true);
    assert_eq!(fs::read_to_string(&file).unwrap(), defaults);
    let custom = "[states.dance]\nlabel='The dance'\nclock='manual'\n";
    fs::write(&file, custom).unwrap();
    run(&["workflow", "init"], false);
    assert_eq!(run(&["workflow", "show"], true), custom);
    let output = run(&["workflow", "show", "--json"], true);
    let parsed: serde_json::Value = serde_json::from_str(&output).unwrap();
    assert_eq!(parsed["states"].as_object().unwrap().len(), 1);
    run(&["check"], true);
    fs::write(
        file,
        "[states.dance]\nlabel='The dance'\nclock='occasionally'",
    )
    .unwrap();
    run(&["workflow", "show"], false);
    run(&["check"], false);
}

#[test]
fn review_handoff_times_only_active_work_and_preserves_history_after_retirement() {
    let root = tempfile::tempdir().unwrap();
    let run = |args: &[&str], success: bool| {
        let output = Command::new(env!("CARGO_BIN_EXE_isled"))
            .arg("--root")
            .arg(root.path())
            .args(args)
            .output()
            .unwrap();
        assert_eq!(output.status.success(), success, "{args:?}: {output:?}");
        String::from_utf8(if success {
            output.stdout
        } else {
            output.stderr
        })
        .unwrap()
    };
    let report = || -> serde_json::Value {
        serde_json::from_str(&run(&["work", "show", "1", "--json"], true)).unwrap()
    };
    run(&["init"], true);
    run(
        &[
            "add",
            "Reviewed change",
            "Integrate after review.",
            "--kind",
            "feature",
        ],
        true,
    );
    run(&["workflow", "init"], true);
    let path = root.path().join(".issues/workflow.toml");
    let defaults = fs::read_to_string(&path).unwrap();
    let custom = format!(
        "{defaults}\n[states.integration]\nlabel='Integrate'\nclock='manual'\n[states.verify]\nlabel='Verification'\nclock='auto'\n[states.verify.reasons.exception]\nlabel='Exception'\nprompt='What changed?'\n"
    );
    fs::write(&path, &custom).unwrap();
    run(
        &[
            "work",
            "await",
            "1",
            "--reason",
            "review",
            "--at",
            "2026-10-01 08:00:00",
        ],
        true,
    );
    run(
        &[
            "work",
            "set",
            "1",
            "integration",
            "--at",
            "2026-10-01 09:00:00",
        ],
        true,
    );
    assert!(report()["running_since"].is_null());
    run(
        &["work", "resume", "1", "--at", "2026-10-01 10:00:00"],
        true,
    );
    run(
        &["work", "resume", "1", "--at", "2026-10-01 10:02:00"],
        true,
    );
    run(&["work", "pause", "1", "--at", "2026-10-01 10:03:00"], true);
    assert_eq!(report()["since"], "2026-10-01 09:00:00");
    assert_eq!(report()["recorded_seconds"], 180);
    run(
        &["work", "set", "1", "verify", "--reason", "exception"],
        false,
    );
    assert_eq!(report()["state"], "integration");
    run(
        &[
            "work",
            "set",
            "1",
            "verify",
            "--reason",
            "exception",
            "--question",
            "Which branch?",
            "--at",
            "2026-10-01 11:00:00",
        ],
        true,
    );
    assert_eq!(report()["running_since"], "2026-10-01 11:00:00");
    assert!(
        run(
            &[
                "list",
                "--work-state",
                "verify",
                "--work-reason",
                "exception"
            ],
            true
        )
        .contains("Reviewed change")
    );
    assert!(
        run(&["search", "--work-reason", "exception", "Integrate"], true)
            .contains("Reviewed change")
    );
    run(&["check"], true);
    fs::write(path, defaults).unwrap();
    assert!(run(&["list", "--work-state", "verify"], false).contains("unknown work state"));
    assert_eq!(report()["question"], "Which branch?");
    run(&["work", "pause", "1", "--at", "2026-10-01 11:02:00"], true);
    run(&["evidence", "add", "1", "Integration verified."], true);
    run(&["close", "1", "--outcome", "Integrated."], true);
    assert_eq!(report()["state"], "not-queued");
    assert_eq!(report()["recorded_seconds"], 300);
    assert_eq!(report()["spans"][1]["activity"], "Verification");
}
