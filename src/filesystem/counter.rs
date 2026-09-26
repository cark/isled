use super::{FilesystemError, StoredIdentity, paths::require_regular_file, write::write_new_file};
use crate::ledger::HighWater;
use std::{fs, path::Path};

pub(super) fn maximum_issue_id(identities: &[StoredIdentity]) -> Option<crate::issue::IssueId> {
    identities.iter().map(StoredIdentity::id).max()
}
pub(super) fn read_high_water(path: &Path) -> Result<HighWater, FilesystemError> {
    require_regular_file(path, true)?;
    HighWater::parse(&fs::read(path).map_err(FilesystemError::Io)?).map_err(FilesystemError::Ledger)
}

pub(super) fn write_counter(issues: &Path, value: u16) -> Result<(), FilesystemError> {
    let temporary = issues.join(format!(".next-id.tmp-{}", std::process::id()));
    write_new_file(&temporary, format!("{value}\n").as_bytes(), 0o600)?;
    if let Err(error) = fs::rename(&temporary, issues.join(".next-id")) {
        let _ = fs::remove_file(&temporary);
        return Err(FilesystemError::Io(error));
    }
    Ok(())
}
