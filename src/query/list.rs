//! Metadata listing and its shared summary row format.

use super::filters::matches_filters;
use super::records::{ViewIndex, header_sources, parse_source_views, record_sources};
use super::{Filters, OutputPaths, QueryError};
use crate::filesystem::{StoredHeader, StoredRecord};
use crate::record::RecordView;

pub fn list(records: &[StoredRecord], filters: &Filters) -> Result<Vec<u8>, QueryError> {
    list_sources(record_sources(records), filters, None)
}

pub fn list_with_paths(
    records: &[StoredRecord],
    filters: &Filters,
    paths: &OutputPaths,
) -> Result<Vec<u8>, QueryError> {
    list_sources(record_sources(records), filters, Some(paths))
}

pub fn list_headers(headers: &[StoredHeader], filters: &Filters) -> Result<Vec<u8>, QueryError> {
    list_sources(header_sources(headers), filters, None)
}

pub fn list_headers_with_paths(
    headers: &[StoredHeader],
    filters: &Filters,
    paths: &OutputPaths,
) -> Result<Vec<u8>, QueryError> {
    list_sources(header_sources(headers), filters, Some(paths))
}

fn list_sources<'a>(
    sources: impl IntoIterator<Item = &'a StoredRecord>,
    filters: &Filters,
    paths: Option<&OutputPaths>,
) -> Result<Vec<u8>, QueryError> {
    let views = parse_source_views(sources)?;
    let index = ViewIndex::new(&views);
    let mut selected = Vec::new();
    for view in &views {
        if !matches_filters(view, filters, &index)? {
            continue;
        }
        selected.push((
            view,
            paths.map(|value| value.get(view.filename())).transpose()?,
        ));
    }
    if filters.oldest_first {
        selected.sort_by_key(|(view, _)| {
            let since = view.work_state().and_then(|state| state.since());
            (since.is_none(), since, view.id())
        });
    }
    let mut output = Vec::new();
    for (view, path) in selected
        .into_iter()
        .take(filters.limit.unwrap_or(usize::MAX))
    {
        append_summary(&mut output, view, path)?;
    }
    Ok(output)
}

pub(super) fn append_summary(
    output: &mut Vec<u8>,
    view: &RecordView<'_>,
    path: Option<&[u8]>,
) -> Result<(), QueryError> {
    output.extend_from_slice(view.id().to_string().as_bytes());
    output.push(b'\t');
    output.extend_from_slice(view.status().as_str().as_bytes());
    output.push(b'\t');
    output.extend_from_slice(view.kind().as_str().as_bytes());
    output.push(b'\t');
    output.extend_from_slice(view.title());
    if let Some(path) = path {
        output.push(b'\t');
        output.extend_from_slice(path);
    }
    output.push(b'\n');
    Ok(())
}
