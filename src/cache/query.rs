//! Parameterized metadata selection and validated summary rows.
use super::{Cache, CacheError};
use crate::{
    issue::{IssueId, Name, Status, Tag},
    mutation::TitleText,
    query::{Filters, dependency::Node},
};
use rusqlite::{OptionalExtension, types::Value};

#[derive(Clone, Debug)]
pub struct Summary {
    id: IssueId,
    filename: String,
    title: TitleText,
    status: Status,
    kind: Name,
    ready: bool,
    work: crate::work_wire::WorkSummary,
}
impl Summary {
    pub fn work(&self) -> &crate::work_wire::WorkSummary {
        &self.work
    }
    pub fn id(&self) -> IssueId {
        self.id
    }
    pub fn filename(&self) -> &str {
        &self.filename
    }
    pub fn title(&self) -> &str {
        self.title.as_str()
    }
    pub fn status(&self) -> Status {
        self.status
    }
    pub fn ready(&self) -> bool {
        self.ready
    }
    pub fn kind(&self) -> &Name {
        &self.kind
    }
    pub fn render(&self, path: Option<&[u8]>) -> Vec<u8> {
        let mut bytes = format!(
            "{}\t{}\t{}\t{}",
            self.id,
            self.status.as_str(),
            self.kind,
            self.title.as_str()
        )
        .into_bytes();
        if let Some(path) = path {
            bytes.push(b'\t');
            bytes.extend_from_slice(path);
        }
        bytes.push(b'\n');
        bytes
    }
}

// A missing/unreadable blocker is not evidence of readiness.
const HAS_ACTIVE_WAIT: &str =
    "EXISTS(SELECT 1 FROM dependencies d LEFT JOIN issues b ON b.id=d.blocking_issue_id
    WHERE d.waiting_issue_id=i.id AND (b.status='open' OR b.status IS NULL))";

impl Cache<'_> {
    /// Select and order metadata; callers cap only after their additional matching.
    pub fn summaries(&self, filters: &Filters) -> Result<Vec<Summary>, CacheError> {
        let mut sql = format!(
            "SELECT i.id,i.filename,i.title,i.status,i.kind,(i.status='open' AND NOT {HAS_ACTIVE_WAIT}),i.work_state,i.work_reason,i.work_question,i.work_seconds,i.work_started,i.work_since FROM issues i WHERE i.error IS NULL"
        );
        let mut values = Vec::<Value>::new();
        if let Some(status) = filters.status {
            sql.push_str(" AND i.status=?");
            values.push(status.as_str().to_owned().into());
        }
        if let Some(kind) = &filters.kind {
            sql.push_str(" AND i.kind=?");
            values.push(kind.as_str().to_owned().into());
        }
        if let Some(state) = filters.work_state {
            sql.push_str(" AND i.work_state=?");
            values.push(state.as_str().to_owned().into());
        }
        if let Some(reason) = filters.work_reason {
            sql.push_str(" AND i.work_reason=?");
            values.push(reason.as_str().to_owned().into());
        }
        for tag in &filters.tags {
            sql.push_str(
                " AND EXISTS(SELECT 1 FROM issue_tags t WHERE t.issue_id=i.id AND t.tag=?)",
            );
            values.push(tag.as_str().to_owned().into());
        }
        if let Some(waiting) = filters.waiting {
            sql.push_str(if waiting { " AND " } else { " AND NOT " });
            sql.push_str(HAS_ACTIVE_WAIT);
        }
        if let Some(id) = filters.waiting_on {
            sql.push_str(" AND EXISTS(SELECT 1 FROM dependencies d LEFT JOIN issues b ON b.id=d.blocking_issue_id WHERE d.waiting_issue_id=i.id AND d.blocking_issue_id=? AND (b.status='open' OR b.status IS NULL))");
            values.push(i64::from(id.get()).into());
        }
        sql.push_str(if filters.oldest_first {
            " ORDER BY i.work_since IS NULL,i.work_since,i.id"
        } else {
            " ORDER BY i.id"
        });
        let mut statement = self.connection.prepare(&sql)?;
        let mut rows = statement.query(rusqlite::params_from_iter(values))?;
        let mut result = Vec::new();
        while let Some(row) = rows.next()? {
            result.push(decode_summary(row)?);
        }
        Ok(result)
    }

    pub fn filename(&self, id: IssueId) -> Result<String, CacheError> {
        let name: Option<String> = self
            .connection
            .query_row("SELECT filename FROM issues WHERE id=?1", [id.get()], |r| {
                r.get(0)
            })
            .optional()?;
        let name = name.ok_or_else(|| {
            CacheError::Invalid(format!(
                "issue not found: {id}; run cache refresh or check for ledger diagnostics"
            ))
        })?;
        let (stored, _) = crate::record::parse_filename(name.as_bytes())
            .map_err(|e| CacheError::Corrupt(e.to_string()))?;
        if stored != id {
            return Err(CacheError::Corrupt(
                "cached filename/ID mismatch; run cache refresh".into(),
            ));
        }
        Ok(name)
    }

    pub fn tag_counts(&self) -> Result<Vec<(Tag, u32)>, CacheError> {
        let mut query = self
            .connection
            .prepare("SELECT tag,count(*) FROM issue_tags GROUP BY tag ORDER BY tag")?;
        query
            .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, u32>(1)?)))?
            .map(|r| {
                let (name, count) = r?;
                Ok((
                    Tag::try_parse(name.as_bytes())
                        .map_err(|e| CacheError::Corrupt(e.to_string()))?,
                    count,
                ))
            })
            .collect()
    }

    pub(super) fn summary(&self, id: IssueId) -> Result<Summary, CacheError> {
        let sql = format!(
            "SELECT i.id,i.filename,i.title,i.status,i.kind,(i.status='open' AND NOT {HAS_ACTIVE_WAIT}),i.work_state,i.work_reason,i.work_question,i.work_seconds,i.work_started,i.work_since FROM issues i WHERE i.id=?1 AND i.error IS NULL"
        );
        let mut statement = self.connection.prepare(&sql)?;
        let mut rows = statement.query([id.get()])?;
        let row = rows.next()?.ok_or_else(|| {
            CacheError::Invalid(format!("issue {id} missing or unreadable; run check"))
        })?;
        decode_summary(row)
    }
}
pub(super) fn dependency_node_from_summary(summary: &Summary) -> Node {
    Node {
        id: summary.id,
        status: summary.status,
        ready: summary.ready,
        title: summary.title.as_str().to_owned(),
        filename: summary.filename.as_bytes().to_vec(),
    }
}

fn decode_summary(row: &rusqlite::Row<'_>) -> Result<Summary, CacheError> {
    let id = parse_cached_issue_id(row.get(0)?)?;
    let filename: String = row.get(1)?;
    let (parsed, _) = crate::record::parse_filename(filename.as_bytes())
        .map_err(|e| CacheError::Corrupt(e.to_string()))?;
    if parsed != id {
        return Err(CacheError::Corrupt("cached filename/ID mismatch".into()));
    }
    let title: String = row.get(2)?;
    let status: String = row.get(3)?;
    let kind: String = row.get(4)?;
    let status =
        Status::try_parse(status.as_bytes()).map_err(|e| CacheError::Corrupt(e.to_string()))?;
    let work = decode_work(row)?;
    if status == Status::Closed && work.state != "not-queued" {
        return Err(CacheError::Corrupt(
            "closed issue has a current work state".into(),
        ));
    }
    Ok(Summary {
        id,
        filename,
        title: TitleText::parse(&title).map_err(|e| CacheError::Corrupt(e.to_string()))?,
        status,
        kind: Name::try_parse(kind.as_bytes()).map_err(|e| CacheError::Corrupt(e.to_string()))?,
        ready: row.get(5)?,
        work,
    })
}
pub(super) fn parse_cached_issue_id(value: i64) -> Result<IssueId, CacheError> {
    u16::try_from(value)
        .ok()
        .and_then(IssueId::new)
        .ok_or_else(|| {
            CacheError::Corrupt(format!(
                "invalid cached issue ID: {value}; run cache refresh"
            ))
        })
}

fn decode_work(row: &rusqlite::Row<'_>) -> Result<crate::work_wire::WorkSummary, CacheError> {
    use crate::issue::{OwnerQuestion, WorkStateKind};
    let state: String = row.get(6)?;
    let state: WorkStateKind = state
        .parse()
        .map_err(|e: crate::issue::WorkStateError| CacheError::Corrupt(e.to_string()))?;
    let reason: Option<String> = row.get(7)?;
    let question: Option<String> = row.get(8)?;
    let reason = match (state, reason.as_deref(), question.as_deref()) {
        (WorkStateKind::AwaitingOwner, Some("review"), None) => Some("review"),
        (WorkStateKind::AwaitingOwner, Some("clarification"), Some(question)) => {
            OwnerQuestion::parse(question).map_err(|e| CacheError::Corrupt(e.to_string()))?;
            Some("clarification")
        }
        (state, None, None) if state != WorkStateKind::AwaitingOwner => None,
        _ => return Err(CacheError::Corrupt("invalid cached owner wait".into())),
    };
    let running: Option<String> = row.get(10)?;
    let running = running
        .map(|value| value.parse())
        .transpose()
        .map_err(|e: crate::work_log::WorkLogError| CacheError::Corrupt(e.to_string()))?;
    if running.is_some() && state != WorkStateKind::InProgress {
        return Err(CacheError::Corrupt("invalid cached running clock".into()));
    }
    let since: Option<String> = row.get(11)?;
    let since = since
        .map(|value| value.parse())
        .transpose()
        .map_err(|e: crate::work_log::WorkLogError| CacheError::Corrupt(e.to_string()))?;
    if since.is_some() && state == WorkStateKind::NotQueued {
        return Err(CacheError::Corrupt(
            "not-queued issue has a cached entry time".into(),
        ));
    }
    Ok(crate::work_wire::WorkSummary::from_cached(
        state,
        reason,
        question,
        u64::try_from(row.get::<_, i64>(9)?)
            .map_err(|_| CacheError::Corrupt("negative cached work time".into()))?,
        running,
        since,
    ))
}
