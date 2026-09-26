use crate::filesystem::StoredRecord;
use crate::issue::{IssueId, IssueRelation, Status, WaitReason, WaitRelation};
use crate::wait_graph::{self, Adjacency};

use super::{
    MutationError, MutationPlan, parse_record_document, parse_record_view,
    plan_document_replacements, unique_record,
};

/// Plan from fresh endpoint records and an ID-typed cached graph. External graph
/// changes outside the refreshed neighborhood have best-effort freshness.
pub fn wait_add_indexed(
    records: &[StoredRecord],
    graph: &Adjacency,
    source: IssueId,
    target: IssueId,
    reason: &WaitReason,
) -> Result<MutationPlan, MutationError> {
    if source == target {
        return Err(MutationError::Cycle { source, target });
    }
    let source_record = unique_record(records, source)?;
    let source_view = parse_record_view(source_record)?;
    if source_view.status() != Status::Open {
        return Err(MutationError::ClosedWaitSource(source));
    }
    let target_record = unique_record(records, target)?;
    if parse_record_view(target_record)?.status() != Status::Open {
        return Err(MutationError::ClosedWaitTarget(target));
    }
    if source_view
        .waits()
        .iter()
        .any(|relation| relation.target == target)
    {
        return Err(MutationError::DuplicateWait { source, target });
    }
    if wait_graph::reaches(graph, target, source) {
        return Err(MutationError::Cycle { source, target });
    }
    add_mirrored_wait(source_record, target_record, reason)
}

pub fn wait_remove(
    records: &[StoredRecord],
    source: IssueId,
    target: IssueId,
) -> Result<MutationPlan, MutationError> {
    let source_record = unique_record(records, source)?;
    let target_record = unique_record(records, target)?;
    let source_view = parse_record_view(source_record)?;
    let target_view = parse_record_view(target_record)?;
    let source_title = source_view.title();
    let relation = source_view
        .waits()
        .iter()
        .find(|relation| relation.target == target)
        .ok_or(MutationError::MissingWait { source, target })?;
    if relation.title.as_slice() != target_view.title()
        || !target_view
            .blocking()
            .iter()
            .any(|reverse| reverse.target == source && reverse.title.as_slice() == source_title)
    {
        return Err(MutationError::InvalidGraphSource {
            operation: "remove wait",
            source,
        });
    }
    let mut source_document = parse_record_document(source_record)?;
    let mut target_document = parse_record_document(target_record)?;
    source_document
        .issue
        .waits
        .retain(|relation| relation.target != target);
    target_document
        .issue
        .blocking
        .retain(|relation| relation.target != source);
    Ok(plan_document_replacements([
        (source_record, source_document),
        (target_record, target_document),
    ]))
}

fn add_mirrored_wait(
    source: &StoredRecord,
    target: &StoredRecord,
    reason: &WaitReason,
) -> Result<MutationPlan, MutationError> {
    let mut source_document = parse_record_document(source)?;
    let mut target_document = parse_record_document(target)?;
    source_document.issue.waits.push(WaitRelation {
        target: target_document.issue.id,
        title: target_document.issue.title.clone(),
        reason: reason.as_bytes().to_vec(),
    });
    target_document.issue.blocking.push(IssueRelation {
        target: source_document.issue.id,
        title: source_document.issue.title.clone(),
    });
    source_document
        .issue
        .waits
        .sort_by_key(|relation| relation.target);
    target_document
        .issue
        .blocking
        .sort_by_key(|relation| relation.target);
    Ok(plan_document_replacements([
        (source, source_document),
        (target, target_document),
    ]))
}
