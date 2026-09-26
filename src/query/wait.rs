//! Direct wait inspection and relation consistency checks.

use super::list::append_summary;
use super::records::{
    ViewIndex, header_sources, parse_source_views, record_sources, unique_source,
};
use super::{OutputPaths, QueryError};
use crate::filesystem::{StoredHeader, StoredRecord};
use crate::issue::{IssueId, Status, WaitRelation};
use crate::record::RecordView;

pub fn wait_show(records: &[StoredRecord], subject: IssueId) -> Result<Vec<u8>, QueryError> {
    render_source_waits(record_sources(records), subject, None)
}

pub fn wait_show_with_paths(
    records: &[StoredRecord],
    subject: IssueId,
    paths: &OutputPaths,
) -> Result<Vec<u8>, QueryError> {
    render_source_waits(record_sources(records), subject, Some(paths))
}

pub fn wait_show_headers(
    headers: &[StoredHeader],
    subject: IssueId,
) -> Result<Vec<u8>, QueryError> {
    render_source_waits(header_sources(headers), subject, None)
}

pub fn wait_show_headers_with_paths(
    headers: &[StoredHeader],
    subject: IssueId,
    paths: &OutputPaths,
) -> Result<Vec<u8>, QueryError> {
    render_source_waits(header_sources(headers), subject, Some(paths))
}

fn render_source_waits<'a>(
    sources: impl Iterator<Item = &'a StoredRecord> + Clone,
    subject: IssueId,
    paths: Option<&OutputPaths>,
) -> Result<Vec<u8>, QueryError> {
    unique_source(sources.clone(), subject)?;
    let views = parse_source_views(sources)?;
    let index = ViewIndex::new(&views);
    let subject_view = index.unique(subject)?;
    validate_wait_graph(&views, &index)?;

    let mut outgoing = subject_view
        .waits()
        .iter()
        .map(|relation| (relation.target, relation.reason.as_slice()))
        .collect::<Vec<_>>();
    let mut incoming = Vec::new();
    for view in &views {
        for relation in view.waits() {
            if relation.target == subject {
                incoming.push((view.id(), relation.reason.as_slice()));
            }
        }
    }
    outgoing.sort();
    incoming.sort();

    let mut output = b"Waits on:\n".to_vec();
    append_relations(&mut output, &index, &outgoing, paths)?;
    output.extend_from_slice(b"Waited on by:\n");
    append_relations(&mut output, &index, &incoming, paths)?;
    Ok(output)
}

pub(super) fn validated_active_waits<'a>(
    source: &'a RecordView<'_>,
    views: &ViewIndex<'_>,
) -> Result<Vec<&'a WaitRelation>, QueryError> {
    let mut active = Vec::new();
    let source_title = source.title();
    for relation in source.waits() {
        let target = views.unique(relation.target)?;
        let reciprocal = target.blocking().iter().any(|reverse| {
            reverse.target == source.id() && reverse.title.as_slice() == source_title
        });
        if relation.title.as_slice() != target.title() || !reciprocal {
            return Err(QueryError::InconsistentRelation(source.id()));
        }
        if target.status() == Status::Open {
            active.push(relation);
        }
    }
    for relation in source.blocking() {
        let blocked = views.unique(relation.target)?;
        if relation.title.as_slice() != blocked.title()
            || !blocked
                .waits()
                .iter()
                .any(|reverse| reverse.target == source.id())
        {
            return Err(QueryError::InconsistentRelation(source.id()));
        }
    }
    Ok(active)
}

fn validate_wait_graph(views: &[RecordView<'_>], index: &ViewIndex<'_>) -> Result<(), QueryError> {
    for view in views {
        validated_active_waits(view, index)?;
    }
    Ok(())
}

fn append_relations(
    output: &mut Vec<u8>,
    views: &ViewIndex<'_>,
    relations: &[(IssueId, &[u8])],
    paths: Option<&OutputPaths>,
) -> Result<(), QueryError> {
    if relations.is_empty() {
        output.extend_from_slice(b"(none)\n");
        return Ok(());
    }
    for (id, reason) in relations {
        let path = paths
            .map(|value| value.get(views.unique(*id)?.filename()))
            .transpose()?;
        append_summary(output, views.unique(*id)?, path)?;
        output.extend_from_slice(b"  ");
        output.extend_from_slice(reason);
        output.push(b'\n');
    }
    Ok(())
}
