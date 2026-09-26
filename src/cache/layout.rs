//! Graph extraction from metadata, preserving either-half relations.
use super::{Cache, CacheError, Summary, query::parse_cached_issue_id};
use crate::{
    graph_layout::Graph,
    issue::{IssueId, Status},
    query::Filters,
};

impl Cache<'_> {
    pub fn layout_inputs(
        &self,
        status: Option<Status>,
        max_edges: usize,
    ) -> Result<(Vec<Summary>, Graph), CacheError> {
        let summaries = self.summaries(&Filters {
            status,
            ..Filters::default()
        })?;
        let graph = Graph::new(
            summaries.iter().map(Summary::id),
            self.layout_edges(status, max_edges)?,
            max_edges,
        )
        .map_err(|e| CacheError::Invalid(e.to_string()))?;
        Ok((summaries, graph))
    }

    pub(crate) fn layout_edges(
        &self,
        status: Option<Status>,
        max_edges: usize,
    ) -> Result<Vec<(IssueId, IssueId)>, CacheError> {
        let mut statement = self.connection.prepare(
            "SELECT DISTINCT d.waiting_issue_id,d.blocking_issue_id FROM dependencies d
             JOIN issues a ON a.id=d.waiting_issue_id AND a.error IS NULL
             JOIN issues b ON b.id=d.blocking_issue_id AND b.error IS NULL
             WHERE (?1 IS NULL OR (a.status=?1 AND b.status=?1))
             ORDER BY d.waiting_issue_id,d.blocking_issue_id LIMIT ?2",
        )?;
        let limit = i64::try_from(max_edges)
            .unwrap_or(i64::MAX)
            .saturating_add(1);
        let rows = statement.query_map(
            rusqlite::params![status.map(Status::as_str), limit],
            |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?)),
        )?;
        let mut edges = Vec::new();
        for row in rows {
            let (dependent, prerequisite) = row?;
            if edges.len() == max_edges {
                return Err(CacheError::Invalid(format!(
                    "dependency graph exceeds the edge budget ({max_edges})"
                )));
            }
            edges.push((
                parse_cached_issue_id(dependent)?,
                parse_cached_issue_id(prerequisite)?,
            ));
        }
        Ok(edges)
    }
}
