use super::error::AppError;
use isled::cache::Cache;
use isled::filesystem::{FilesystemError, ProjectRoot};
use isled::snapshot::{self, Snapshot, SnapshotSource};

pub(crate) fn run(
    root: impl FnOnce() -> Result<ProjectRoot, FilesystemError>,
) -> Result<Vec<u8>, AppError> {
    let project = root()?;
    let lock = project.acquire_lock()?;
    let cache = Cache::open_for_refresh(&lock, None)?;
    cache.report_warnings();
    drop(cache);
    let view = {
        let records = lock.read_snapshot_records()?;
        let paths = records
            .iter()
            .map(|record| project.issue_path_bytes_lossless(record.identity.filename()))
            .collect::<Result<Vec<_>, _>>()?;
        let sources = records
            .iter()
            .zip(&paths)
            .map(|(record, path)| match &record.content {
                Ok(loaded) => SnapshotSource::record(loaded, path),
                Err(error) => SnapshotSource::unavailable(&record.identity, path, error),
            })
            .collect::<Vec<_>>();
        Snapshot::build(project.path_bytes_lossless()?, &sources)?
    };
    lock.finish()?;
    Ok(snapshot::json::render(&view)?)
}
