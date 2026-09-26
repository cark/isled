//! Metadata lookups for bounded issue views and inspection.
use super::{Cache, CacheError, Summary, query::parse_cached_issue_id};
use crate::issue::IssueId;
use rusqlite::OptionalExtension;

pub(crate) struct Entry {
    pub id: IssueId,
    pub filename: String,
    pub error: Option<String>,
}

impl Cache<'_> {
    pub(crate) fn frontend_entry(&self, id: IssueId) -> Result<Option<Entry>, CacheError> {
        let value: Option<(String, Option<String>)> = self
            .connection
            .query_row(
                "SELECT filename,error FROM issues WHERE id=?1",
                [id.get()],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        value
            .map(|(filename, error)| {
                let (stored, _) = crate::record::parse_filename(filename.as_bytes())
                    .map_err(|e| CacheError::Corrupt(e.to_string()))?;
                if stored != id {
                    return Err(CacheError::Corrupt("cached filename/ID mismatch".into()));
                }
                Ok(Entry {
                    id,
                    filename,
                    error,
                })
            })
            .transpose()
    }

    pub(crate) fn frontend_summary(&self, id: IssueId) -> Result<Option<Summary>, CacheError> {
        match self.frontend_entry(id)? {
            Some(entry) if entry.error.is_none() => self.summary(id).map(Some),
            _ => Ok(None),
        }
    }

    pub(crate) fn frontend_problems(&self) -> Result<Vec<Entry>, CacheError> {
        let mut query = self
            .connection
            .prepare("SELECT id FROM issues WHERE error IS NOT NULL ORDER BY id")?;
        let ids = query
            .query_map([], |r| r.get::<_, i64>(0))?
            .map(|id| parse_cached_issue_id(id?))
            .collect::<Result<Vec<_>, _>>()?;
        ids.into_iter()
            .map(|id| {
                self.frontend_entry(id)?
                    .ok_or_else(|| CacheError::Corrupt("missing unreadable row".into()))
            })
            .collect()
    }

    pub(crate) fn frontend_identity_errors(&self) -> Result<Vec<String>, CacheError> {
        let text: String = self.connection.query_row(
            "SELECT diagnostics FROM cache_state WHERE singleton=1",
            [],
            |r| r.get(0),
        )?;
        serde_json::from_str(&text).map_err(|e| CacheError::Corrupt(e.to_string()))
    }
}
