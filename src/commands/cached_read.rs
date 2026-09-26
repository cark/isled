use super::error::AppError;
use isled::cache::Cache;
use isled::filesystem::{ProjectRoot, StoreLock};

pub(crate) fn with_cached_query(
    project: &ProjectRoot,
    action: impl FnMut(&mut Cache<'_>) -> Result<Vec<u8>, AppError>,
) -> Result<Vec<u8>, AppError> {
    let lock = project.acquire_lock()?;
    let result = with_locked_query(&lock, action);
    lock.finish()?;
    result
}

pub(crate) fn with_locked_query(
    lock: &StoreLock<'_>,
    action: impl FnMut(&mut Cache<'_>) -> Result<Vec<u8>, AppError>,
) -> Result<Vec<u8>, AppError> {
    with_locked_query_mode(lock, false, action)
}

pub(crate) fn with_locked_query_mode(
    lock: &StoreLock<'_>,
    full: bool,
    mut action: impl FnMut(&mut Cache<'_>) -> Result<Vec<u8>, AppError>,
) -> Result<Vec<u8>, AppError> {
    let mut cache = if full {
        Cache::open_for_refresh(lock, None)?
    } else {
        Cache::open(lock)?
    };
    let mut result = action(&mut cache);
    if matches!(&result, Err(AppError::Cache(error)) if error.is_corruption()) {
        eprintln!("isled: warning: corrupt cache discovered during query; rebuilding once");
        drop(cache);
        cache = Cache::rebuild(lock)?;
        result = action(&mut cache);
    }
    cache.report_warnings();
    result
}
