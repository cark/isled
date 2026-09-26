use isled::{
    filesystem::ProjectRoot,
    issue::{IssueId, Status, Tag},
    query::{self, Filters, OutputPaths, QueryError, SearchSnippets},
};
use std::fs;
use tempfile::TempDir;

fn fixture() -> (TempDir, ProjectRoot) {
    let directory = tempfile::tempdir().unwrap();
    let issues = directory.path().join(".issues");
    fs::create_dir(&issues).unwrap();
    fs::write(issues.join(".next-id"), "3\n").unwrap();
    for (filename, text) in [
        (
            "0001-source.md",
            "# 0001 — Source\n\n## Metadata\n\n- **Status:** open\n- **Kind:** feature\n- **Created:** 2026-09-06\n- **Tags:** rust\n- **Waiting on:**\n  - #0002 — Target\n    - **Reason:** Needed first.\n\n## Statement\n\nStraße needle\n\n## Evidence\n\n- Verified.\n\n## Outcome\n\nPending.\n",
        ),
        (
            "0002-target.md",
            "# 0002 — Target\n\n## Metadata\n\n- **Status:** open\n- **Kind:** feature\n- **Created:** 2026-09-06\n- **Blocking:**\n  - #0001 — Source\n\n## Statement\n\nOther text.\n\n## Evidence\n\n- Verified.\n\n## Outcome\n\nPending.\n",
        ),
    ] {
        fs::write(issues.join(filename), text).unwrap();
    }
    let root = ProjectRoot::explicit(directory.path()).unwrap();
    (directory, root)
}

fn id(value: &str) -> IssueId {
    value.parse().unwrap()
}

fn paths() -> OutputPaths {
    OutputPaths::new([
        (b"0001-source.md".to_vec(), b"/ledger/source.md".to_vec()),
        (b"0002-target.md".to_vec(), b"/ledger/target.md".to_vec()),
    ])
}

#[test]
fn record_and_header_queries_preserve_filter_and_wait_output() {
    let (_directory, root) = fixture();
    let records = root.read_records().unwrap();
    let headers = root.read_headers().unwrap();
    let filters = Filters {
        status: Some(Status::Open),
        tags: vec![Tag::try_parse(b"rust").unwrap()],
        waiting_on: Some(id("2")),
        ..Filters::default()
    };
    let expected = b"0001\topen\tfeature\tSource\n";
    assert_eq!(query::list(&records, &filters).unwrap(), expected);
    assert_eq!(query::list_headers(&headers, &filters).unwrap(), expected);
    let expected_paths = b"0001\topen\tfeature\tSource\t/ledger/source.md\n";
    assert_eq!(
        query::list_with_paths(&records, &filters, &paths()).unwrap(),
        expected_paths
    );
    assert_eq!(
        query::list_headers_with_paths(&headers, &filters, &paths()).unwrap(),
        expected_paths
    );
    let expected_wait =
        b"Waits on:\n0002\topen\tfeature\tTarget\n  Needed first.\nWaited on by:\n(none)\n";
    assert_eq!(query::wait_show(&records, id("1")).unwrap(), expected_wait);
    assert_eq!(
        query::wait_show_headers(&headers, id("1")).unwrap(),
        expected_wait
    );
    let expected_wait_paths = b"Waits on:\n0002\topen\tfeature\tTarget\t/ledger/target.md\n  Needed first.\nWaited on by:\n(none)\n";
    assert_eq!(
        query::wait_show_with_paths(&records, id("1"), &paths()).unwrap(),
        expected_wait_paths
    );
    assert_eq!(
        query::wait_show_headers_with_paths(&headers, id("1"), &paths()).unwrap(),
        expected_wait_paths
    );
}

#[test]
fn search_folds_unicode_requires_every_snippet_and_emits_each_line_once() {
    let (_directory, root) = fixture();
    let records = root.read_records().unwrap();
    let needles = SearchSnippets::parse(vec!["STRASSE".into(), "NEEDLE".into()]).unwrap();
    assert_eq!(
        query::search_parsed(&records, &Filters::default(), &needles).unwrap(),
        b"0001\topen\tfeature\tSource\n  15: Stra\xc3\x9fe needle\n"
    );
    assert_eq!(
        query::search_parsed_with_paths(&records, &Filters::default(), &needles, &paths()).unwrap(),
        b"0001\topen\tfeature\tSource\t/ledger/source.md\n  15: Stra\xc3\x9fe needle\n"
    );
    let unmatched = SearchSnippets::parse(vec!["STRASSE".into(), "absent".into()]).unwrap();
    assert!(
        query::search_parsed(&records, &Filters::default(), &unmatched)
            .unwrap()
            .is_empty()
    );
}

#[test]
fn lookup_preserves_raw_bytes_requested_order_and_identity_errors() {
    let (_directory, root) = fixture();
    let raw = b"Unstructured text\r\nwithout a final newline";
    fs::write(root.issues_dir().join("0001-source.md"), raw).unwrap();
    let records = root.read_records().unwrap();
    assert_eq!(query::show(&records, id("1")).unwrap(), raw);
    let ids = [id("2"), id("1"), id("2")];
    let expected = b"0002\t/ledger/target.md\n0001\t/ledger/source.md\n0002\t/ledger/target.md\n";
    assert_eq!(query::path(&records, &ids, &paths()).unwrap(), expected);
    assert_eq!(
        query::path_identities(&root.read_identities().unwrap(), &ids, &paths()).unwrap(),
        expected
    );
    assert!(matches!(
        query::show(&records, id("3")),
        Err(QueryError::MissingIssue(_))
    ));
    assert!(matches!(
        query::path(&records, &ids, &OutputPaths::default()),
        Err(QueryError::MissingOutputPath)
    ));
    fs::write(root.issues_dir().join("0001-duplicate.md"), raw).unwrap();
    let records = root.read_records().unwrap();
    assert!(matches!(
        query::show(&records, id("1")),
        Err(QueryError::DuplicateId(_))
    ));
    assert!(matches!(
        query::path_identities(&root.read_identities().unwrap(), &[id("1")], &paths()),
        Err(QueryError::DuplicateId(_))
    ));
}

#[test]
fn unresolved_relation_inconsistency_is_still_a_query_error() {
    let (_directory, root) = fixture();
    let target = root.issues_dir().join("0002-target.md");
    let text = fs::read_to_string(&target)
        .unwrap()
        .replace("- **Blocking:**\n  - #0001 — Source\n", "");
    fs::write(target, text).unwrap();
    let records = root.read_records().unwrap();
    assert!(matches!(
        query::list(&records, &Filters::default()),
        Err(QueryError::InconsistentRelation(_))
    ));
    assert!(matches!(
        query::wait_show(&records, id("1")),
        Err(QueryError::InconsistentRelation(_))
    ));
}

#[test]
fn relation_index_preserves_selection_and_validation_error_order() {
    let (_directory, root) = fixture();
    let target = fs::read(root.issues_dir().join("0002-target.md")).unwrap();
    fs::write(root.issues_dir().join("0002-duplicate.md"), &target).unwrap();
    let records = root.read_records().unwrap();
    assert!(
        matches!(query::list(&records, &Filters::default()), Err(QueryError::DuplicateId(value)) if value == id("2"))
    );
    // Filtered-out records must not make an unqueried duplicate eager-fatal.
    let filtered = Filters {
        status: Some(Status::Closed),
        ..Filters::default()
    };
    assert!(query::list(&records, &filtered).unwrap().is_empty());
    fs::write(root.issues_dir().join("0003-broken.md"), b"Broken").unwrap();
    let records = root.read_records().unwrap();
    assert!(matches!(
        query::list(&records, &Filters::default()),
        Err(QueryError::Record(_))
    ));
    // Wait inspection selects its subject before reporting unrelated parse errors.
    assert!(
        matches!(query::wait_show(&records, id("4")), Err(QueryError::MissingIssue(value)) if value == id("4"))
    );
    assert!(
        matches!(query::wait_show(&records, id("2")), Err(QueryError::DuplicateId(value)) if value == id("2"))
    );
}
