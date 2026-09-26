use isled::filesystem::{self, FilesystemError};
use isled::issue::IssueId;
use std::collections::BTreeSet;

pub(crate) fn read_selected_records(
    lock: &filesystem::StoreLock<'_>,
    ids: impl IntoIterator<Item = IssueId>,
) -> Result<Vec<filesystem::StoredRecord>, FilesystemError> {
    let mut records = Vec::new();
    let mut loaded = BTreeSet::new();
    for id in ids {
        if loaded.insert(id) {
            records.extend(lock.read_issue_records(id)?);
        }
    }
    Ok(records)
}
