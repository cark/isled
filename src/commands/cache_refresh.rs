use super::error::AppError;
use super::issue_id::parse_issue_id;
use isled::cache::Cache;
use isled::filesystem::{FilesystemError, ProjectRoot};

pub(crate) fn run(
    arguments: isled::cli::CacheArgs,
    root: impl FnOnce() -> Result<ProjectRoot, FilesystemError>,
) -> Result<Vec<u8>, AppError> {
    let isled::cli::CacheCommand::Refresh { issue } = arguments.command;
    let id = issue.as_deref().map(parse_issue_id).transpose()?;
    let project = root()?;
    let lock = project.acquire_lock()?;
    let cache = Cache::open_for_refresh(&lock, id)?;
    cache.report_warnings();
    drop(cache);
    lock.finish()?;
    Ok(match id {
        Some(id) => format!("refreshed cache for issue {id} and direct neighbors\n"),
        None => "refreshed full issue cache\n".to_owned(),
    }
    .into_bytes())
}
