use super::error::AppError;
use isled::issue::Tag;

pub(crate) fn parse_tag(value: &str) -> Result<Tag, AppError> {
    Tag::try_parse(value.as_bytes())
        .map_err(|_| AppError::Invocation(format!("invalid tag: {value}")))
}
