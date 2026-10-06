use super::cached_read::with_cached_query;
use super::error::AppError;
use super::filters::{StatusDefault, parse_filters};
use isled::filesystem::{FilesystemError, ProjectRoot};

pub(crate) fn run(
    arguments: isled::cli::FilterArgs,
    root: impl FnOnce() -> Result<ProjectRoot, FilesystemError>,
) -> Result<Vec<u8>, AppError> {
    let with_path = arguments.with_path;
    let filters = parse_filters(arguments, StatusDefault::Open)?;
    let project = root()?;
    if with_path {
        project.ensure_tsv_output_path()?;
    }
    with_cached_query(&project, |cache| {
        let mut output = Vec::new();
        for summary in cache
            .summaries(&filters)?
            .into_iter()
            .take(filters.limit.unwrap_or(usize::MAX))
        {
            let path = with_path
                .then(|| project.issue_path_bytes(summary.filename().as_bytes()))
                .transpose()?;
            output.extend(summary.render(path.as_deref()));
        }
        Ok(output)
    })
}
