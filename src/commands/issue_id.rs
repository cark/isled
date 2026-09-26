use super::error::AppError;
use isled::issue::IssueId;

pub(crate) fn parse_issue_id(value: &str) -> Result<IssueId, AppError> {
    value.parse::<IssueId>().map_err(|_| {
        AppError::Invocation(format!(
            "issue ID must be 1-4 ASCII digits, optionally prefixed by # (1-9999): {value}"
        ))
    })
}
