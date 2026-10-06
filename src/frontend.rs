//! Bounded frontend views and changed-detail responses over the shared cache.
mod graph;
pub mod request;
mod wire;
use crate::{
    cache::{Cache, CacheError},
    filesystem::RecordRead,
    issue::IssueId,
    snapshot::{Snapshot, SnapshotSource},
};
use request::{Mode, Request};
use std::collections::{BTreeMap, BTreeSet};
use wire::{
    Bytes, Change, Detail, Payload, Problem, Response, SummaryData, View, WarningTarget, live_hash,
};

pub fn respond(cache: &mut Cache<'_>, request: &Request) -> Result<Vec<u8>, CacheError> {
    let changes = if request.mode == Mode::Choices {
        Vec::new()
    } else {
        let ids = request.details.keys().copied().collect();
        let records = cache.inspect_records(&ids)?;
        let mut issues = prepare_issues(cache, &records)?;
        changed_details(cache, request, &mut issues)?
    };
    let (graph_rows, graph) = match &request.graph {
        Some(input) => {
            let (rows, graph) = graph::prepare(cache, request, input)?;
            (Some(rows), Some(graph))
        }
        None => (None, None),
    };
    let (view_hash, view) = if matches!(request.mode, Mode::Details | Mode::Choices) {
        (None, None)
    } else {
        let mut summaries = match graph_rows {
            Some(rows) => rows,
            None => {
                cache.filter_summaries(&request.filters, &request.kinds, request.text.as_ref())?
            }
        };
        if let Some(limit) = request.filters.limit {
            summaries.truncate(limit);
        }
        let view = View {
            issues: summaries
                .iter()
                .map(|row| SummaryData::new(cache.root(), row))
                .collect::<Result<_, _>>()?,
            unavailable: cache
                .frontend_problems()?
                .into_iter()
                .map(|entry| {
                    Ok(Problem {
                        id: entry.id.to_string(),
                        path: Some(Bytes(
                            cache
                                .root()
                                .issue_path_bytes_lossless(entry.filename.as_bytes())?,
                        )),
                        error: entry.error.expect("unreadable row"),
                    })
                })
                .collect::<Result<_, CacheError>>()?,
        };
        let hash = live_hash(&view).map_err(json_error)?;
        let changed = request.view_hash.as_ref() != Some(&hash);
        (Some(hash), changed.then_some(view))
    };
    let mut output = serde_json::to_vec(&Response {
        schema_version: 5,
        graph,
        root: Bytes(cache.root().path_bytes_lossless()?.to_vec()),
        view_hash,
        view,
        changes,
        first_warning: first_warning(cache)?,
        warning_targets: cache
            .warning_ids()?
            .into_iter()
            .filter_map(|id| warning_target(cache, id).transpose())
            .collect::<Result<_, _>>()?,
        choices: if request.mode == Mode::Details {
            None
        } else {
            Some(match &request.choice_filter {
                Some(criteria) => cache.contextual_choices(
                    &criteria.filters,
                    &criteria.kinds,
                    criteria.text.as_ref(),
                )?,
                None => cache.frontend_choices()?,
            })
        },
    })
    .map_err(json_error)?;
    output.push(b'\n');
    Ok(output)
}

fn changed_details(
    cache: &Cache<'_>,
    request: &Request,
    issues: &mut BTreeMap<IssueId, crate::snapshot::SnapshotIssue>,
) -> Result<Vec<Change>, CacheError> {
    let mut changes = Vec::new();
    let mut target_rows = BTreeMap::new();
    for (&id, known_hash) in &request.details {
        let payload = detail_payload(cache, id, issues.remove(&id), &mut target_rows)?;
        let hash = live_hash(&payload).map_err(json_error)?;
        if known_hash.as_ref() != Some(&hash) {
            changes.push(Change {
                id: id.to_string(),
                hash,
                payload,
            });
        }
    }
    Ok(changes)
}

fn detail_payload(
    cache: &Cache<'_>,
    id: IssueId,
    issue: Option<crate::snapshot::SnapshotIssue>,
    target_rows: &mut BTreeMap<IssueId, Option<crate::cache::Summary>>,
) -> Result<Payload, CacheError> {
    Ok(if let Some(mut issue) = issue {
        let target_ids = issue
            .references()
            .iter()
            .map(|r| r.target())
            .chain(issue.warnings().iter().map(|w| w.related_id()))
            .collect::<BTreeSet<_>>();
        let mut targets = Vec::new();
        let mut unavailable = Vec::new();
        let mut known = BTreeSet::new();
        for target in target_ids {
            if let std::collections::btree_map::Entry::Vacant(entry) = target_rows.entry(target) {
                entry.insert(cache.frontend_summary(target)?);
            }
            if let Some(row) = &target_rows[&target] {
                known.insert(target);
                targets.push(SummaryData::new(cache.root(), row)?);
            } else if let Some(problem) = problem(cache, target)? {
                unavailable.push(problem);
            }
        }
        let row = cache
            .frontend_summary(id)?
            .ok_or_else(|| CacheError::Corrupt("inspected issue missing from cache".into()))?;
        issue.resolve_context(row.ready(), &known);
        Payload::Issue {
            detail: Box::new(Detail {
                issue,
                targets,
                unavailable,
            }),
        }
    } else if let Some(problem) = problem(cache, id)? {
        Payload::Problem { problem }
    } else {
        let errors = cache.frontend_identity_errors()?;
        if errors.is_empty() {
            Payload::Deleted
        } else {
            Payload::Problem {
                problem: Problem {
                    id: id.to_string(),
                    path: None,
                    error: format!("Cannot establish issue identity: {}", errors.join("; ")),
                },
            }
        }
    })
}

fn prepare_issues(
    cache: &Cache<'_>,
    records: &[RecordRead],
) -> Result<BTreeMap<IssueId, crate::snapshot::SnapshotIssue>, CacheError> {
    let paths = records
        .iter()
        .map(|record| {
            cache
                .root()
                .issue_path_bytes_lossless(record.identity.filename())
        })
        .collect::<Result<Vec<_>, _>>()?;
    let sources = records
        .iter()
        .zip(&paths)
        .map(|(record, path)| match &record.content {
            Ok(loaded) => SnapshotSource::record(loaded, path),
            Err(error) => SnapshotSource::unavailable(&record.identity, path, error),
        })
        .collect::<Vec<_>>();
    let snapshot = Snapshot::build(cache.root().path_bytes_lossless()?, &sources)
        .map_err(|e| CacheError::Invalid(e.to_string()))?;
    snapshot
        .into_issues()
        .map(|mut issue| {
            issue.set_warnings(cache.known_relation_warnings(issue.id())?);
            Ok((issue.id(), issue))
        })
        .collect()
}

fn problem(cache: &Cache<'_>, id: IssueId) -> Result<Option<Problem>, CacheError> {
    let Some(entry) = cache.frontend_entry(id)? else {
        return Ok(None);
    };
    entry
        .error
        .map(|error| {
            Ok(Problem {
                id: id.to_string(),
                path: Some(Bytes(
                    cache
                        .root()
                        .issue_path_bytes_lossless(entry.filename.as_bytes())?,
                )),
                error,
            })
        })
        .transpose()
}
fn json_error(error: serde_json::Error) -> CacheError {
    CacheError::Invalid(error.to_string())
}

fn first_warning(cache: &Cache<'_>) -> Result<Option<WarningTarget>, CacheError> {
    let Some(id) = cache.first_warning_id()? else {
        return Ok(None);
    };
    warning_target(cache, id)
}

fn warning_target(cache: &Cache<'_>, id: IssueId) -> Result<Option<WarningTarget>, CacheError> {
    if let Some(issue) = cache.frontend_summary(id)? {
        Ok(Some(WarningTarget::Issue {
            issue: SummaryData::new(cache.root(), &issue)?,
        }))
    } else {
        Ok(problem(cache, id)?.map(|problem| WarningTarget::Problem { problem }))
    }
}
