use super::{
    FilesystemError, ProjectRoot, StoredIdentity, StoredRecord,
    counter::{maximum_issue_id, read_high_water, write_counter},
    paths::os_name,
    write::write_new_file,
};
use crate::{
    ledger::LedgerError,
    mutation::{MutationPlan, Replacement},
};
use std::{
    fs, io,
    path::PathBuf,
    time::{Duration, Instant},
};

impl ProjectRoot {
    pub fn acquire_lock(&self) -> Result<StoreLock<'_>, FilesystemError> {
        let cache = self.cache_dir()?;
        let lock_dir = cache.join(".isled-lock");
        let deadline = Instant::now() + Duration::from_millis(500);
        loop {
            match fs::create_dir(&lock_dir) {
                Ok(()) => break,
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                    let remaining = deadline.saturating_duration_since(Instant::now());
                    if remaining.is_zero() {
                        return Err(FilesystemError::Locked);
                    }
                    std::thread::sleep(remaining.min(Duration::from_millis(10)));
                }
                Err(error) => return Err(FilesystemError::Io(error)),
            }
        }
        Ok(StoreLock {
            root: self,
            lock_dir,
            released: false,
            loaded: super::loaded::LoadedIssues::default(),
            inventory: super::inventory::Inventory::default(),
        })
    }
}

pub struct StoreLock<'a> {
    root: &'a ProjectRoot,
    lock_dir: PathBuf,
    released: bool,
    loaded: super::loaded::LoadedIssues,
    inventory: super::inventory::Inventory,
}

impl StoreLock<'_> {
    pub(crate) fn root(&self) -> &ProjectRoot {
        self.root
    }
    pub fn read_records(&self) -> Result<Vec<StoredRecord>, FilesystemError> {
        self.read_records_matching(None)
    }

    pub fn read_issue_records(
        &self,
        id: crate::issue::IssueId,
    ) -> Result<Vec<StoredRecord>, FilesystemError> {
        self.read_records_matching(Some(id))
    }

    fn read_records_matching(
        &self,
        wanted: Option<crate::issue::IssueId>,
    ) -> Result<Vec<StoredRecord>, FilesystemError> {
        self.root.read_records_with(wanted, |name, _| {
            let record = self.load_file(name)?.record()?;
            record.require_encoding()?;
            Ok(record)
        })
    }

    pub(crate) fn load_file(
        &self,
        filename: &[u8],
    ) -> Result<super::loaded::LoadedFile, FilesystemError> {
        self.loaded.get(self.root, filename)
    }

    pub(crate) fn files_read(&self) -> usize {
        self.loaded.reads()
    }

    pub(crate) fn visit_files<'n, E: From<io::Error>>(
        &self,
        names: impl IntoIterator<Item = &'n str>,
        consume: impl FnMut(&str) -> Result<(), E>,
    ) -> Result<(), E> {
        self.loaded.visit_files(self.root, names, consume)
    }

    /// Reuse read successes and failures; unsafe identities remain fatal.
    pub fn read_snapshot_records(&self) -> Result<Vec<super::RecordRead>, FilesystemError> {
        self.read_identities()?
            .into_iter()
            .map(|identity| {
                let loaded = self.load_file(identity.filename())?;
                let content = loaded.record().map_err(|error| error.to_string());
                Ok(super::RecordRead { identity, content })
            })
            .collect()
    }

    pub fn read_identities(&self) -> Result<Vec<StoredIdentity>, FilesystemError> {
        super::read::identities(self.issue_entries()?.iter())
    }

    pub(crate) fn issue_entries(&self) -> Result<std::rc::Rc<Vec<fs::DirEntry>>, FilesystemError> {
        self.inventory.entries(self.root)
    }

    /// Computes the next ID without reserving it; creation rechecks under this lock.
    pub fn next_available_id(&self) -> Result<crate::issue::IssueId, FilesystemError> {
        let high_water = read_high_water(&self.root.issues_dir().join(".next-id"))?;
        let maximum = maximum_issue_id(&self.root.read_identities()?);
        let next = high_water.get().max(maximum.map_or(1, |id| id.get() + 1));
        crate::issue::IssueId::new(next)
            .ok_or(FilesystemError::Ledger(LedgerError::IdSpaceExhausted))
    }

    pub fn publish(&self, plan: &MutationPlan) -> Result<(), FilesystemError> {
        let result = self.publish_without_sync(plan);
        if result.is_ok() && !plan.replacements().is_empty() {
            crate::cache::synchronize_edit(self);
        }
        result
    }

    /// Cache reconciliation already owns the lock and synchronizes its own rows.
    pub(crate) fn publish_without_sync(&self, plan: &MutationPlan) -> Result<(), FilesystemError> {
        crate::cache::mark_pending_files(
            self,
            plan.replacements().iter().map(Replacement::filename),
        )?;
        match plan.replacements() {
            [] => Ok(()),
            [replacement] => self.publish_one(replacement),
            replacements => self.publish_many(replacements),
        }
    }

    pub fn add(&self, replacement: &Replacement) -> Result<(), FilesystemError> {
        let (id, _) = crate::record::parse_filename(replacement.filename())?;
        let expected = self.next_available_id()?;
        if id != expected {
            return Err(FilesystemError::UnexpectedCreationId {
                expected,
                actual: id,
            });
        }
        let next_high_water = id.get() + 1;
        crate::cache::mark_pending_files(self, [replacement.filename()])?;
        let destination = self
            .root
            .issues_dir()
            .join(os_name(replacement.filename())?);
        if destination.exists() || destination.is_symlink() {
            return Err(FilesystemError::DestinationExists);
        }
        let temporary = self
            .root
            .issues_dir()
            .join(format!(".isled-add-{}", std::process::id()));
        write_new_file(&temporary, replacement.bytes(), 0o644)?;
        if let Err(error) = fs::rename(&temporary, &destination) {
            let _ = fs::remove_file(&temporary);
            return Err(FilesystemError::Io(error));
        }
        self.loaded.published(self.root, replacement.record());
        self.inventory.invalidate();
        write_counter(&self.root.issues_dir(), next_high_water)?;
        crate::cache::synchronize_edit(self);
        Ok(())
    }

    /// Publish a validated new record with reciprocal edits, preserving ID no-reuse.
    pub(crate) fn add_draft(
        &self,
        id: crate::issue::IssueId,
        plan: &MutationPlan,
    ) -> Result<(), FilesystemError> {
        let expected = self.next_available_id()?;
        if id != expected {
            return Err(FilesystemError::UnexpectedCreationId {
                expected,
                actual: id,
            });
        }
        // Reserve once validation is complete; an I/O failure can consume an ID.
        write_counter(&self.root.issues_dir(), id.get() + 1)?;
        self.inventory.invalidate();
        self.publish(plan)
    }

    pub fn finish(mut self) -> Result<(), FilesystemError> {
        fs::remove_dir(&self.lock_dir).map_err(FilesystemError::Io)?;
        self.released = true;
        Ok(())
    }

    fn publish_one(&self, replacement: &Replacement) -> Result<(), FilesystemError> {
        let temporary = self
            .root
            .issues_dir()
            .join(format!(".isled-rewrite-{}", std::process::id()));
        write_new_file(&temporary, replacement.bytes(), 0o644)?;
        let destination = self
            .root
            .issues_dir()
            .join(os_name(replacement.filename())?);
        if let Err(error) = fs::rename(&temporary, destination) {
            let _ = fs::remove_file(&temporary);
            return Err(FilesystemError::Io(error));
        }
        self.loaded.published(self.root, replacement.record());
        Ok(())
    }

    fn publish_many(&self, replacements: &[Replacement]) -> Result<(), FilesystemError> {
        let staging = self
            .root
            .issues_dir()
            .join(format!(".isled-close-{}", std::process::id()));
        fs::create_dir(&staging).map_err(|error| {
            if error.kind() == io::ErrorKind::AlreadyExists {
                FilesystemError::TemporaryExists
            } else {
                FilesystemError::Io(error)
            }
        })?;
        let result = (|| {
            for replacement in replacements {
                write_new_file(
                    &staging.join(os_name(replacement.filename())?),
                    replacement.bytes(),
                    0o644,
                )?;
            }
            for replacement in replacements {
                fs::rename(
                    staging.join(os_name(replacement.filename())?),
                    self.root
                        .issues_dir()
                        .join(os_name(replacement.filename())?),
                )
                .map_err(FilesystemError::Io)?;
                self.loaded.published(self.root, replacement.record());
            }
            fs::remove_dir(&staging).map_err(FilesystemError::Io)
        })();
        if result.is_err() {
            let _ = fs::remove_dir_all(&staging);
        }
        result
    }
}

impl Drop for StoreLock<'_> {
    fn drop(&mut self) {
        if !self.released {
            let _ = fs::remove_dir(&self.lock_dir);
        }
        if self.root.cache_cleanup == super::CacheCleanup::LeaveToProcessExit {
            // Only process memory is abandoned: publication, SQLite, and lock
            // cleanup retain their ordinary ownership and failure handling.
            std::mem::forget(std::mem::take(&mut self.loaded));
        }
    }
}
