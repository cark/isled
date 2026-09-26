use std::{
    collections::BTreeMap,
    fs,
    io::Write,
    path::Path,
    process::{Command, Output, Stdio},
};
use tempfile::{TempDir, tempdir};

const FILE: &str = "0001-example.md";
const PREFIX: &str = "# 0001 — Example\n\n## Metadata\n\n- **Status:** open\n- **Kind:** feature\n- **Created:** 2026-09-05\n\n## Statement\n\n";
const SUFFIX: &str =
    "\n\n## Evidence\n\n- Verified.\n\n## Outcome\n\nSome unchanged\nwrapped prose.\n";

fn ledger(statement: &str) -> TempDir {
    let root = tempdir().unwrap();
    fs::create_dir(root.path().join(".issues")).unwrap();
    fs::write(root.path().join(".issues/.next-id"), "2\n").unwrap();
    fs::write(
        root.path().join(".issues").join(FILE),
        format!("{PREFIX}{statement}{SUFFIX}"),
    )
    .unwrap();
    root
}

fn run(root: &Path, args: &[&str], input: &[u8]) -> Output {
    let mut child = Command::new(env!("CARGO_BIN_EXE_isled"))
        .arg("--root")
        .arg(root)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let _ = child.stdin.take().unwrap().write_all(input);
    child.wait_with_output().unwrap()
}

fn files(root: &Path) -> BTreeMap<String, Vec<u8>> {
    fs::read_dir(root.join(".issues"))
        .unwrap()
        .filter(|entry| {
            entry
                .as_ref()
                .map_or(true, |entry| entry.file_name() != ".cache")
        })
        .map(|entry| {
            let entry = entry.unwrap();
            (
                entry.file_name().into_string().unwrap(),
                fs::read(entry.path()).unwrap(),
            )
        })
        .collect()
}

fn assert_statement(root: &Path, statement: &str) {
    assert_eq!(
        fs::read_to_string(root.join(".issues").join(FILE)).unwrap(),
        format!("{PREFIX}{statement}{SUFFIX}")
    );
}

#[test]
fn set_stdin_replaces_the_complete_statement_and_preserves_other_bytes() {
    let root = ledger("Old prose.\n\nMore old prose.");
    let text = "New \"quotes\", $x, `code`, café.\n\n### Details\n\n- First\n- Second";
    for (input, expected) in [
        (text.to_owned(), text),
        (format!("{text}\n"), text),
        ("CRLF\r\n".to_owned(), "CRLF\r"),
    ] {
        let output = run(
            root.path(),
            &["statement", "set", "#1", "--stdin"],
            input.as_bytes(),
        );
        assert!(output.status.success(), "{output:?}");
        assert_eq!(output.stdout, b"set statement for issue 0001\n");
        assert!(output.stderr.is_empty());
        assert_statement(root.path(), expected);
    }
    assert!(run(root.path(), &["check"], b"").status.success());
}

#[test]
fn rejected_set_stdin_preserves_files_and_validates_before_discovery() {
    let root = ledger("Original.");
    let before = files(root.path());
    for input in [
        b"".as_slice(),
        b"\xff",
        b"\n",
        b"## Evidence\n",
        b"Body.\n\n## Custom\n",
        b"\nLeading\n",
        b"Trailing\n\n",
    ] {
        let output = run(root.path(), &["statement", "set", "1", "--stdin"], input);
        assert!(!output.status.success(), "{input:?}");
        assert!(output.stdout.is_empty());
        assert_eq!(files(root.path()), before);
    }
    for args in [
        vec!["statement", "set", "1", "text", "--stdin"],
        vec!["statement", "set", "1"],
    ] {
        assert!(!run(root.path(), &args, b"Body.\n").status.success());
        assert_eq!(files(root.path()), before);
    }
    let output = run(
        Path::new("/no-such-project"),
        &["statement", "set", "1", "--stdin"],
        b"## Reserved\n",
    );
    assert!(
        String::from_utf8(output.stderr)
            .unwrap()
            .contains("### or deeper")
    );
}

#[test]
fn closed_set_stdin_warns_only_when_content_changes() {
    let root = ledger("Body.");
    let path = root.path().join(".issues").join(FILE);
    let closed = format!("{PREFIX}Body.{SUFFIX}").replace("**Status:** open", "**Status:** closed");
    fs::write(&path, &closed).unwrap();
    let modified = fs::metadata(&path).unwrap().modified().unwrap();
    let output = run(
        root.path(),
        &["statement", "set", "1", "--stdin"],
        b"Body.\n",
    );
    assert!(output.status.success());
    assert!(output.stderr.is_empty());
    assert_eq!(fs::metadata(&path).unwrap().modified().unwrap(), modified);
    let output = run(
        root.path(),
        &["statement", "set", "1", "--stdin"],
        b"## Reserved\n",
    );
    assert!(!output.status.success());
    assert!(
        !String::from_utf8(output.stderr)
            .unwrap()
            .contains("updating historical record")
    );
    assert_eq!(fs::read_to_string(&path).unwrap(), closed);
    let output = run(
        root.path(),
        &["statement", "set", "1", "--stdin"],
        b"Corrected.\n\nMore detail.\n",
    );
    assert!(output.status.success());
    assert!(
        String::from_utf8(output.stderr)
            .unwrap()
            .contains("updating historical record")
    );
    assert_eq!(
        fs::read_to_string(path).unwrap(),
        closed.replace("Body.", "Corrected.\n\nMore detail.")
    );
}

#[test]
fn append_and_literal_replace_preserve_every_other_byte() {
    let root = ledger("Existing statement.");
    let output = run(
        root.path(),
        &["statement", "append", "#1", "--stdin"],
        "Quotes \" ' $x `x` café\n\n### Subsection\n\n- one\n- two\n".as_bytes(),
    );
    assert!(output.status.success(), "{:?}", output);
    assert!(output.stderr.is_empty());
    let expected =
        "Existing statement.\n\nQuotes \" ' $x `x` café\n\n### Subsection\n\n- one\n- two";
    assert_statement(root.path(), expected);
    let output = run(
        root.path(),
        &["statement", "replace", "0001", "--stdin"],
        "café\n\n### Subsection\n---replacement---\nthé\n\n### Changed\n".as_bytes(),
    );
    assert!(output.status.success(), "{:?}", output);
    assert_statement(
        root.path(),
        &expected.replace("café\n\n### Subsection", "thé\n\n### Changed"),
    );
    assert!(run(root.path(), &["check"], b"").status.success());
}

#[test]
fn explicit_occurrences_all_and_empty_replacements_work() {
    let root = ledger("first pending; second pending; third pending.");
    let output = run(
        root.path(),
        &["statement", "replace", "1", "--stdin", "--occurrence", "2"],
        b"pending\n---replacement---\ncomplete\n",
    );
    assert!(output.status.success());
    assert_statement(
        root.path(),
        "first pending; second complete; third pending.",
    );
    let output = run(
        root.path(),
        &[
            "statement",
            "replace",
            "1",
            "--stdin",
            "--all",
            "--separator",
            "CUT",
        ],
        b"pending\nCUT\n",
    );
    assert!(output.status.success());
    assert_statement(root.path(), "first ; second complete; third .");
}

#[test]
fn invalid_edits_leave_all_files_unchanged() {
    let root = ledger("same and same");
    let before = files(root.path());
    for input in [
        "same\n---replacement---\nnew\n", // ambiguous
        "missing\n---replacement---\nnew\n",
        "same and same\n---replacement---\n", // deleting required section
        "same and same\n---replacement---\n## Evidence\n\nInjected\n",
        "same and same\n---replacement---\n\nleading blank line\n",
        "same and same\n---replacement---\ntrailing blank line\n\n",
        "\n---replacement---\nnew\n",
        "old\n---replacement---\nnew\n---replacement---\nmore\n",
        "no separator",
    ] {
        let output = run(
            root.path(),
            &["statement", "replace", "1", "--stdin"],
            input.as_bytes(),
        );
        assert!(!output.status.success(), "{input:?}");
        assert!(output.stdout.is_empty());
        assert!(!output.stderr.is_empty());
        assert_eq!(files(root.path()), before);
    }
    for extra in [
        vec!["--occurrence", "3"],
        vec!["--occurrence", "0"],
        vec!["--occurrence", "1", "--all"],
    ] {
        let mut args = vec!["statement", "replace", "1", "--stdin"];
        args.extend(extra);
        assert!(
            !run(root.path(), &args, b"same\n---replacement---\nnew\n")
                .status
                .success()
        );
        assert_eq!(files(root.path()), before);
    }
    assert!(
        !run(
            root.path(),
            &["statement", "append", "1", "--stdin"],
            &[0xff]
        )
        .status
        .success()
    );
    assert!(
        !run(root.path(), &["statement", "append", "1", "--stdin"], b"\n")
            .status
            .success()
    );
    assert!(
        !run(
            root.path(),
            &["statement", "append", "1", "text", "--stdin"],
            b"more"
        )
        .status
        .success()
    );
    assert_eq!(files(root.path()), before);
}

#[test]
fn matching_cannot_reach_other_sections_and_unrelated_bad_prose_does_not_block() {
    let root = ledger("Body.");
    fs::write(root.path().join(".issues/0002-broken.md"), "malformed").unwrap();
    let before = files(root.path());
    assert!(
        !run(
            root.path(),
            &["statement", "replace", "1", "--stdin"],
            b"Verified.\n---replacement---\nChanged\n"
        )
        .status
        .success()
    );
    assert_eq!(files(root.path()), before);
    assert!(
        run(
            root.path(),
            &["statement", "replace", "1", "--stdin"],
            b"Body.\n---replacement---\nNew body.\n"
        )
        .status
        .success()
    );
    assert_statement(root.path(), "New body.");
}

#[test]
fn closed_edits_warn_only_for_real_changes_and_noops_do_not_rewrite() {
    let root = ledger("Body.");
    let path = root.path().join(".issues").join(FILE);
    let closed = format!("{PREFIX}Body.{SUFFIX}").replace("**Status:** open", "**Status:** closed");
    fs::write(&path, &closed).unwrap();
    let modified = fs::metadata(&path).unwrap().modified().unwrap();
    let output = run(
        root.path(),
        &["statement", "replace", "1", "--stdin"],
        b"Body.\n---replacement---\nBody.\n",
    );
    assert!(output.status.success());
    assert!(output.stderr.is_empty());
    assert_eq!(fs::metadata(&path).unwrap().modified().unwrap(), modified);
    let output = run(
        root.path(),
        &["statement", "replace", "1", "--stdin"],
        b"Body.\n---replacement---\nCorrected.\n",
    );
    assert!(output.status.success());
    assert!(String::from_utf8(output.stderr).unwrap().contains("closed"));
    assert_eq!(
        fs::read_to_string(path).unwrap(),
        closed.replace("Body.", "Corrected.")
    );
}

#[test]
fn existing_argument_commands_and_new_help_remain_discoverable() {
    let root = ledger("Old.");
    assert!(
        run(root.path(), &["statement", "set", "1", "New."], b"")
            .status
            .success()
    );
    assert!(
        run(root.path(), &["statement", "append", "1", "More."], b"")
            .status
            .success()
    );
    assert_statement(root.path(), "New.\n\nMore.");
    let output = run(
        Path::new("/no-such-project"),
        &["help", "statement", "set"],
        b"",
    );
    assert!(output.status.success());
    assert!(output.stderr.is_empty());
    let help = String::from_utf8(output.stdout).unwrap();
    assert!(help.contains("--stdin"));
    assert!(help.contains("without a separator"));
    let output = run(
        Path::new("/no-such-project"),
        &["help", "statement", "replace"],
        b"",
    );
    assert!(output.status.success());
    assert!(
        String::from_utf8(output.stdout)
            .unwrap()
            .contains("Delete by leaving the replacement empty")
    );
}

#[test]
fn argument_edits_validate_final_statement_and_preserve_files_on_failure() {
    for status in ["open", "closed"] {
        let root = ledger("Original statement.");
        let path = root.path().join(".issues").join(FILE);
        let original = format!("{PREFIX}Original statement.{SUFFIX}")
            .replace("**Status:** open", &format!("**Status:** {status}"));
        fs::write(&path, original).unwrap();
        let before = files(root.path());
        for operation in ["set", "append"] {
            for heading in [
                "## Metadata",
                "## Statement",
                "## Evidence",
                "## Outcome",
                "## Custom",
            ] {
                let output = run(root.path(), &["statement", operation, "1", heading], b"");
                assert!(!output.status.success(), "{operation}: {heading}");
                assert!(output.stdout.is_empty());
                let diagnostic = String::from_utf8(output.stderr).unwrap();
                assert!(diagnostic.contains("### or deeper"));
                assert!(!diagnostic.contains("updating historical record"));
                assert_eq!(files(root.path()), before);
            }
        }
        let modified = fs::metadata(&path).unwrap().modified().unwrap();
        let output = run(
            root.path(),
            &["statement", "set", "1", "Original statement."],
            b"",
        );
        assert!(output.status.success());
        assert!(output.stderr.is_empty());
        assert_eq!(fs::metadata(&path).unwrap().modified().unwrap(), modified);
        assert_eq!(files(root.path()), before);
        let output = run(
            root.path(),
            &["statement", "append", "1", "### Allowed subsection"],
            b"",
        );
        assert!(output.status.success(), "{output:?}");
        assert_eq!(
            String::from_utf8(output.stderr)
                .unwrap()
                .contains("updating historical record"),
            status == "closed"
        );
        assert!(run(root.path(), &["check"], b"").status.success());
    }
}

#[test]
fn creation_accepts_multiline_stdin_without_a_placeholder_issue() {
    let root = ledger("Existing issue.");
    let input = "Concern with $quotes and `code`.\n\n### Details\n\n- café\n- thé\n";
    let output = run(
        root.path(),
        &[
            "add",
            "New issue",
            "--kind",
            "feature",
            "--stdin",
            "--with-path",
        ],
        input.as_bytes(),
    );
    assert!(output.status.success(), "{output:?}");
    assert!(output.stderr.is_empty());
    assert!(output.stdout.starts_with(b"0002\t"));
    let bytes = fs::read(root.path().join(".issues/0002-new-issue.md")).unwrap();
    isled::record::IssueRecord::parse(b"0002-new-issue.md", bytes.clone()).unwrap();
    assert!(String::from_utf8(bytes).unwrap().contains(&format!(
        "## Statement\n\n{}\n\n## Evidence",
        input.strip_suffix('\n').unwrap()
    )));
    assert_statement(root.path(), "Existing issue.");
    assert_eq!(
        fs::read(root.path().join(".issues/.next-id")).unwrap(),
        b"3\n"
    );
    assert!(run(root.path(), &["check"], b"").status.success());
}

#[test]
fn rejected_creation_consumes_no_id_and_creates_no_record() {
    let root = ledger("Existing issue.");
    let before = files(root.path());
    for input in [
        b"".as_slice(),
        b"\xff",
        b"\n",
        b"## Evidence\n",
        b"Prose.\n\n## Other\n",
        b"Text\n\n",
    ] {
        let output = run(
            root.path(),
            &["add", "Rejected", "--kind", "feature", "--stdin"],
            input,
        );
        assert!(!output.status.success(), "{input:?}");
        assert!(output.stdout.is_empty());
        assert_eq!(files(root.path()), before);
    }
    for args in [
        vec!["add", "Rejected", "## Evidence", "--kind", "feature"],
        vec![
            "add", "Rejected", "Argument", "--kind", "feature", "--stdin",
        ],
        vec!["add", "Rejected", "--kind", "feature"],
    ] {
        assert!(!run(root.path(), &args, b"Text\n").status.success());
        assert_eq!(files(root.path()), before);
    }
    let output = run(
        Path::new("/no-such-project"),
        &["add", "Rejected", "--kind", "feature", "--stdin"],
        b"## Reserved\n",
    );
    assert!(
        String::from_utf8(output.stderr)
            .unwrap()
            .contains("### or deeper")
    );
    assert!(
        run(
            root.path(),
            &["add", "Accepted", "Single line.", "--kind", "feature"],
            b""
        )
        .stdout
        .starts_with(b"0002")
    );
}
