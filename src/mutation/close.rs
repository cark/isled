use crate::filesystem::StoredRecord;
use crate::issue::{IssueId, Status};

use super::{
    MutationError, MutationPlan, SectionText, parse_record_document, parse_record_view,
    plan_record_replacement, unique_record,
};
use super::{completion::SectionState, evidence::evidence_state, outcome::outcome_state};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CloseOutcome {
    pub plan: MutationPlan,
    pub was_closed: bool,
}

pub fn close_issue(
    records: &[StoredRecord],
    id: IssueId,
    outcome: Option<&SectionText>,
) -> Result<CloseOutcome, MutationError> {
    let target = unique_record(records, id)?;
    let was_closed = parse_record_view(target)?.status() == Status::Closed;
    if evidence_state(target.bytes())? == SectionState::Pending {
        return Err(MutationError::EvidencePending);
    }
    let outcome_state = outcome_state(target.bytes())?;
    match (outcome, outcome_state) {
        (Some(_), SectionState::Recorded) => {
            return Err(MutationError::OutcomeAlreadyRecorded);
        }
        (None, SectionState::Pending) => return Err(MutationError::OutcomePending),
        _ => {}
    }
    let mut document = parse_record_document(target)?;
    if document.work_log.active().is_some() {
        document.work_log.stop(crate::work_log::WorkTime::now())?;
        document.work_log_source = None;
    }
    document.issue.work_state = None;
    document.issue.status = Status::Closed;
    document.issue.tags.retain(|tag| !tag.is_priority());
    if let Some(outcome) = outcome {
        document.outcome = outcome.as_bytes().to_vec();
    }
    Ok(CloseOutcome {
        plan: plan_record_replacement(target, document),
        was_closed,
    })
}
