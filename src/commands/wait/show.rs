use super::super::cached_read::with_cached_query;
use super::super::error::AppError;
use super::super::issue_id::parse_issue_id;
use isled::filesystem::{FilesystemError, ProjectRoot};

pub(super) fn run(
    arguments: isled::cli::WaitShowArgs,
    root: impl FnOnce() -> Result<ProjectRoot, FilesystemError>,
) -> Result<Vec<u8>, AppError> {
    let id = parse_issue_id(&arguments.id)?;
    let project = root()?;
    with_cached_query(&project, |cache| {
        cache.refresh(Some(id))?;
        Ok(cache.wait_show(id, arguments.with_path)?)
    })
}
