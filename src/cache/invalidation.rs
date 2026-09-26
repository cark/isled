use super::{Cache, CacheError, database::require_regular_file_if_present};
use crate::filesystem::{FilesystemError, StoreLock};
use std::{
    collections::BTreeSet,
    fs,
    io::{self, Write},
    path::Path,
};

/// Persist affected filenames before Markdown publication, including interrupted batches.
pub(crate) fn mark_pending_files<'a>(
    lock: &StoreLock<'_>,
    filenames: impl IntoIterator<Item = &'a [u8]>,
) -> Result<(), FilesystemError> {
    let names: Vec<_> = filenames.into_iter().collect();
    if names.is_empty() {
        return Ok(());
    }
    let path = lock.root().cache_dir()?.join("pending");
    require_regular_file_if_present(&path).map_err(FilesystemError::Io)?;
    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(FilesystemError::Io)?;
    for name in names {
        file.write_all(name)
            .and_then(|()| file.write_all(b"\n"))
            .map_err(FilesystemError::Io)?;
    }
    Ok(())
}

pub(crate) fn synchronize_edit(lock: &StoreLock<'_>) {
    match Cache::open(lock) {
        Ok(cache) => cache.report_warnings(),
        Err(error) => eprintln!(
            "isled: warning: edit saved; cache update failed: {error}; pending invalidation retained, next cache command retries reconciliation; do not retry the edit"
        ),
    }
}
pub(super) fn read_pending_files(path: &Path) -> Result<BTreeSet<String>, CacheError> {
    require_regular_file_if_present(path)?;
    let text = match fs::read_to_string(path) {
        Ok(text) => text,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(BTreeSet::new()),
        Err(error) => return Err(error.into()),
    };
    text.lines()
        .map(|name| {
            crate::record::parse_filename(name.as_bytes())
                .map_err(|e| CacheError::Invalid(format!("invalid pending cache entry: {e}")))?;
            Ok(name.to_owned())
        })
        .collect()
}
