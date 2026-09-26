mod batch;

use super::cached_read::with_locked_query;
use super::error::AppError;
use super::issue_id::parse_issue_id;
use isled::filesystem::{FilesystemError, ProjectRoot};
use isled::query;

pub(crate) fn run(
    arguments: isled::cli::ShowArgs,
    root: impl FnOnce() -> Result<ProjectRoot, FilesystemError>,
) -> Result<Vec<u8>, AppError> {
    let project = root()?;
    let ids = arguments
        .ids
        .iter()
        .map(|id| parse_issue_id(id))
        .collect::<Result<Vec<_>, _>>()?;
    if ids.len() > 1 {
        return batch::run(&project, &ids);
    }
    let id = ids[0];
    let lock = match project.acquire_lock() {
        Ok(lock) => lock,
        Err(error) => {
            // Preserve raw lookup/encoding errors ahead of lock failures.
            query::show(&project.read_issue_records(id)?, id)?;
            return Err(error.into());
        }
    };
    query::show(&lock.read_issue_records(id)?, id)?;
    // Reconcile metadata, but preserve the raw diagnostic show path.
    with_locked_query(&lock, |cache| {
        cache.refresh(Some(id))?;
        Ok(Vec::new())
    })?;
    let output = query::show(&lock.read_issue_records(id)?, id)?;
    lock.finish()?;
    Ok(output)
}
