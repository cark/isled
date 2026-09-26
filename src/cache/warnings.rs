//! Aggregate incomplete-query and inspected-relation warnings.
use super::{Cache, CacheError, query::parse_cached_issue_id};

impl Cache<'_> {
    /// Operational warnings for callers that supply their own per-issue findings.
    pub fn maintenance_warnings(&self) -> impl Iterator<Item = &str> {
        self.warnings.iter().map(String::as_str).filter(|warning| {
            !warning.starts_with("cached query results incomplete")
                && !warning.starts_with("issue #")
        })
    }

    pub(super) fn collect_incomplete_query_warnings(&mut self) -> Result<(), CacheError> {
        self.warnings
            .retain(|w| !w.starts_with("cached query results incomplete"));
        let diagnostics: String = self.connection.query_row(
            "SELECT diagnostics FROM cache_state WHERE singleton=1",
            [],
            |r| r.get(0),
        )?;
        let mut messages: Vec<String> =
            serde_json::from_str(&diagnostics).map_err(|e| CacheError::Corrupt(e.to_string()))?;
        let mut statement = self
            .connection
            .prepare("SELECT filename,error FROM issues WHERE error IS NOT NULL ORDER BY id")?;
        for message in statement.query_map([], |r| {
            Ok(format!(
                "{}: {}",
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?
            ))
        })? {
            messages.push(message?);
        }
        let mut missing=self.connection.prepare("SELECT d.waiting_issue_id,d.blocking_issue_id FROM dependencies d
            LEFT JOIN issues b ON b.id=d.blocking_issue_id WHERE b.id IS NULL ORDER BY d.waiting_issue_id,d.blocking_issue_id")?;
        for row in missing.query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?)))? {
            let (source, target) = row?;
            messages.push(format!(
                "issue {} has missing blocker {}",
                parse_cached_issue_id(source)?,
                parse_cached_issue_id(target)?
            ));
        }
        if !messages.is_empty() {
            let warning = format!(
                "cached query results incomplete; unreadable issues: {}",
                messages.join("; ")
            );
            if !self.warnings.contains(&warning) {
                self.warnings.push(warning);
            }
        }
        Ok(())
    }

    pub(super) fn collect_relation_warnings(&mut self) -> Result<(), CacheError> {
        self.retain_inspected_warnings()?;
        self.warnings
            .retain(|warning| !warning.starts_with("issue #"));
        let mut query = self.connection.prepare(
            "SELECT owner_issue_id,code,message FROM relation_warnings ORDER BY owner_issue_id,source_id,target_id,code")?;
        for row in query.query_map([], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
            ))
        })? {
            let (owner, code, message) = row?;
            self.warnings.push(format!(
                "issue #{} [{code}]: {message}",
                parse_cached_issue_id(owner)?
            ));
        }
        Ok(())
    }
}
