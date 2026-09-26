use crate::filesystem::StoredRecord;
use crate::issue::IssueId;
use crate::record::RecordDocument;

use super::MutationError;

pub(super) fn parse_record_document(
    record: &StoredRecord,
) -> Result<RecordDocument, MutationError> {
    record.document().cloned().map_err(MutationError::Record)
}

pub(super) fn unique_record(
    records: &[StoredRecord],
    id: IssueId,
) -> Result<&StoredRecord, MutationError> {
    let mut selected = None;
    for record in records {
        let (record_id, _) = crate::record::parse_filename(record.filename())?;
        if record_id == id && selected.replace(record).is_some() {
            return Err(MutationError::DuplicateId(id));
        }
    }
    selected.ok_or(MutationError::MissingIssue(id))
}

pub(super) fn parse_record_view(
    record: &StoredRecord,
) -> Result<&crate::issue::Issue, MutationError> {
    record.header().map_err(MutationError::Record)
}
