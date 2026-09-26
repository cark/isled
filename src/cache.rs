//! Disposable SQLite connection lifecycle, always scoped to a ledger lock.
mod database;
mod dependency;
mod error;
mod filter_choices;
mod filtering;
mod frontend;
mod inspection;
mod invalidation;
mod layout;
mod query;
mod repair;
mod retained_warnings;
mod show;
mod source;
mod storage;
mod warnings;

use crate::{
    filesystem::{ProjectRoot, StoreLock},
    issue::IssueId,
};
use database::{Database, require_regular_file_if_present};
pub use error::CacheError;
pub(crate) use invalidation::{mark_pending_files, synchronize_edit};
pub use query::Summary;
pub use show::ShownIssue;
use std::{collections::BTreeSet, fs, io};

/// Scoped to a held ledger lock; no connections escape into pure query consumers.
pub struct Cache<'a> {
    connection: Database,
    lock: &'a StoreLock<'a>,
    warnings: Vec<String>,
    rebuilt: bool,
    allow_title_repairs: bool,
    last_neighbors: BTreeSet<IssueId>,
    warning_neighbors: BTreeSet<IssueId>,
    inspected: std::collections::BTreeMap<IssueId, Option<crate::filesystem::StoredRecord>>,
}

impl<'a> Cache<'a> {
    pub fn open(lock: &'a StoreLock<'a>) -> Result<Self, CacheError> {
        Self::open_mode(lock, false)
    }

    fn open_mode(lock: &'a StoreLock<'a>, full: bool) -> Result<Self, CacheError> {
        Self::open_with_repairs(lock, full, true)
    }

    pub(crate) fn open_for_editor(lock: &'a StoreLock<'a>) -> Result<Self, CacheError> {
        Self::open_with_repairs(lock, false, false)
    }

    fn open_with_repairs(
        lock: &'a StoreLock<'a>,
        full: bool,
        repairs: bool,
    ) -> Result<Self, CacheError> {
        match Self::open_once(lock, full, repairs) {
            Err(error) if error.is_corruption() => {
                eprintln!("isled: warning: {error}; rebuilding corrupt cache");
                Self::rebuild_with_repairs(lock, repairs)
            }
            result => result,
        }
    }

    fn open_once(lock: &'a StoreLock<'a>, full: bool, repairs: bool) -> Result<Self, CacheError> {
        let directory = lock.root().cache_dir()?;
        let path = directory.join("ledger.sqlite");
        require_regular_file_if_present(&path)?;
        require_regular_file_if_present(&directory.join("ledger.sqlite-journal"))?;
        let (connection, fresh) = Database::open(&path)?;
        let mut cache = Self {
            connection,
            lock,
            warnings: Vec::new(),
            rebuilt: fresh,
            allow_title_repairs: repairs,
            last_neighbors: BTreeSet::new(),
            warning_neighbors: BTreeSet::new(),
            inspected: std::collections::BTreeMap::new(),
        };
        cache.reconcile(fresh || full)?;
        Ok(cache)
    }

    pub fn open_for_refresh(
        lock: &'a StoreLock<'a>,
        id: Option<IssueId>,
    ) -> Result<Self, CacheError> {
        let mut cache = Self::open_mode(lock, id.is_none())?;
        if let Some(id) = id {
            if cache.rebuilt {
                cache.filename(id)?;
            } else {
                cache.refresh(Some(id))?;
            }
        }
        Ok(cache)
    }

    pub fn rebuild(lock: &'a StoreLock<'a>) -> Result<Self, CacheError> {
        Self::rebuild_with_repairs(lock, true)
    }

    fn rebuild_with_repairs(lock: &'a StoreLock<'a>, repairs: bool) -> Result<Self, CacheError> {
        let directory = lock.root().cache_dir()?;
        for filename in ["ledger.sqlite", "ledger.sqlite-journal"] {
            let path = directory.join(filename);
            require_regular_file_if_present(&path)?;
            match fs::remove_file(&path) {
                Ok(()) => {}
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(error) => return Err(error.into()),
            }
        }
        Self::open_once(lock, true, repairs)
    }

    pub fn root(&self) -> &ProjectRoot {
        self.lock.root()
    }
    pub fn files_read(&self) -> usize {
        self.lock.files_read()
    }
    pub fn warnings(&self) -> &[String] {
        &self.warnings
    }

    pub fn refresh(&mut self, id: Option<IssueId>) -> Result<(), CacheError> {
        match id {
            Some(id) => self.refresh_target(id),
            None => self.reconcile(true),
        }
    }

    pub fn report_warnings(&self) {
        for warning in &self.warnings {
            eprintln!("isled: warning: {warning}");
        }
    }
}
