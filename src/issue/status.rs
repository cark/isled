use std::fmt;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Status {
    Open,
    Closed,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ParseStatusError;

impl Status {
    pub fn parse(bytes: &[u8]) -> Option<Self> {
        Self::try_parse(bytes).ok()
    }

    pub fn try_parse(bytes: &[u8]) -> Result<Self, ParseStatusError> {
        match bytes {
            b"open" => Ok(Self::Open),
            b"closed" => Ok(Self::Closed),
            _ => Err(ParseStatusError),
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Open => "open",
            Self::Closed => "closed",
        }
    }
}

impl fmt::Display for ParseStatusError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "status must be open or closed")
    }
}

impl std::error::Error for ParseStatusError {}
