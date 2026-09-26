use super::error::AppError;
use super::filters::{StatusDefault, parse_filters};
use isled::filesystem::{self, FilesystemError, ProjectRoot};
use isled::query::{self, OutputPaths, ParseSearchSnippetsError, SearchSnippets};

pub(crate) fn run(
    arguments: isled::cli::SearchArgs,
    root: impl FnOnce() -> Result<ProjectRoot, FilesystemError>,
) -> Result<Vec<u8>, AppError> {
    let snippets = SearchSnippets::parse(arguments.snippets).map_err(|error| {
        let message = match error {
            ParseSearchSnippetsError::Missing => {
                format!("{error}; use `isled list` for filter-only queries")
            }
            _ => error.to_string(),
        };
        AppError::Invocation(message)
    })?;
    let with_path = arguments.filters.with_path;
    let filters = parse_filters(arguments.filters, StatusDefault::All)?;
    let project = root()?;
    let records = project.read_records()?;
    if with_path {
        let paths = output_paths(&project, &records)?;
        Ok(query::search_parsed_with_paths(
            &records, &filters, &snippets, &paths,
        )?)
    } else {
        Ok(query::search_parsed(&records, &filters, &snippets)?)
    }
}

fn output_paths(
    project: &ProjectRoot,
    records: &[filesystem::StoredRecord],
) -> Result<OutputPaths, FilesystemError> {
    project.ensure_tsv_output_path()?;
    records
        .iter()
        .map(|record| {
            Ok((
                record.filename().to_vec(),
                project.issue_path_bytes(record.filename())?,
            ))
        })
        .collect::<Result<Vec<_>, FilesystemError>>()
        .map(OutputPaths::new)
}
