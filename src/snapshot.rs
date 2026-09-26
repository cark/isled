//! Pure application view consumed by local read-only frontends.

pub mod json;

use crate::filesystem::{StoredIdentity, StoredRecord};
use crate::issue::{IssueId, Name, Status};
use crate::record::RecordError;
use crate::reference::{self, InlineIssueReference};
use std::collections::{BTreeMap, BTreeSet};
use std::error::Error;
use std::fmt;

#[derive(Clone, Copy, Debug)]
pub struct SnapshotSource<'a> {
    filename: &'a [u8],
    path: &'a [u8],
    record: Result<&'a StoredRecord, &'a str>,
}

impl<'a> SnapshotSource<'a> {
    pub fn record(record: &'a StoredRecord, path: &'a [u8]) -> Self {
        Self {
            filename: record.filename(),
            path,
            record: Ok(record),
        }
    }

    pub fn unavailable(identity: &'a StoredIdentity, path: &'a [u8], error: &'a str) -> Self {
        Self {
            filename: identity.filename(),
            path,
            record: Err(error),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Snapshot {
    root: Vec<u8>,
    issues: Vec<SnapshotIssue>,
    unavailable: Vec<UnavailableIssue>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct UnavailableIssue {
    id: IssueId,
    path: Vec<u8>,
    error: String,
}
impl UnavailableIssue {
    pub fn id(&self) -> IssueId {
        self.id
    }
    pub fn path(&self) -> &[u8] {
        &self.path
    }
    pub fn error(&self) -> &str {
        &self.error
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SnapshotIssue {
    id: IssueId,
    status: Status,
    kind: Name,
    ready: bool,
    title: Vec<u8>,
    path: Vec<u8>,
    content: Vec<u8>,
    references: Vec<InlineIssueReference>,
    warnings: Vec<crate::diagnostic::RelationWarning>,
}

impl Snapshot {
    pub fn build(root: &[u8], sources: &[SnapshotSource<'_>]) -> Result<Self, SnapshotError> {
        let mut parsed_sources = Vec::new();
        let mut unavailable = Vec::new();
        let mut identities = BTreeSet::new();
        for source in sources {
            let (id, _) = crate::record::parse_filename(source.filename).map_err(|error| {
                SnapshotError::Record {
                    filename: source.filename.to_vec(),
                    error,
                }
            })?;
            if !identities.insert(id) {
                return Err(SnapshotError::DuplicateId(id));
            }
            let parsed = source.record.map_err(str::to_owned).and_then(|record| {
                record
                    .issue()
                    .map(|issue| (record, issue))
                    .map_err(|error| error.to_string())
            });
            match parsed {
                Ok((record, issue)) => parsed_sources.push((source, record, issue)),
                Err(error) => unavailable.push(UnavailableIssue {
                    id,
                    path: source.path.to_vec(),
                    error,
                }),
            }
        }
        unavailable.sort_by_key(|issue| issue.id);
        parsed_sources.sort_by_key(|(_, _, issue)| issue.id);

        let known_targets = parsed_sources.iter().map(|(_, _, r)| r.id()).collect();
        let unavailable_ids = unavailable.iter().map(|r| r.id).collect::<BTreeSet<_>>();
        let index = parsed_sources
            .iter()
            .map(|(_, _, r)| (r.id(), *r))
            .collect::<std::collections::BTreeMap<_, _>>();
        let mut warnings = parsed_sources
            .iter()
            .map(|(_, _, issue)| {
                let warnings = crate::diagnostic::relation_warnings(issue, |id| {
                    if unavailable_ids.contains(&id) {
                        return crate::diagnostic::RelatedIssue::Unreadable;
                    }
                    index
                        .get(&id)
                        .map_or(crate::diagnostic::RelatedIssue::Missing, |issue| {
                            crate::diagnostic::RelatedIssue::Present(issue)
                        })
                });
                (issue.id(), warnings)
            })
            .collect::<std::collections::BTreeMap<_, _>>();
        let mirrors = warnings
            .iter()
            .flat_map(|(&owner, items)| {
                items
                    .iter()
                    .filter(|w| w.code() == "RELATION_RECIPROCAL")
                    .map(move |w| (w.related_id(), w.for_other_endpoint(owner)))
            })
            .collect::<Vec<_>>();
        for (id, warning) in mirrors {
            if let Some(items) = warnings.get_mut(&id) {
                items.push(warning);
            }
        }
        let mut incoming: BTreeMap<IssueId, BTreeSet<IssueId>> = BTreeMap::new();
        for (_, _, issue) in &parsed_sources {
            for relation in issue.blocking() {
                incoming
                    .entry(relation.target)
                    .or_default()
                    .insert(issue.id());
            }
        }
        let statuses = parsed_sources
            .iter()
            .map(|(_, _, issue)| (issue.id, issue.status))
            .collect::<std::collections::BTreeMap<_, _>>();
        let issues = parsed_sources
            .into_iter()
            .map(|(source, record, issue)| {
                let id = issue.id;
                let status = issue.status;
                let content = std::str::from_utf8(record.bytes())
                    .expect("RecordDocument guarantees UTF-8 content");
                let references = reference::recognize_issue_references(content, &known_targets);
                SnapshotIssue {
                    id,
                    status,
                    kind: issue.kind().clone(),
                    ready: status == Status::Open
                        && issue.waits.iter().all(|relation| {
                            statuses.get(&relation.target) == Some(&Status::Closed)
                        })
                        && incoming
                            .get(&id)
                            .into_iter()
                            .flatten()
                            .all(|target| statuses.get(target) == Some(&Status::Closed)),
                    title: issue.title.clone(),
                    path: source.path.to_vec(),
                    content: record.bytes().to_vec(),
                    references,
                    warnings: warnings.remove(&id).unwrap_or_default(),
                }
            })
            .collect();
        Ok(Self {
            root: root.to_vec(),
            issues,
            unavailable,
        })
    }

    pub fn root(&self) -> &[u8] {
        &self.root
    }

    pub fn issues(&self) -> &[SnapshotIssue] {
        &self.issues
    }
    pub(crate) fn into_issues(self) -> impl Iterator<Item = SnapshotIssue> {
        self.issues.into_iter()
    }
    pub fn unavailable(&self) -> &[UnavailableIssue] {
        &self.unavailable
    }
}

impl SnapshotIssue {
    pub(crate) fn set_warnings(&mut self, warnings: Vec<crate::diagnostic::RelationWarning>) {
        self.warnings = warnings;
    }

    pub(crate) fn resolve_context(&mut self, ready: bool, known: &BTreeSet<IssueId>) {
        self.ready = ready;
        for reference in &mut self.references {
            reference.resolve(known.contains(&reference.target()));
        }
    }
    pub fn id(&self) -> IssueId {
        self.id
    }

    pub fn status(&self) -> Status {
        self.status
    }

    pub fn kind(&self) -> &Name {
        &self.kind
    }

    pub fn is_ready(&self) -> bool {
        self.ready
    }

    pub fn title(&self) -> &[u8] {
        &self.title
    }

    pub fn path(&self) -> &[u8] {
        &self.path
    }

    pub fn content(&self) -> &[u8] {
        &self.content
    }

    pub fn references(&self) -> &[InlineIssueReference] {
        &self.references
    }

    pub fn warnings(&self) -> &[crate::diagnostic::RelationWarning] {
        &self.warnings
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum SnapshotError {
    Record {
        filename: Vec<u8>,
        error: RecordError,
    },
    DuplicateId(IssueId),
}

impl fmt::Display for SnapshotError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Record { filename, error } => write!(
                formatter,
                "cannot include record {} in snapshot: {error}",
                String::from_utf8_lossy(filename)
            ),
            Self::DuplicateId(id) => write!(formatter, "duplicate issue ID in snapshot: {id}"),
        }
    }
}

impl Error for SnapshotError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Record { error, .. } => Some(error),
            Self::DuplicateId(_) => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record(id: &str, status: &str, title: &str) -> Vec<u8> {
        format!(
            "# {id} — {title}\n\n## Metadata\n\n- **Status:** {status}\n- **Kind:** feature\n- **Created:** 2026-09-02\n\n## Statement\n\nStatement.\n\n## Evidence\n\n- Pending.\n\n## Outcome\n\nPending.\n"
        )
        .into_bytes()
    }

    #[test]
    fn builds_an_id_ordered_view_from_unsorted_sources() {
        let second = record("0002", "closed", "Second");
        let first = record("0001", "open", "First");
        let source_record_0 =
            StoredRecord::new(b"0002-second.md".to_vec(), second.to_vec()).unwrap();
        let source_record_1 = StoredRecord::new(b"0001-first.md".to_vec(), first.to_vec()).unwrap();
        let sources = [
            SnapshotSource::record(&source_record_0, b"/project/.issues/0002-second.md"),
            SnapshotSource::record(&source_record_1, b"/project/.issues/0001-first.md"),
        ];

        let snapshot = Snapshot::build(b"/project", &sources).expect("valid snapshot");

        assert_eq!(snapshot.root(), b"/project");
        assert_eq!(snapshot.issues()[0].id().to_string(), "0001");
        assert_eq!(snapshot.issues()[0].status(), Status::Open);
        assert!(snapshot.issues()[0].is_ready());
        assert_eq!(snapshot.issues()[0].title(), b"First");
        assert_eq!(snapshot.issues()[0].content(), first);
        assert!(snapshot.issues()[0].references().is_empty());
        assert_eq!(snapshot.issues()[1].id().to_string(), "0002");
        assert!(!snapshot.issues()[1].is_ready());
    }

    #[test]
    fn an_open_issue_with_a_wait_is_not_ready() {
        let waiting = b"# 0001 \xe2\x80\x94 Waiting\n\n## Metadata\n\n- **Status:** open\n- **Kind:** feature\n- **Created:** 2026-09-02\n- **Waiting on:**\n  - #0002 \xe2\x80\x94 Blocker\n    - **Reason:** Needed first.\n\n## Statement\n\nWaiting.\n\n## Evidence\n\n- Pending.\n\n## Outcome\n\nPending.\n";
        let blocker = b"# 0002 \xe2\x80\x94 Blocker\n\n## Metadata\n\n- **Status:** open\n- **Kind:** feature\n- **Created:** 2026-09-02\n- **Blocking:**\n  - #0001 \xe2\x80\x94 Waiting\n\n## Statement\n\nStatement.\n\n## Evidence\n\n- Pending.\n\n## Outcome\n\nPending.\n".to_vec();
        let source_record_0 =
            StoredRecord::new(b"0001-waiting.md".to_vec(), (waiting).to_vec()).unwrap();
        let source_record_1 =
            StoredRecord::new(b"0002-blocker.md".to_vec(), blocker.to_vec()).unwrap();
        let sources = [
            SnapshotSource::record(&source_record_0, b"/project/.issues/0001-waiting.md"),
            SnapshotSource::record(&source_record_1, b"/project/.issues/0002-blocker.md"),
        ];

        let snapshot = Snapshot::build(b"/project", &sources).expect("valid snapshot");

        assert!(!snapshot.issues()[0].is_ready());
        assert!(snapshot.issues()[1].is_ready());
    }

    #[test]
    fn rejects_duplicate_issue_identity() {
        let first = record("0001", "open", "First");
        let duplicate = record("0001", "open", "Duplicate");
        let source_record_0 = StoredRecord::new(b"0001-first.md".to_vec(), first.to_vec()).unwrap();
        let source_record_1 =
            StoredRecord::new(b"0001-duplicate.md".to_vec(), duplicate.to_vec()).unwrap();
        let sources = [
            SnapshotSource::record(&source_record_0, b"/project/.issues/0001-first.md"),
            SnapshotSource::record(&source_record_1, b"/project/.issues/0001-duplicate.md"),
        ];

        assert_eq!(
            Snapshot::build(b"/project", &sources),
            Err(SnapshotError::DuplicateId(IssueId::new(1).unwrap()))
        );
    }
}
