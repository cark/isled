//! Pure, neighborhood-scoped relation diagnostics; never repairs stored records.
use crate::issue::{Issue, IssueId};

pub enum RelatedIssue<'a> {
    Present(&'a Issue),
    Missing,
    Unreadable,
    Unchecked,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RelationWarning {
    code: &'static str,
    message: String,
    related_id: IssueId,
    source_id: IssueId,
    target_id: IssueId,
    needs_reason: bool,
}

impl RelationWarning {
    pub(crate) fn from_parts(
        code: &'static str,
        message: String,
        related_id: IssueId,
        source_id: IssueId,
        target_id: IssueId,
        needs_reason: bool,
    ) -> Self {
        Self {
            code,
            message,
            related_id,
            source_id,
            target_id,
            needs_reason,
        }
    }

    pub fn code(&self) -> &'static str {
        self.code
    }
    pub fn message(&self) -> &str {
        &self.message
    }
    pub fn related_id(&self) -> IssueId {
        self.related_id
    }
    pub fn source_id(&self) -> IssueId {
        self.source_id
    }
    pub fn target_id(&self) -> IssueId {
        self.target_id
    }
    pub fn needs_reason(&self) -> bool {
        self.needs_reason
    }
    pub fn for_other_endpoint(&self, owner: IssueId) -> Self {
        let mut warning = self.clone();
        warning.related_id = owner;
        warning
    }
}

pub fn relation_warnings<'a>(
    issue: &Issue,
    mut lookup: impl FnMut(IssueId) -> RelatedIssue<'a>,
) -> Vec<RelationWarning> {
    let mut warnings = Vec::new();
    let relations = issue
        .waits()
        .iter()
        .map(|r| (r.target, r.title.as_slice(), true))
        .chain(
            issue
                .blocking()
                .iter()
                .map(|r| (r.target, r.title.as_slice(), false)),
        );
    for (id, title, waiting) in relations {
        let field = if waiting { "Waiting on" } else { "Blocking" };
        let mut add = |code, message| {
            warnings.push(RelationWarning {
                code,
                message,
                related_id: id,
                source_id: if waiting { issue.id() } else { id },
                target_id: if waiting { id } else { issue.id() },
                needs_reason: !waiting,
            })
        };
        match lookup(id) {
            RelatedIssue::Missing => add(
                "RELATION_MISSING",
                format!("{field} refers to missing issue #{id}."),
            ),
            RelatedIssue::Unreadable => add(
                "RELATION_UNREADABLE",
                format!("{field} refers to unreadable issue #{id}; inspect it with show/check."),
            ),
            RelatedIssue::Unchecked => {}
            RelatedIssue::Present(other) => {
                if title != other.title() {
                    add(
                        "RELATION_TITLE",
                        format!("{field} has a stale copied title for #{id}."),
                    );
                }
                let reciprocal = if waiting {
                    other.blocking().iter().any(|r| r.target == issue.id())
                } else {
                    other.waits().iter().any(|r| r.target == issue.id())
                };
                if !reciprocal {
                    let reverse = if waiting { "Blocking" } else { "Waiting on" };
                    add(
                        "RELATION_RECIPROCAL",
                        format!(
                            "Issue #{id} lacks reciprocal {reverse} #{source}.",
                            source = issue.id()
                        ),
                    );
                }
            }
        }
    }
    warnings
}
