use super::Name;
use std::fmt;

#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct Tag(Name);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ParseTagError;

impl Tag {
    pub fn parse(bytes: &[u8]) -> Option<Self> {
        Self::try_parse(bytes).ok()
    }

    pub fn try_parse(bytes: &[u8]) -> Result<Self, ParseTagError> {
        let name = Name::try_parse(bytes).map_err(|_| ParseTagError)?;
        if name.as_str().starts_with("priority-")
            && !matches!(
                name.as_str(),
                "priority-high" | "priority-normal" | "priority-low"
            )
        {
            return Err(ParseTagError);
        }
        Ok(Self(name))
    }

    pub fn as_str(&self) -> &str {
        self.0.as_str()
    }

    pub fn is_priority(&self) -> bool {
        self.as_str().starts_with("priority-")
    }
}

impl fmt::Display for ParseTagError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "invalid lowercase hyphenated tag")
    }
}

impl std::error::Error for ParseTagError {}

impl fmt::Display for Tag {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(formatter)
    }
}
