//! Borrowed record and header views for pure queries.

use super::QueryError;
use crate::filesystem::{StoredHeader, StoredRecord};
use crate::issue::IssueId;
use crate::record::RecordView;
use std::collections::BTreeMap;

pub(super) fn parse_record_views(
    records: &[StoredRecord],
) -> Result<Vec<RecordView<'_>>, QueryError> {
    records
        .iter()
        .map(|record| RecordView::retained(record).map_err(QueryError::Record))
        .collect()
}

pub(super) fn record_sources(
    records: &[StoredRecord],
) -> impl Iterator<Item = &StoredRecord> + Clone {
    records.iter()
}

pub(super) fn header_sources(
    headers: &[StoredHeader],
) -> impl Iterator<Item = &StoredRecord> + Clone {
    headers.iter().map(StoredHeader::record)
}

pub(super) fn parse_source_views<'a>(
    sources: impl IntoIterator<Item = &'a StoredRecord>,
) -> Result<Vec<RecordView<'a>>, QueryError> {
    sources
        .into_iter()
        .map(|record| RecordView::retained(record).map_err(QueryError::Record))
        .collect()
}

pub(super) fn unique_source<'a>(
    sources: impl IntoIterator<Item = &'a StoredRecord>,
    id: IssueId,
) -> Result<&'a StoredRecord, QueryError> {
    let mut matching = sources
        .into_iter()
        .filter(|source| RecordView::retained(source).is_ok_and(|view| view.id() == id));
    let source = matching.next().ok_or(QueryError::MissingIssue(id))?;
    if matching.next().is_some() {
        return Err(QueryError::DuplicateId(id));
    }
    Ok(source)
}

/// Duplicate identities are recorded here but reported only when selected.
pub(super) struct ViewIndex<'a>(BTreeMap<IssueId, Option<&'a RecordView<'a>>>);

impl<'a> ViewIndex<'a> {
    pub(super) fn new(views: &'a [RecordView<'a>]) -> Self {
        let mut index = BTreeMap::new();
        for view in views {
            index
                .entry(view.id())
                .and_modify(|entry| *entry = None)
                .or_insert(Some(view));
        }
        Self(index)
    }

    pub(super) fn unique(&self, id: IssueId) -> Result<&'a RecordView<'a>, QueryError> {
        match self.0.get(&id) {
            Some(Some(view)) => Ok(view),
            Some(None) => Err(QueryError::DuplicateId(id)),
            None => Err(QueryError::MissingIssue(id)),
        }
    }
}
