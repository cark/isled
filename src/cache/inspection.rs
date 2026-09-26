//! Shared targeted inspection for frontend details and human batch reads.
use super::{Cache, CacheError};
use crate::{
    filesystem::{RecordRead, StoredIdentity},
    issue::IssueId,
};
use std::collections::BTreeSet;

impl Cache<'_> {
    /// Refresh selected files and their direct neighbors once in the shared command state.
    pub(crate) fn inspect_records(
        &mut self,
        ids: &BTreeSet<IssueId>,
    ) -> Result<Vec<RecordRead>, CacheError> {
        let mut scope = ids.clone();
        for &id in ids {
            scope.extend(self.neighbors(id)?);
        }
        self.inspect_files(ids)?;
        for &id in ids {
            scope.extend(self.neighbors(id)?);
            if let Some(Some(record)) = self.inspected.get(&id) {
                let issue = record.issue().expect("inspected valid record");
                scope.extend(issue.waits().iter().map(|r| r.target));
                scope.extend(issue.blocking().iter().map(|r| r.target));
            }
        }
        self.inspect_files(&scope)?;
        self.repair_inspected_titles();
        self.retain_inspected_warnings()?;
        scope
            .into_iter()
            .filter_map(|id| self.frontend_entry(id).transpose())
            .map(|entry| {
                let entry = entry?;
                let identity = StoredIdentity::new(entry.filename.into_bytes())?;
                let content = match entry.error {
                    Some(error) => Err(error),
                    None => self
                        .lock
                        .load_file(identity.filename())?
                        .record()
                        .map_err(|error| error.to_string()),
                };
                Ok(RecordRead { identity, content })
            })
            .collect()
    }

    pub(super) fn inspect_files(&mut self, ids: &BTreeSet<IssueId>) -> Result<(), CacheError> {
        if ids.is_empty() {
            return Ok(());
        }
        let names = ids
            .iter()
            .filter(|id| !self.inspected.contains_key(id))
            .filter_map(|&id| self.frontend_entry(id).transpose())
            .map(|entry| entry.map(|entry| entry.filename))
            .collect::<Result<Vec<_>, _>>()?;
        if names.is_empty() {
            return Ok(());
        }
        self.connection.begin_immediate()?;
        let result = self
            .lock
            .visit_files(names.iter().map(String::as_str), |name| {
                self.refresh_file_rows(name)
            });
        match result {
            Ok(()) => self.connection.commit()?,
            Err(error) => {
                let _ = self.connection.rollback();
                return Err(error);
            }
        }
        Ok(())
    }
}
