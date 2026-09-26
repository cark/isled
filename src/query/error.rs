//! Failures shared by the pure query operations.

use super::search::ParseSearchSnippetsError;
use crate::issue::IssueId;
use crate::record::RecordError;
use std::error::Error;
use std::fmt;

#[derive(Debug)]
pub enum QueryError {
    InvalidSearchSnippets(ParseSearchSnippetsError),
    Record(RecordError),
    MissingIssue(IssueId),
    DuplicateId(IssueId),
    InvalidUtf8,
    Json(serde_json::Error),
    MissingOutputPath,
    InconsistentRelation(IssueId),
}

impl fmt::Display for QueryError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidSearchSnippets(error) => error.fmt(formatter),
            Self::Record(error) => error.fmt(formatter),
            Self::MissingIssue(id) => write!(formatter, "issue not found: {id}"),
            Self::DuplicateId(id) => write!(formatter, "multiple issue files found for {id}"),
            Self::InvalidUtf8 => write!(formatter, "issue record is not valid UTF-8"),
            Self::Json(error) => error.fmt(formatter),
            Self::MissingOutputPath => write!(formatter, "issue output path is unavailable"),
            Self::InconsistentRelation(id) => {
                write!(
                    formatter,
                    "relation metadata for issue {id} is inconsistent"
                )
            }
        }
    }
}

impl Error for QueryError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Record(error) => Some(error),
            Self::Json(error) => Some(error),
            _ => None,
        }
    }
}

impl From<RecordError> for QueryError {
    fn from(error: RecordError) -> Self {
        Self::Record(error)
    }
}

impl From<ParseSearchSnippetsError> for QueryError {
    fn from(error: ParseSearchSnippetsError) -> Self {
        Self::InvalidSearchSnippets(error)
    }
}
