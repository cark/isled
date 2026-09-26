//! Validated human inspection results over one deduplicated neighborhood.
use super::{Cache, CacheError};
use crate::{diagnostic::RelationWarning, filesystem::StoredRecord, issue::IssueId};
use std::collections::{BTreeMap, BTreeSet};

pub struct ShownIssue {
    content: Result<StoredRecord, String>,
    warnings: Vec<RelationWarning>,
}

impl ShownIssue {
    pub fn content(&self) -> Result<&StoredRecord, &str> {
        self.content.as_ref().map_err(String::as_str)
    }

    pub fn warnings(&self) -> &[RelationWarning] {
        &self.warnings
    }
}

impl Cache<'_> {
    /// Inspect valid requested records, retaining individual failures as data.
    pub fn show_batch(
        &mut self,
        ids: &BTreeSet<IssueId>,
    ) -> Result<BTreeMap<IssueId, ShownIssue>, CacheError> {
        let records = self.inspect_records(ids)?;
        let mut contents = records
            .into_iter()
            .map(|read| (read.identity.id(), read.content))
            .collect::<BTreeMap<_, _>>();

        let identity_errors = self.frontend_identity_errors()?;
        ids.iter()
            .map(|&id| {
                let content = contents.remove(&id).unwrap_or_else(|| {
                    Err(if identity_errors.is_empty() {
                        format!("issue not found: {id}")
                    } else {
                        format!(
                            "Cannot establish issue identity: {}",
                            identity_errors.join("; ")
                        )
                    })
                });
                Ok((
                    id,
                    ShownIssue {
                        content,
                        warnings: self.known_relation_warnings(id)?,
                    },
                ))
            })
            .collect::<Result<_, CacheError>>()
    }
}
