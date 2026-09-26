use std::fmt;

/// A lowercase ASCII name used by slugs, kinds, and ordinary tags.
#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct Name(String);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ParseNameError;

impl Name {
    pub fn parse(bytes: &[u8]) -> Option<Self> {
        Self::try_parse(bytes).ok()
    }

    pub fn try_parse(bytes: &[u8]) -> Result<Self, ParseNameError> {
        let valid = !bytes.is_empty()
            && bytes.first() != Some(&b'-')
            && bytes.last() != Some(&b'-')
            && bytes
                .iter()
                .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || *byte == b'-');
        valid
            .then(|| Self(String::from_utf8(bytes.to_vec()).expect("validated ASCII")))
            .ok_or(ParseNameError)
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for ParseNameError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "name must be lowercase ASCII words separated by hyphens"
        )
    }
}

impl std::error::Error for ParseNameError {}

impl fmt::Display for Name {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(formatter)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn names_match_the_bash_vocabulary() {
        assert!(Name::parse(b"feature-request-2").is_some());
        for invalid in [b"".as_slice(), b"-bad", b"bad-", b"Bad", b"bad_name"] {
            assert_eq!(Name::try_parse(invalid), Err(ParseNameError));
        }
    }
}
