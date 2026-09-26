use crate::filesystem::StoredRecord;
use crate::issue::{IssueId, Status, Tag};

use super::{
    MutationError, MutationPlan, parse_record_document, parse_record_view, plan_record_replacement,
    unique_record,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PriorityOutcome {
    Changed,
    AlreadySet,
}

pub fn tag_add(
    records: &[StoredRecord],
    id: IssueId,
    additions: &[Tag],
) -> Result<MutationPlan, MutationError> {
    let record = unique_record(records, id)?;
    let view = parse_record_view(record)?;
    let priority = additions.iter().find(|tag| tag.is_priority());
    if priority.is_some() && view.status() != Status::Open {
        return Err(MutationError::ClosedPriority);
    }
    let mut document = parse_record_document(record)?;
    if let Some(priority) = priority {
        document.issue.tags.retain(|tag| !tag.is_priority());
        document.issue.tags.push(priority.clone());
    }
    for addition in additions {
        if !document.issue.tags.contains(addition) {
            document.issue.tags.push(addition.clone());
        }
    }
    Ok(plan_record_replacement(record, document))
}

pub fn tag_remove(
    records: &[StoredRecord],
    id: IssueId,
    removals: &[Tag],
) -> Result<MutationPlan, MutationError> {
    let record = unique_record(records, id)?;
    let mut document = parse_record_document(record)?;
    if !document
        .issue
        .tags
        .iter()
        .any(|existing| removals.contains(existing))
    {
        return Ok(MutationPlan::default());
    }
    document.issue.tags.retain(|tag| !removals.contains(tag));
    Ok(plan_record_replacement(record, document))
}

pub fn priority_set(
    records: &[StoredRecord],
    id: IssueId,
    priority: &Tag,
) -> Result<(MutationPlan, PriorityOutcome), MutationError> {
    let record = unique_record(records, id)?;
    let view = parse_record_view(record)?;
    if view.status() != Status::Open {
        return Err(MutationError::ClosedPriority);
    }
    let mut document = parse_record_document(record)?;
    let priorities = document
        .issue
        .tags
        .iter()
        .filter(|tag| tag.is_priority())
        .collect::<Vec<_>>();
    if priorities.len() == 1 && priorities[0] == priority {
        return Ok((MutationPlan::default(), PriorityOutcome::AlreadySet));
    }
    document.issue.tags.retain(|tag| !tag.is_priority());
    document.issue.tags.push(priority.clone());
    Ok((
        plan_record_replacement(record, document),
        PriorityOutcome::Changed,
    ))
}

pub fn priority_clear(
    records: &[StoredRecord],
    id: IssueId,
) -> Result<MutationPlan, MutationError> {
    let record = unique_record(records, id)?;
    let mut document = parse_record_document(record)?;
    if !document.issue.tags.iter().any(Tag::is_priority) {
        return Ok(MutationPlan::default());
    }
    document.issue.tags.retain(|tag| !tag.is_priority());
    Ok(plan_record_replacement(record, document))
}
