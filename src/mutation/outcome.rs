//! Current outcome replacement and its pending-state check.
use super::completion::{SectionState, find_bytes};
use super::{
    MutationError, MutationPlan, SectionText, parse_record_document, plan_record_replacement,
    unique_record,
};
use crate::{filesystem::StoredRecord, issue::IssueId};

pub fn outcome_set(
    records: &[StoredRecord],
    id: IssueId,
    text: &SectionText,
) -> Result<MutationPlan, MutationError> {
    let record = unique_record(records, id)?;
    let mut parsed = parse_record_document(record)?;
    parsed.outcome = text.as_bytes().to_vec();
    Ok(plan_record_replacement(record, parsed))
}

pub(super) fn outcome_state(bytes: &[u8]) -> Result<SectionState, MutationError> {
    let start = find_bytes(bytes, b"\n\n## Outcome\n\n").ok_or(MutationError::InvalidOutcome)?
        + b"\n\n## Outcome\n\n".len();
    let value = bytes[start..]
        .strip_suffix(b"\n")
        .unwrap_or(&bytes[start..]);
    if value == b"Pending." {
        Ok(SectionState::Pending)
    } else if value.is_empty()
        || value.windows(2).any(|part| part == b"\n\n")
        || value
            .split(|byte| *byte == b'\n')
            .any(|line| line.is_empty())
    {
        Err(MutationError::InvalidOutcome)
    } else {
        Ok(SectionState::Recorded)
    }
}
