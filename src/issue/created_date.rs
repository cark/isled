use std::fmt;

/// The Bash format validates the shape, not calendar validity.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CreatedDate(String);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ParseCreatedDateError;

impl CreatedDate {
    pub fn parse(bytes: &[u8]) -> Option<Self> {
        Self::try_parse(bytes).ok()
    }

    pub fn try_parse(bytes: &[u8]) -> Result<Self, ParseCreatedDateError> {
        let valid = bytes.len() == 10
            && bytes.iter().enumerate().all(|(index, byte)| match index {
                4 | 7 => *byte == b'-',
                _ => byte.is_ascii_digit(),
            });
        valid
            .then(|| Self(String::from_utf8(bytes.to_vec()).expect("validated ASCII")))
            .ok_or(ParseCreatedDateError)
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for ParseCreatedDateError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "created date must have YYYY-MM-DD shape")
    }
}

impl std::error::Error for ParseCreatedDateError {}
