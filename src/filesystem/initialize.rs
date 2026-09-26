use super::{
    FilesystemError, ProjectRoot,
    counter::{maximum_issue_id, read_high_water, write_counter},
};
use crate::ledger::{HighWater, LedgerError};
use std::{
    fs::{self, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
};

pub fn initialize_ledger(path: &Path) -> Result<PathBuf, FilesystemError> {
    let root = path
        .canonicalize()
        .map_err(|_| FilesystemError::RootDoesNotExist)?;
    if !root.is_dir() {
        return Err(FilesystemError::RootDoesNotExist);
    }
    let issues = root.join(".issues");
    if issues.is_symlink() {
        return Err(FilesystemError::SymlinkedStore);
    }
    if issues.exists() {
        if !issues.is_dir() {
            return Err(FilesystemError::NotDirectory);
        }
    } else {
        fs::create_dir(&issues).map_err(FilesystemError::Io)?;
    }

    let project = ProjectRoot {
        path: root.clone(),
        cache_cleanup: super::CacheCleanup::Drop,
    };
    let lock = project.acquire_lock()?;
    let maximum = maximum_issue_id(&lock.read_identities()?).map_or(0, crate::issue::IssueId::get);
    let counter_path = issues.join(".next-id");
    let stored = if counter_path.exists() || counter_path.is_symlink() {
        read_high_water(&counter_path)?.get()
    } else {
        1
    };
    let next = stored.max(maximum + 1);
    if next > HighWater::MAX {
        return Err(FilesystemError::Ledger(LedgerError::IdSpaceExhausted));
    }
    write_counter(&issues, next)?;
    ensure_ledger_ignored(&root)?;
    lock.finish()?;
    Ok(issues)
}
fn ensure_ledger_ignored(root: &Path) -> Result<(), FilesystemError> {
    let path = root.join(".gitignore");
    if path.is_symlink() || path.is_dir() {
        return Err(FilesystemError::UnsafeGitignore);
    }
    let existing = if path.exists() {
        fs::read(&path).map_err(FilesystemError::Io)?
    } else {
        Vec::new()
    };
    if existing
        .split(|byte| *byte == b'\n')
        .any(|line| line == b"/.issues/")
    {
        return Ok(());
    }
    let mut options = OpenOptions::new();
    options.create(true).append(true);
    let mut file = options.open(path).map_err(FilesystemError::Io)?;
    if !existing.is_empty() {
        file.write_all(b"\n").map_err(FilesystemError::Io)?;
    }
    file.write_all(b"/.issues/\n").map_err(FilesystemError::Io)
}
