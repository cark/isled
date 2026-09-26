//! Synchronize copied titles using the already-held lock and connection.
use super::{Cache, CacheError};
use std::fs;

impl Cache<'_> {
    pub(super) fn repair_inspected_titles(&mut self) -> bool {
        if !self.allow_title_repairs {
            return false;
        }
        let result = (|| {
            let plan = crate::mutation::repair_copied_titles(
                self.inspected.values().filter_map(Option::as_ref),
            )
            .map_err(|e| CacheError::Invalid(e.to_string()))?;
            if plan.replacements().is_empty() {
                return Ok(());
            }
            // No lock acquisition or publication callback: this cache owns both.
            self.lock.publish_without_sync(&plan)?;
            self.connection.begin_immediate()?;
            for replacement in plan.replacements() {
                self.refresh_file_rows(
                    std::str::from_utf8(replacement.filename()).expect("validated filename"),
                )?;
            }
            self.connection.commit()?;
            let pending = self.root().issues_dir().join(".cache/pending");
            if pending.exists() {
                fs::remove_file(pending)?;
            }
            Ok::<_, CacheError>(())
        })();
        let repaired = result.is_ok();
        if let Err(error) = result {
            let _ = self.connection.rollback();
            self.warnings.push(format!(
                "copied-title repair failed: {error}; inspect the record and retry refresh"
            ));
        }
        repaired
    }
}
