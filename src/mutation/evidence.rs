//! Evidence entries and their pending-state check.
use super::completion::{SectionState, section_body};
use super::{
    MutationError, MutationPlan, SectionText, parse_record_document, plan_record_replacement,
    unique_record,
};
use crate::{filesystem::StoredRecord, issue::IssueId};

pub fn evidence_add(
    records: &[StoredRecord],
    id: IssueId,
    entries: &[SectionText],
) -> Result<MutationPlan, MutationError> {
    let record = unique_record(records, id)?;
    let mut parsed = parse_record_document(record)?;
    if entries.is_empty() {
        return Ok(MutationPlan::default());
    }
    if parsed.evidence == [b"Pending.".to_vec()] {
        parsed.evidence.clear();
    }
    if entries.iter().any(|entry| entry.as_bytes() == b"Pending.")
        && parsed.evidence.len() + entries.len() > 1
    {
        return Err(MutationError::MixedPendingEvidence);
    }
    parsed
        .evidence
        .extend(entries.iter().map(|entry| entry.as_bytes().to_vec()));
    Ok(plan_record_replacement(record, parsed))
}

pub(super) fn evidence_state(bytes: &[u8]) -> Result<SectionState, MutationError> {
    let value = section_body(bytes, b"\n\n## Evidence\n\n", b"\n\n## Outcome\n\n")
        .ok_or(MutationError::InvalidEvidence)?;
    if value == b"- Pending." {
        Ok(SectionState::Pending)
    } else {
        Ok(SectionState::Recorded)
    }
}
