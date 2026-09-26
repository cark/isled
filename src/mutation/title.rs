use crate::filesystem::StoredRecord;
use crate::issue::{Issue, IssueId};
use crate::record::RecordDocument;
use std::fmt;

use super::{
    MutationError, MutationPlan, parse_record_document, plan_document_replacements, unique_record,
};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TitleText(String);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ParseTitleTextError;

impl TitleText {
    pub fn parse(value: &str) -> Result<Self, ParseTitleTextError> {
        (!value.is_empty() && !value.contains(['\n', '\t']))
            .then(|| Self(value.to_owned()))
            .ok_or(ParseTitleTextError)
    }
    pub fn as_str(&self) -> &str {
        &self.0
    }
    pub fn as_bytes(&self) -> &[u8] {
        self.0.as_bytes()
    }
}

impl fmt::Display for ParseTitleTextError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "title must be one non-empty line without tabs")
    }
}
impl std::error::Error for ParseTitleTextError {}

pub fn title_set(
    records: &[StoredRecord],
    id: IssueId,
    title: &TitleText,
) -> Result<MutationPlan, MutationError> {
    let target = unique_record(records, id)?;
    if target
        .document()
        .map_err(MutationError::Record)?
        .issue
        .title
        == title.as_bytes()
    {
        return Ok(MutationPlan::default());
    }
    let mut changed = Vec::new();
    for record in records {
        if let Some(document) = rewrite_titles(record, id, title)? {
            changed.push((record, document));
        }
    }
    Ok(plan_document_replacements(changed))
}

fn rewrite_titles(
    record: &StoredRecord,
    id: IssueId,
    title: &TitleText,
) -> Result<Option<RecordDocument>, MutationError> {
    let mut document = parse_record_document(record)?;
    let mut touched = false;
    for field in matching_titles(&mut document.issue, id) {
        field.clear();
        field.extend_from_slice(title.as_bytes());
        touched = true;
    }
    Ok(touched.then_some(document))
}

fn matching_titles(issue: &mut Issue, id: IssueId) -> impl Iterator<Item = &mut Vec<u8>> {
    let heading = (issue.id == id).then_some(&mut issue.title).into_iter();
    let waits = issue
        .waits
        .iter_mut()
        .filter(move |relation| relation.target == id)
        .map(|relation| &mut relation.title);
    let blocking = issue
        .blocking
        .iter_mut()
        .filter(move |relation| relation.target == id)
        .map(|relation| &mut relation.title);
    heading.chain(waits).chain(blocking)
}
