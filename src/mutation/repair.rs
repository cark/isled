//! Explicit choices to complete or remove an existing relation.
use super::{MutationError, MutationPlan, parse_record_document, plan_document_replacements};
use crate::{
    filesystem::StoredRecord,
    issue::{IssueId, IssueRelation, WaitReason, WaitRelation},
};

pub fn relation_repair(
    records: &[StoredRecord],
    source: IssueId,
    target: IssueId,
    complete: bool,
    reason: Option<&WaitReason>,
) -> Result<MutationPlan, MutationError> {
    let mut documents = records
        .iter()
        .map(|r| Ok((r, parse_record_document(r)?)))
        .collect::<Result<Vec<_>, MutationError>>()?;
    let mut seen = std::collections::BTreeSet::new();
    for (_, doc) in &documents {
        if !seen.insert(doc.issue.id) {
            return Err(MutationError::DuplicateId(doc.issue.id));
        }
    }
    let source_doc = documents.iter().find(|(_, d)| d.issue.id == source);
    let target_doc = documents.iter().find(|(_, d)| d.issue.id == target);
    if complete && (source_doc.is_none() || target_doc.is_none()) {
        return Err(MutationError::MissingWait { source, target });
    }
    let source_title = source_doc.map(|(_, d)| d.issue.title.clone());
    let target_title = target_doc.map(|(_, d)| d.issue.title.clone());
    let saved_reason = source_doc
        .and_then(|(_, d)| d.issue.waits.iter().find(|r| r.target == target))
        .map(|r| r.reason.clone());
    let has_mirror =
        target_doc.is_some_and(|(_, d)| d.issue.blocking.iter().any(|r| r.target == source));
    if complete && saved_reason.is_none() && !has_mirror {
        return Err(MutationError::MissingWait { source, target });
    }
    if complete && saved_reason.is_none() && reason.is_none() {
        return Err(MutationError::RepairReasonRequired);
    }
    for (_, doc) in &mut documents {
        if doc.issue.id == source {
            doc.issue.waits.retain(|r| r.target != target);
            if complete {
                doc.issue.waits.push(WaitRelation {
                    target,
                    title: target_title.clone().unwrap(),
                    reason: saved_reason
                        .clone()
                        .unwrap_or_else(|| reason.unwrap().as_bytes().to_vec()),
                });
            }
            doc.issue.waits.sort_by_key(|r| r.target);
        }
        if doc.issue.id == target {
            doc.issue.blocking.retain(|r| r.target != source);
            if complete {
                doc.issue.blocking.push(IssueRelation {
                    target: source,
                    title: source_title.clone().unwrap(),
                });
            }
            doc.issue.blocking.sort_by_key(|r| r.target);
        }
    }
    Ok(plan_document_replacements(documents))
}
