//! External callers compose typed core operations with locked publication.
use isled::{
    filesystem::{FilesystemError, ProjectRoot, initialize_ledger},
    issue::{CreatedDate, IssueId, Name, Status},
    mutation::{
        AddStatementText, MutationPlan, SectionText, TitleText, add_record_validated, evidence_add,
    },
    record::IssueRecord,
};
use std::fs;
use tempfile::tempdir;

#[test]
fn creation_preserves_parsed_data_and_rejects_replayed_ids_without_writes() {
    let directory = tempdir().unwrap();
    let issues = initialize_ledger(directory.path()).unwrap();
    let root = ProjectRoot::explicit(directory.path()).unwrap();
    let lock = root.acquire_lock().unwrap();
    let id = lock.next_available_id().unwrap();
    let replacement = add_record_validated(
        id,
        &Name::parse(b"example").unwrap(),
        &Name::parse(b"feature").unwrap(),
        &TitleText::parse("Example café").unwrap(),
        &AddStatementText::parse("Body café").unwrap(),
        &CreatedDate::try_parse(b"2026-09-05").unwrap(),
        &[],
    );
    let parsed = IssueRecord::parse(replacement.filename(), replacement.bytes().to_vec()).unwrap();
    assert_eq!(parsed.issue().id(), id);
    assert_eq!(parsed.issue().title(), "Example café".as_bytes());
    assert_eq!(parsed.issue().status(), Status::Open);
    lock.add(&replacement).unwrap();
    let records = lock.read_issue_records(id).unwrap();
    assert!(
        evidence_add(&records, id, &[])
            .unwrap()
            .replacements()
            .is_empty()
    );
    let pending = SectionText::try_parse("Pending.").unwrap();
    let concrete = SectionText::try_parse("Checked.").unwrap();
    assert!(evidence_add(&records, id, &[pending, concrete]).is_err());
    assert_eq!(
        fs::read(issues.join("0001-example.md")).unwrap(),
        parsed.bytes()
    );
    assert_eq!(fs::read(issues.join(".next-id")).unwrap(), b"2\n");
    assert!(matches!(
        lock.add(&replacement),
        Err(FilesystemError::UnexpectedCreationId { .. })
    ));
    assert_eq!(fs::read(issues.join(".next-id")).unwrap(), b"2\n");
    assert_eq!(
        fs::read(issues.join("0001-example.md")).unwrap(),
        parsed.bytes()
    );
    let empty = MutationPlan::default();
    assert!(empty.replacements().is_empty());
    lock.publish(&empty).unwrap();
    lock.finish().unwrap();
}

#[test]
fn creation_cannot_skip_high_water_and_last_id_exhausts_allocation() {
    let directory = tempdir().unwrap();
    let issues = initialize_ledger(directory.path()).unwrap();
    let root = ProjectRoot::explicit(directory.path()).unwrap();
    let lock = root.acquire_lock().unwrap();
    let replacement = add_record_validated(
        IssueId::new(9999).unwrap(),
        &Name::parse(b"last").unwrap(),
        &Name::parse(b"feature").unwrap(),
        &TitleText::parse("Last").unwrap(),
        &AddStatementText::parse("Body").unwrap(),
        &CreatedDate::try_parse(b"2026-09-05").unwrap(),
        &[],
    );
    assert!(matches!(
        lock.add(&replacement),
        Err(FilesystemError::UnexpectedCreationId { .. })
    ));
    assert!(!issues.join("9999-last.md").exists());
    assert_eq!(fs::read(issues.join(".next-id")).unwrap(), b"1\n");
    fs::write(issues.join(".next-id"), b"9999\n").unwrap();
    lock.add(&replacement).unwrap();
    assert_eq!(fs::read(issues.join(".next-id")).unwrap(), b"10000\n");
    assert!(lock.next_available_id().is_err());
    lock.finish().unwrap();
}
