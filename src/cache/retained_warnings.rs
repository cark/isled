//! Last-known relation findings; only inspected conditions replace cached findings.
use super::{Cache, CacheError, query::parse_cached_issue_id};
use crate::{
    diagnostic::{RelatedIssue, relation_warnings},
    issue::IssueId,
};
use rusqlite::params;
use std::collections::{BTreeMap, BTreeSet};

type FindingKey = (IssueId, IssueId, IssueId, String);
type Findings = BTreeMap<FindingKey, (String, bool)>;

impl Cache<'_> {
    /// Return a stable affected identity without reading bodies or applying filters.
    pub fn first_warning_id(&self) -> Result<Option<IssueId>, CacheError> {
        let id: Option<i64> = self.connection.query_row(
            "SELECT MIN(id) FROM (SELECT id FROM issues WHERE error IS NOT NULL
             UNION SELECT owner_issue_id AS id FROM relation_warnings)",
            [],
            |row| row.get(0),
        )?;
        id.map(parse_cached_issue_id).transpose()
    }

    /// Enumerate affected identities from derived rows, without inspecting sources.
    pub fn warning_ids(&self) -> Result<Vec<IssueId>, CacheError> {
        let mut query = self.connection.prepare(
            "SELECT id FROM issues WHERE error IS NOT NULL
             UNION SELECT owner_issue_id FROM relation_warnings ORDER BY id",
        )?;
        query
            .query_map([], |row| row.get::<_, i64>(0))?
            .map(|row| parse_cached_issue_id(row?))
            .collect()
    }

    pub(crate) fn known_relation_warnings(
        &self,
        owner: IssueId,
    ) -> Result<Vec<crate::diagnostic::RelationWarning>, CacheError> {
        let mut query = self.connection.prepare(
            "SELECT source_id,target_id,code,message,needs_reason FROM relation_warnings
             WHERE owner_issue_id=?1 ORDER BY source_id,target_id,code",
        )?;
        query
            .query_map([owner.get()], |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, i64>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, String>(3)?,
                    r.get::<_, bool>(4)?,
                ))
            })?
            .map(|row| {
                let (source, target, code, message, needs_reason) = row?;
                let source = parse_cached_issue_id(source)?;
                let target = parse_cached_issue_id(target)?;
                let code = match code.as_str() {
                    "RELATION_RECIPROCAL" => "RELATION_RECIPROCAL",
                    "RELATION_TITLE" => "RELATION_TITLE",
                    "RELATION_MISSING" => "RELATION_MISSING",
                    "RELATION_UNREADABLE" => "RELATION_UNREADABLE",
                    _ => return Err(CacheError::Corrupt("invalid cached warning code".into())),
                };
                Ok(crate::diagnostic::RelationWarning::from_parts(
                    code,
                    message,
                    if owner == source { target } else { source },
                    source,
                    target,
                    needs_reason,
                ))
            })
            .collect()
    }

    /// Recheck one layer around changed records, including former warning neighbors.
    pub(super) fn inspect_warning_neighbors(&mut self) -> Result<(), CacheError> {
        let neighbors = std::mem::take(&mut self.warning_neighbors);
        self.inspect_files(&neighbors)?;
        self.warning_neighbors.clear();
        Ok(())
    }

    pub(super) fn retain_inspected_warnings(&mut self) -> Result<(), CacheError> {
        let has_previous: bool = self.connection.query_row(
            "SELECT EXISTS(SELECT 1 FROM relation_warnings)",
            [],
            |r| r.get(0),
        )?;
        let mut pairs = BTreeSet::new();
        let mut known = BTreeSet::new();
        let mut exists = self
            .connection
            .prepare("SELECT EXISTS(SELECT 1 FROM issues WHERE id=?1)")?;
        for (&owner, record) in &self.inspected {
            // Parsed records already provide current edges. Only retained findings
            // need the old neighborhood when an authored edge has disappeared.
            let mut neighbors = if has_previous {
                self.neighbors(owner)?
            } else {
                BTreeSet::new()
            };
            if let Some(record) = record {
                let issue = record.issue().expect("inspected valid record");
                neighbors.extend(issue.waits().iter().map(|r| r.target));
                neighbors.extend(issue.blocking().iter().map(|r| r.target));
            }
            for related in neighbors.into_iter().chain([owner]) {
                if !known.contains(&related)
                    && (matches!(self.inspected.get(&related), Some(Some(_)))
                        || exists.query_row([related.get()], |r| r.get::<_, bool>(0))?)
                {
                    known.insert(related);
                }
                if owner != related {
                    pairs.insert((owner.min(related), owner.max(related)));
                }
            }
        }
        let mut findings = self.inspected_findings(&known);
        self.connection.begin_immediate()?;
        let result = (|| {
            self.connection.execute(
                "DELETE FROM relation_warnings WHERE owner_issue_id NOT IN (SELECT id FROM issues)",
                [],
            )?;
            for (a, b) in pairs {
                let previous = if has_previous {
                    self.pair_findings(a, b)?
                } else {
                    Findings::new()
                };
                let mut current = findings.remove(&(a, b)).unwrap_or_default();
                let readable = |id| matches!(self.inspected.get(&id), Some(Some(_)));
                // Unreadable or uninspected endpoints cannot disprove earlier findings.
                if known.contains(&a) && known.contains(&b) && !(readable(a) && readable(b)) {
                    let mut retained = previous.clone();
                    retained.extend(current);
                    current = retained;
                }
                if current != previous {
                    self.replace_pair_findings(a, b, &current)?;
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
        self.warning_neighbors.clear();
        Ok(())
    }

    fn inspected_findings(
        &self,
        known: &BTreeSet<IssueId>,
    ) -> BTreeMap<(IssueId, IssueId), Findings> {
        let mut findings = BTreeMap::<_, Findings>::new();
        for (&owner, record) in &self.inspected {
            let Some(record) = record else { continue };
            let issue = record.issue().expect("inspected valid record");
            for warning in relation_warnings(issue, |related| match self.inspected.get(&related) {
                Some(Some(record)) => {
                    RelatedIssue::Present(record.issue().expect("inspected valid record"))
                }
                Some(None) if known.contains(&related) => RelatedIssue::Unreadable,
                _ if !known.contains(&related) => RelatedIssue::Missing,
                _ => RelatedIssue::Unchecked,
            }) {
                let related = warning.related_id();
                let pair = findings
                    .entry((owner.min(related), owner.max(related)))
                    .or_default();
                pair.insert(
                    (
                        owner,
                        warning.source_id(),
                        warning.target_id(),
                        warning.code().into(),
                    ),
                    (warning.message().into(), warning.needs_reason()),
                );
                if warning.code() == "RELATION_RECIPROCAL" {
                    pair.insert(
                        (
                            related,
                            warning.source_id(),
                            warning.target_id(),
                            warning.code().into(),
                        ),
                        (warning.message().into(), warning.needs_reason()),
                    );
                }
            }
        }
        findings
    }

    fn pair_findings(&self, a: IssueId, b: IssueId) -> Result<Findings, CacheError> {
        let mut query = self.connection.prepare(
            "SELECT owner_issue_id,source_id,target_id,code,message,needs_reason FROM relation_warnings
             WHERE (source_id=?1 AND target_id=?2) OR (source_id=?2 AND target_id=?1)",
        )?;
        query
            .query_map(params![a.get(), b.get()], |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, i64>(1)?,
                    r.get::<_, i64>(2)?,
                    r.get::<_, String>(3)?,
                    r.get::<_, String>(4)?,
                    r.get::<_, bool>(5)?,
                ))
            })?
            .map(|row| {
                let (owner, source, target, code, message, needs_reason) = row?;
                Ok((
                    (
                        parse_cached_issue_id(owner)?,
                        parse_cached_issue_id(source)?,
                        parse_cached_issue_id(target)?,
                        code,
                    ),
                    (message, needs_reason),
                ))
            })
            .collect()
    }

    fn replace_pair_findings(
        &self,
        a: IssueId,
        b: IssueId,
        findings: &Findings,
    ) -> Result<(), CacheError> {
        self.connection.execute(
            "DELETE FROM relation_warnings WHERE (source_id=?1 AND target_id=?2)
            OR (source_id=?2 AND target_id=?1)",
            params![a.get(), b.get()],
        )?;
        for ((owner, source, target, code), (message, needs_reason)) in findings {
            self.connection.execute(
                "INSERT INTO relation_warnings VALUES(?1,?2,?3,?4,?5,?6)",
                params![
                    owner.get(),
                    source.get(),
                    target.get(),
                    code,
                    message,
                    needs_reason
                ],
            )?;
        }
        Ok(())
    }
}
