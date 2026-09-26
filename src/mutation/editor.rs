//! Complete issue drafts, dependency-aware freshness and replacement planning.
mod draft;
mod relations;
use super::{MutationPlan, Replacement};
use crate::{
    filesystem::StoredRecord,
    issue::{IssueId, Status},
    record::RecordDocument,
    wait_graph::Adjacency,
};
pub use draft::{Draft, FieldError, Relation, ValidatedDraft};
use serde::Serialize;
use std::collections::BTreeMap;

pub(crate) type Records = BTreeMap<IssueId, StoredRecord>;
#[derive(Serialize)]
pub struct Editable {
    pub id: String,
    pub filename: String,
    pub status: String,
    pub version: String,
    pub source: String,
    pub draft: Draft,
}
pub(crate) fn document(records: &Records, id: IssueId) -> Result<&RecordDocument, FieldError> {
    let record = records
        .get(&id)
        .ok_or_else(|| FieldError::new("relations", format!("Issue {id} is missing")))?;
    record
        .document()
        .map_err(|e| FieldError::new("record", format!("Issue {id}: {e}")))
}
pub(crate) fn editable(records: &Records, id: IssueId) -> Result<Editable, FieldError> {
    let document = document(records, id)?;
    let issue = &document.issue;
    let blocking = issue
        .blocking
        .iter()
        .map(|edge| {
            let neighbor = self::document(records, edge.target)?;
            let reverse = neighbor
                .issue
                .waits
                .iter()
                .find(|r| r.target == id)
                .ok_or_else(|| {
                    FieldError::new("blocking", "Incomplete dependency; use wait repair first")
                })?;
            Ok(Relation {
                id: edge.target.to_string(),
                reason: text(&reverse.reason),
            })
        })
        .collect::<Result<Vec<_>, FieldError>>()?;
    let source = text(records[&id].bytes());
    let version = serde_json::to_string(&(&source, &blocking)).expect("serializable strings");
    Ok(Editable {
        id: id.to_string(),
        filename: text(records[&id].filename()),
        status: issue.status.as_str().into(),
        version,
        source,
        draft: Draft {
            title: text(&issue.title),
            kind: issue.kind.to_string(),
            tags: issue.tags.iter().map(|v| v.as_str().into()).collect(),
            statement: text(&document.statement),
            evidence: document.evidence.iter().map(|e| text(e)).collect(),
            outcome: text(&document.outcome),
            waiting_on: issue
                .waits
                .iter()
                .map(|r| Relation {
                    id: r.target.to_string(),
                    reason: text(&r.reason),
                })
                .collect(),
            blocking,
        },
    })
}
fn text(bytes: &[u8]) -> String {
    String::from_utf8(bytes.to_vec()).expect("validated record UTF-8")
}

pub(crate) fn plan(
    records: &Records,
    id: IssueId,
    draft: ValidatedDraft,
    graph: &Adjacency,
    adding: bool,
) -> Result<MutationPlan, FieldError> {
    let original = document(records, id)?;
    let mut updated = original.clone();
    updated.issue.title = draft.draft.title.into_bytes();
    updated.issue.kind = draft.kind;
    updated.issue.tags = draft.tags;
    updated.statement = draft.draft.statement.into_bytes();
    updated.evidence = draft
        .draft
        .evidence
        .into_iter()
        .map(String::into_bytes)
        .collect();
    updated.outcome = draft.draft.outcome.into_bytes();
    let edited_id = id;
    let documents = relations::update(
        records,
        original.clone(),
        updated,
        &draft.waiting,
        &draft.blocking,
        graph,
    )?;
    let replacements = documents
        .into_iter()
        .filter_map(|(id, doc)| {
            let record = &records[&id];
            // A semantically unchanged record keeps its authored representation exactly.
            match record.document() {
                Ok(old) if *old == doc && !(adding && id == edited_id) => None,
                _ => Some(Replacement::rendered(record.filename().to_vec(), doc)),
            }
        })
        .collect();
    Ok(MutationPlan { replacements })
}
pub(crate) fn closed(records: &Records, id: IssueId) -> bool {
    document(records, id).is_ok_and(|d| d.issue.status == Status::Closed)
}

/// Apply the existing closure operation to the planned draft before any publication.
pub(crate) fn close_plan(
    records: &Records,
    id: IssueId,
    mut plan: MutationPlan,
) -> Result<MutationPlan, FieldError> {
    if closed(records, id) {
        return Err(FieldError::new(
            "record",
            "Issue is already closed; edit it without Close",
        ));
    }
    let target = plan
        .replacements
        .iter()
        .find(|r| r.record().issue().is_ok_and(|issue| issue.id() == id))
        .map(|r| r.record())
        .unwrap_or(&records[&id]);
    let closure = super::close_issue(std::slice::from_ref(target), id, None).map_err(|error| {
        let field = match error {
            super::MutationError::EvidencePending => "evidence",
            super::MutationError::OutcomePending => "outcome",
            _ => "record",
        };
        FieldError::new(field, error)
    })?;
    let filename = target.filename().to_vec();
    plan.replacements.retain(|r| r.filename() != filename);
    plan.replacements.extend(closure.plan.replacements);
    plan.replacements
        .sort_by(|a, b| a.filename().cmp(b.filename()));
    Ok(plan)
}
