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
    let mut output = Vec::new();
    let views = parse_source_views(sources)?;
    let index = ViewIndex::new(&views);
    for view in &views {
        if !matches_filters(view, filters, &index)? {
            continue;
        }
        append_summary(
            &mut output,
            view,
            paths.map(|value| value.get(view.filename())).transpose()?,
        )?;
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
