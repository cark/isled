//! Transport fields and their validated complete-draft counterpart.
use crate::{
    issue::{IssueId, Name, Tag, WaitReason},
    mutation::TitleText,
    record,
};
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Relation {
    pub id: String,
    pub reason: String,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Draft {
    pub title: String,
    pub kind: String,
    pub tags: Vec<String>,
    pub statement: String,
    pub evidence: Vec<String>,
    pub outcome: String,
    pub waiting_on: Vec<Relation>,
    pub blocking: Vec<Relation>,
}
#[derive(Clone, Debug, Serialize)]
pub struct FieldError {
    pub code: &'static str,
    pub field: String,
    pub message: String,
}
impl FieldError {
    pub(crate) fn new(field: impl Into<String>, message: impl ToString) -> Self {
        Self {
            code: "invalid",
            field: field.into(),
            message: message.to_string(),
        }
    }
}
pub struct ValidatedDraft {
    pub(super) draft: Draft,
    pub(super) kind: Name,
    pub(super) tags: Vec<Tag>,
    pub(super) waiting: Vec<(IssueId, WaitReason)>,
    pub(super) blocking: Vec<(IssueId, WaitReason)>,
}
impl ValidatedDraft {
    pub fn parse(mut draft: Draft) -> Result<Self, FieldError> {
        TitleText::parse(&draft.title).map_err(|e| FieldError::new("title", e))?;
        let kind =
            Name::try_parse(draft.kind.as_bytes()).map_err(|e| FieldError::new("kind", e))?;
        record::parse_statement(draft.statement.as_bytes())
            .map_err(|e| FieldError::new("statement", e))?;
        let mut seen = BTreeSet::new();
        let mut priority = false;
        let tags = draft
            .tags
            .iter()
            .map(|value| {
                let tag =
                    Tag::try_parse(value.as_bytes()).map_err(|e| FieldError::new("tags", e))?;
                if !seen.insert(value) {
                    return Err(FieldError::new("tags", "Duplicate tag"));
                }
                if tag.is_priority() && std::mem::replace(&mut priority, true) {
                    return Err(FieldError::new("tags", "Only one priority is allowed"));
                }
                Ok(tag)
            })
            .collect::<Result<Vec<_>, _>>()?;
        if draft.evidence.is_empty() {
            draft.evidence.push("Pending.".into());
        }
        for (index, entry) in draft.evidence.iter().enumerate() {
            if entry.is_empty() || entry.contains('\n') || entry.contains('\r') {
                return Err(FieldError::new(
                    format!("evidence.{index}"),
                    "Evidence must be one non-empty line",
                ));
            }
        }
        let evidence = draft
            .evidence
            .iter()
            .map(|e| format!("- {e}"))
            .collect::<Vec<_>>()
            .join("\n");
        record::parse_evidence(evidence.as_bytes()).map_err(|e| FieldError::new("evidence", e))?;
        record::parse_outcome(draft.outcome.as_bytes())
            .map_err(|e| FieldError::new("outcome", e))?;
        let waiting = parse_relations(&draft.waiting_on, "waiting_on")?;
        let blocking = parse_relations(&draft.blocking, "blocking")?;
        Ok(Self {
            draft,
            kind,
            tags,
            waiting,
            blocking,
        })
    }
    pub(crate) fn slug(&self) -> Name {
        crate::mutation::derive_slug(&self.draft.title)
    }
    pub fn neighbors(&self) -> impl Iterator<Item = IssueId> + '_ {
        self.waiting.iter().chain(&self.blocking).map(|(id, _)| *id)
    }
}
fn parse_relations(
    values: &[Relation],
    field: &str,
) -> Result<Vec<(IssueId, WaitReason)>, FieldError> {
    let mut seen = BTreeSet::new();
    values
        .iter()
        .enumerate()
        .map(|(i, value)| {
            let field = format!("{field}.{i}");
            let id = value
                .id
                .parse::<IssueId>()
                .map_err(|e| FieldError::new(&field, e))?;
            if !seen.insert(id) {
                return Err(FieldError::new(&field, "Duplicate dependency"));
            }
            let reason = WaitReason::parse(value.reason.as_bytes())
                .map_err(|e| FieldError::new(&field, e))?;
            Ok((id, reason))
        })
        .collect()
}
