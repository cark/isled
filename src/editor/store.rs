//! Scoped record reads and graph inputs for draft operations.
use crate::{
    cache::Cache,
    filesystem::{StoreLock, StoredRecord},
    issue::{CreatedDate, IssueId, Name},
    mutation::{
        self, AddStatementText, TitleText,
        editor::{FieldError, Records, ValidatedDraft},
    },
    wait_graph::Adjacency,
};
use std::collections::{BTreeMap, BTreeSet};
pub(super) fn error(error: impl ToString) -> FieldError {
    FieldError {
        code: "operational",
        field: "record".into(),
        message: error.to_string(),
    }
}
pub(super) fn load_records(
    lock: &StoreLock<'_>,
    id: Option<IssueId>,
    draft: Option<&ValidatedDraft>,
) -> Result<Records, FieldError> {
    let identities: BTreeMap<_, _> = lock
        .read_identities()
        .map_err(error)?
        .into_iter()
        .map(|v| (v.id(), v))
        .collect();
    let mut needed: BTreeSet<_> = id
        .into_iter()
        .chain(draft.into_iter().flat_map(ValidatedDraft::neighbors))
        .collect();
    let mut records = Records::new();
    if let Some(id) = id {
        load(lock, &identities, &mut records, id)?;
        let issue = records[&id].issue().map_err(error)?;
        needed.extend(issue.waits().iter().map(|r| r.target));
        needed.extend(issue.blocking().iter().map(|r| r.target));
    }
    for id in needed {
        load(lock, &identities, &mut records, id)?;
    }
    Ok(records)
}
fn load(
    lock: &StoreLock<'_>,
    identities: &BTreeMap<IssueId, crate::filesystem::StoredIdentity>,
    records: &mut Records,
    id: IssueId,
) -> Result<(), FieldError> {
    if records.contains_key(&id) {
        return Ok(());
    }
    let name = identities
        .get(&id)
        .ok_or_else(|| FieldError::new("relations", format!("Issue {id} is missing")))?;
    let record = lock
        .load_file(name.filename())
        .map_err(error)?
        .record()
        .map_err(error)?;
    record.issue().map_err(error)?;
    records.insert(id, record);
    Ok(())
}
pub(super) fn graph(
    lock: &StoreLock<'_>,
    ids: impl Iterator<Item = IssueId>,
) -> Result<Adjacency, FieldError> {
    let mut cache = Cache::open_for_editor(lock).map_err(error)?;
    for id in ids {
        // The planned new identity is not in the store yet.
        if cache.filename(id).is_ok() {
            cache.refresh(Some(id)).map_err(error)?;
        }
    }
    cache.report_warnings();
    cache.adjacency().map_err(error)
}
pub(super) fn blank_record(
    id: IssueId,
    draft: &ValidatedDraft,
) -> Result<StoredRecord, FieldError> {
    let date = chrono::Local::now().format("%Y-%m-%d").to_string();
    let record = mutation::add_record_validated(
        id,
        &draft.slug(),
        &Name::try_parse(b"task").expect("literal"),
        &TitleText::parse("New issue").expect("literal"),
        &AddStatementText::parse("New issue").expect("literal"),
        &CreatedDate::try_parse(date.as_bytes()).map_err(error)?,
        &[],
    );
    Ok(record.record().clone())
}
