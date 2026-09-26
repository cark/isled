//! Unique issue lookup as raw record bytes or requested paths.

use super::QueryError;
use crate::filesystem::{StoredIdentity, StoredRecord};
use crate::issue::IssueId;
use std::collections::BTreeMap;

#[derive(Clone, Debug, Default)]
pub struct OutputPaths(BTreeMap<Vec<u8>, Vec<u8>>);

impl OutputPaths {
    pub fn new(entries: impl IntoIterator<Item = (Vec<u8>, Vec<u8>)>) -> Self {
        Self(entries.into_iter().collect())
    }

    pub(super) fn get(&self, filename: &[u8]) -> Result<&[u8], QueryError> {
        self.0
            .get(filename)
            .map(Vec::as_slice)
            .ok_or(QueryError::MissingOutputPath)
    }
}

pub fn path_identities(
    identities: &[StoredIdentity],
    ids: &[IssueId],
    paths: &OutputPaths,
) -> Result<Vec<u8>, QueryError> {
    let mut resolved = Vec::new();
    for id in ids {
        let identity = unique_identity(identities, *id)?;
        resolved.push((*id, paths.get(identity.filename())?));
    }
    render_paths(&resolved)
}

pub fn show(records: &[StoredRecord], id: IssueId) -> Result<Vec<u8>, QueryError> {
    let record = unique_record(records, id)?;
    Ok(record.bytes().to_vec())
}

pub fn path(
    records: &[StoredRecord],
    ids: &[IssueId],
    paths: &OutputPaths,
) -> Result<Vec<u8>, QueryError> {
    let mut resolved = Vec::new();
    for id in ids {
        let record = unique_record(records, *id)?;
        resolved.push((*id, paths.get(record.filename())?));
    }
    render_paths(&resolved)
}

fn render_paths(resolved: &[(IssueId, &[u8])]) -> Result<Vec<u8>, QueryError> {
    let mut output = Vec::new();
    for (id, path) in resolved {
        output.extend_from_slice(id.to_string().as_bytes());
        output.push(b'\t');
        output.extend_from_slice(path);
        output.push(b'\n');
    }
    Ok(output)
}

fn unique_record(records: &[StoredRecord], id: IssueId) -> Result<&StoredRecord, QueryError> {
    let mut selected = None;
    for record in records {
        let (record_id, _) = crate::record::parse_filename(record.filename())?;
        if record_id == id && selected.replace(record).is_some() {
            return Err(QueryError::DuplicateId(id));
        }
    }
    selected.ok_or(QueryError::MissingIssue(id))
}

fn unique_identity(
    identities: &[StoredIdentity],
    id: IssueId,
) -> Result<&StoredIdentity, QueryError> {
    let mut matching = identities.iter().filter(|identity| identity.id() == id);
    let identity = matching.next().ok_or(QueryError::MissingIssue(id))?;
    if matching.next().is_some() {
        return Err(QueryError::DuplicateId(id));
    }
    Ok(identity)
}
