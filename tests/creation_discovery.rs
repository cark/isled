use std::process::Command;

#[test]
fn rejected_create_forms_point_to_add_before_project_discovery() {
    let directory = tempfile::tempdir().unwrap();
    let missing = directory.path().join("missing");
    let cases: &[&[&str]] = &[
        &["create"],
        &["help", "create"],
        &["create", "--help"],
        &["create", "-h"],
        &["create", "Title", "Statement", "--kind", "feature"],
    ];

    for arguments in cases {
        let output = Command::new(env!("CARGO_BIN_EXE_isled"))
            .arg("--root")
            .arg(&missing)
            .args(*arguments)
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(1), "{arguments:?}");
        assert!(output.stdout.is_empty(), "{arguments:?}");
        let stderr = String::from_utf8(output.stderr).unwrap();
        assert!(
            stderr.contains("unrecognized subcommand 'create'"),
            "{stderr}"
        );
        assert!(stderr.contains("isled add"), "{stderr}");
        assert!(stderr.contains("isled help add"), "{stderr}");
        assert!(!stderr.contains("project root"), "{stderr}");
        assert!(!stderr.contains('\u{1b}'), "{stderr}");
    }
    assert!(!missing.exists());
    assert_eq!(directory.path().read_dir().unwrap().count(), 0);
}

#[test]
fn add_help_forms_show_creation_examples_without_a_project() {
    let directory = tempfile::tempdir().unwrap();
    let missing = directory.path().join("missing");
    let cases = [["help", "add"], ["add", "--help"], ["add", "-h"]];
    let mut previous_help = None;

    for arguments in cases {
        let output = Command::new(env!("CARGO_BIN_EXE_isled"))
            .arg("--root")
            .arg(&missing)
            .args(arguments)
            .output()
            .unwrap();
        assert!(output.status.success(), "{arguments:?}");
        assert!(output.stderr.is_empty(), "{arguments:?}");
        let stdout = String::from_utf8(output.stdout).unwrap();
        assert!(stdout.contains("isled add 'Improve startup'"), "{stdout}");
        assert!(stdout.contains("--stdin <<'EOF'"), "{stdout}");
        if let Some(previous) = &previous_help {
            assert_eq!(&stdout, previous);
        }
        previous_help = Some(stdout);
    }
    assert!(!missing.exists());
    assert_eq!(directory.path().read_dir().unwrap().count(), 0);
}
