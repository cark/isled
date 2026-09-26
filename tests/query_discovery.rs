use std::process::{Command, Output};

fn run(arguments: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_isled"))
        .args(arguments)
        .output()
        .expect("run isled")
}

#[test]
fn top_level_help_routes_filter_only_queries_to_list() {
    let output = run(&["--help"]);

    assert!(output.status.success());
    assert!(output.stderr.is_empty());
    let stdout = String::from_utf8(output.stdout).expect("UTF-8 help");
    assert!(stdout.contains("isled list --ready --with-path"));
    assert!(stdout.contains("snapshot` is a frontend wire interface"));
}

#[test]
fn command_help_distinguishes_list_search_and_snapshot() {
    let cases = [
        ("list", "metadata-only issue selection"),
        ("search", "use list for filter-only metadata queries"),
        ("snapshot", "use list for filter-only metadata queries"),
    ];

    for (command, expected) in cases {
        let output = run(&[command, "--help"]);
        assert!(output.status.success(), "{command} help failed");
        assert!(output.stderr.is_empty(), "{command} help wrote stderr");
        let stdout = String::from_utf8(output.stdout).expect("UTF-8 help");
        assert!(
            stdout.contains(expected),
            "{command} help omitted {expected}"
        );
    }
}

#[test]
fn rejected_ready_subcommand_names_the_existing_list_route() {
    let output = run(&["ready"]);

    assert_eq!(output.status.code(), Some(1));
    assert!(output.stdout.is_empty());
    let stderr = String::from_utf8(output.stderr).expect("UTF-8 diagnostic");
    assert!(stderr.contains("unrecognized subcommand 'ready'"));
    assert!(stderr.contains("isled list --ready"));
    assert!(!stderr.contains("similar subcommand exists: 'add'"));
}

#[test]
fn empty_search_names_list_without_discovering_a_project() {
    let output = run(&["--root", "/definitely/missing", "search"]);

    assert_eq!(output.status.code(), Some(1));
    assert!(output.stdout.is_empty());
    let stderr = String::from_utf8(output.stderr).expect("UTF-8 diagnostic");
    assert!(stderr.contains("search requires at least one snippet"));
    assert!(stderr.contains("isled list"));
    assert!(!stderr.contains("project root"));
}
