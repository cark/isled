//! Typed query criteria and record matching.

use super::wait::validated_active_waits;
use super::{QueryError, records::ViewIndex};
use crate::issue::{IssueId, Name, Status, Tag};
use crate::record::RecordView;

#[derive(Clone, Debug, Default)]
pub struct Filters {
    pub status: Option<Status>,
    pub kind: Option<Name>,
    pub tags: Vec<Tag>,
    pub waiting: Option<bool>,
    pub waiting_on: Option<IssueId>,
}

pub(super) fn matches_filters(
    view: &RecordView<'_>,
    filters: &Filters,
    views: &ViewIndex<'_>,
) -> Result<bool, QueryError> {
    let status = view.status();
    let kind = view.kind();
    if filters.status.is_some_and(|wanted| wanted != status)
        || filters.kind.as_ref().is_some_and(|wanted| wanted != kind)
        || !view.has_tags(&filters.tags)
    {
        return Ok(false);
    }
    let waits = validated_active_waits(view, views)?;
    if filters
        .waiting
        .is_some_and(|wanted| wanted != !waits.is_empty())
    {
        return Ok(false);
    }
    if filters
        .waiting_on
        .is_some_and(|target| !waits.iter().any(|relation| relation.target == target))
    {
        return Ok(false);
    }
    Ok(true)
}
