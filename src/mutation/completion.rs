//! Validated completion-entry text and shared section framing.
use std::fmt;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SectionText(Vec<u8>);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ParseSectionTextError;

impl SectionText {
    pub fn parse(value: &str) -> Option<Self> {
        Self::try_parse(value).ok()
    }
    pub fn try_parse(value: &str) -> Result<Self, ParseSectionTextError> {
        (!value.is_empty() && !value.contains('\n'))
            .then(|| Self(value.as_bytes().to_vec()))
            .ok_or(ParseSectionTextError)
    }
    pub fn as_bytes(&self) -> &[u8] {
        &self.0
    }
}

impl fmt::Display for ParseSectionTextError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "text must be one non-empty line")
    }
}
impl std::error::Error for ParseSectionTextError {}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum SectionState {
    Pending,
    Recorded,
}

pub(super) fn section_body<'a>(bytes: &'a [u8], start: &[u8], end: &[u8]) -> Option<&'a [u8]> {
    let start = find_bytes(bytes, start)? + start.len();
    let end = find_bytes(&bytes[start..], end)? + start;
    Some(&bytes[start..end])
}

pub(super) fn find_bytes(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .position(|part| part == needle)
}
