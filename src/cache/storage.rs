//! Full and targeted reconciliation against authoritative Markdown.
use super::{
    Cache, CacheError, invalidation::read_pending_files, query::parse_cached_issue_id,
    source::unix_timestamp_parts,
};
use crate::{issue::IssueId, record::parse_filename};
use rusqlite::{OptionalExtension, params};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs, io,
};

impl Cache<'_> {
    pub(super) fn reconcile(&mut self, full: bool) -> Result<(), CacheError> {
        self.inspected.clear();
        let root = self.root().issues_dir();
        let pending_path = root.join(".cache/pending");
        let (mut pending, damaged_pending) = match read_pending_files(&pending_path) {
            Ok(pending) => (pending, false),
            Err(CacheError::Invalid(_)) => (BTreeSet::new(), true),
            Err(CacheError::Io(error)) if error.kind() == io::ErrorKind::InvalidData => {
                (BTreeSet::new(), true)
            }
            Err(error) => return Err(error),
        };
        let full = full || damaged_pending;
        if damaged_pending {
            self.warnings
                .push("damaged pending cache invalidation; rebuilding from Markdown".into());
        }
        let stamp = unix_timestamp_parts(fs::metadata(&root)?.modified().ok());
        let previous: (Option<i64>, Option<u32>) = self.connection.query_row(
            "SELECT directory_seconds, directory_nanos FROM cache_state WHERE singleton=1",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?;
        let scan = full || stamp != previous || stamp.0.is_none();
        self.connection.begin_immediate()?;
        let result = (|| {
            if scan {
                let mut names = BTreeMap::<IssueId, Vec<String>>::new();
                let mut diagnostics = Vec::new();
                for entry in self.lock.issue_entries()?.iter() {
                    let os_name = entry.file_name();
                    let Some(name) = os_name.to_str() else {
                        diagnostics.push(format!("invalid UTF-8 filename: {os_name:?}"));
                        continue;
                    };
                    if name.starts_with('.') || !name.ends_with(".md") {
                        continue;
                    }
                    match parse_filename(name.as_bytes()) {
                        Ok((id, _)) => names.entry(id).or_default().push(name.to_owned()),
                        Err(error) => diagnostics.push(format!("{name}: {error}")),
                    }
                }
                let known = self.known_files()?;
                for (id, filename) in &known {
                    if !names
                        .get(id)
                        .is_some_and(|values| values.contains(filename))
                    {
                        self.warning_neighbors.extend(self.neighbors(*id)?);
                        self.connection
                            .execute("DELETE FROM issues WHERE id=?1", [id.get()])?;
                    }
                }
                for (id, mut filenames) in names {
                    filenames.sort();
                    if filenames.len() != 1 {
                        let message = format!(
                            "multiple issue files found for {id}: {}",
                            filenames.join(", ")
                        );
                        for name in &filenames {
                            pending.remove(name);
                        }
                        self.connection
                            .execute("DELETE FROM issues WHERE id=?1", [id.get()])?;
                        diagnostics.push(message);
                        continue;
                    }
                    let name = &filenames[0];
                    if full || known.get(&id) != Some(name) {
                        pending.insert(name.clone());
                    }
                }
                diagnostics.sort();
                self.connection.execute(
                    "UPDATE cache_state SET diagnostics=?1 WHERE singleton=1 AND diagnostics IS NOT ?1",
                    [serde_json::to_string(&diagnostics)
                        .map_err(|e| CacheError::Invalid(e.to_string()))?],
                )?;
            }
            self.lock
                .visit_files(pending.iter().map(String::as_str), |name| {
                    self.refresh_file_rows(name)
                })?;
            self.connection.execute(
                "UPDATE cache_state SET directory_seconds=?1,directory_nanos=?2 WHERE singleton=1
                 AND (directory_seconds IS NOT ?1 OR directory_nanos IS NOT ?2)",
                params![stamp.0, stamp.1],
            )?;
            Ok::<_, CacheError>(())
        })();
        match result {
            Ok(()) => self.connection.commit()?,
            Err(error) => {
                let _ = self.connection.rollback();
                return Err(error);
            }
        }
        self.inspect_warning_neighbors()?;
        let repaired = self.repair_inspected_titles();
        self.collect_incomplete_query_warnings()?;
        self.collect_relation_warnings()?;
        if repaired && pending_path.exists() {
            fs::remove_file(pending_path)?;
        }
        Ok(())
    }

    fn known_files(&self) -> Result<BTreeMap<IssueId, String>, CacheError> {
        let mut statement = self
            .connection
            .prepare("SELECT id, filename FROM issues ORDER BY id")?;
        let rows =
            statement.query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))?;
        rows.map(|row| {
            let (id, name) = row?;
            Ok((parse_cached_issue_id(id)?, name))
        })
        .collect()
    }

    pub(super) fn refresh_target(&mut self, id: IssueId) -> Result<(), CacheError> {
        self.inspected.clear();
        let filename = self.filename(id)?;
        let mut neighbors = self.neighbors(id)?;
        self.connection.begin_immediate()?;
        let result = (|| {
            self.refresh_file_rows(&filename)?;
            neighbors.extend(self.last_neighbors.iter().copied());
            neighbors.extend(self.neighbors(id)?);
            neighbors.remove(&id);
            for neighbor in neighbors {
                if let Some(name) = self
                    .connection
                    .query_row(
                        "SELECT filename FROM issues WHERE id=?1",
                        [neighbor.get()],
                        |r| r.get::<_, String>(0),
                    )
                    .optional()?
                {
                    self.refresh_file_rows(&name)?;
                }
            }
            Ok::<_, CacheError>(())
        })();
        match result {
            Ok(()) => self.connection.commit()?,
            Err(error) => {
                let _ = self.connection.rollback();
                return Err(error);
            }
        }
        self.repair_inspected_titles();
        self.collect_incomplete_query_warnings()?;
        self.collect_relation_warnings()?;
        Ok(())
    }
}
