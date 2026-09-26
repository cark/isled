use std::fmt;
use std::str::FromStr;

/// A stable semantic issue identity in the range 1 through 9,999.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct IssueId(u16);

impl IssueId {
    pub const MAX: u16 = 9_999;

    pub fn new(value: u16) -> Option<Self> {
        (1..=Self::MAX).contains(&value).then_some(Self(value))
    }

    pub fn get(self) -> u16 {
        self.0
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ParseIssueIdError;

impl fmt::Display for ParseIssueIdError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "issue ID must be one to four ASCII digits, optionally prefixed by #"
        )
    }
}

impl std::error::Error for ParseIssueIdError {}

impl FromStr for IssueId {
    type Err = ParseIssueIdError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        let digits = value.strip_prefix('#').unwrap_or(value).as_bytes();
        if digits.is_empty() || digits.len() > 4 || !digits.iter().all(u8::is_ascii_digit) {
            return Err(ParseIssueIdError);
        }
        let value = digits
            .iter()
            .fold(0_u16, |value, digit| value * 10 + u16::from(digit - b'0'));
        Self::new(value).ok_or(ParseIssueIdError)
    }
}

impl fmt::Display for IssueId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{:04}", self.0)
    }
}

/// A strict four-ASCII-digit issue identity used by canonical formats.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct CanonicalIssueId(IssueId);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ParseCanonicalIssueIdError;

impl CanonicalIssueId {
    pub fn parse(bytes: &[u8]) -> Result<Self, ParseCanonicalIssueIdError> {
        if bytes.len() != 4 || !bytes.iter().all(u8::is_ascii_digit) {
            return Err(ParseCanonicalIssueIdError);
        }
        let value = bytes
            .iter()
            .fold(0_u16, |value, digit| value * 10 + u16::from(digit - b'0'));
        IssueId::new(value)
            .map(Self)
            .ok_or(ParseCanonicalIssueIdError)
    }

    pub fn issue_id(self) -> IssueId {
        self.0
    }
}

impl fmt::Display for ParseCanonicalIssueIdError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "canonical issue ID must be four ASCII digits")
    }
}

impl std::error::Error for ParseCanonicalIssueIdError {}

impl From<CanonicalIssueId> for IssueId {
    fn from(value: CanonicalIssueId) -> Self {
        value.issue_id()
    }
}

impl fmt::Display for CanonicalIssueId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(formatter)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn issue_id_parses_ergonomic_cli_spellings() {
        for value in ["1", "01", "001", "0001", "#1", "#01", "#001", "#0001"] {
            let id = value.parse::<IssueId>().expect("accepted issue ID");
            assert_eq!(id.get(), 1);
            assert_eq!(id.to_string(), "0001");
        }
        assert_eq!("9999".parse::<IssueId>().map(IssueId::get), Ok(9_999));
        for invalid in [
            "", "#", "0", "0000", "#0000", "00001", "#00001", "+1", "-1", " 1", "1 ", "1.0",
            "issue-1", "١",
        ] {
            assert_eq!(invalid.parse::<IssueId>(), Err(ParseIssueIdError));
        }
    }

    #[test]
    fn canonical_issue_id_requires_exactly_four_ascii_digits() {
        assert_eq!(
            CanonicalIssueId::parse(b"0001").map(CanonicalIssueId::issue_id),
            Ok(IssueId::new(1).unwrap())
        );
        assert_eq!(
            CanonicalIssueId::parse(b"9999").map(CanonicalIssueId::issue_id),
            Ok(IssueId::new(9_999).unwrap())
        );
        for invalid in [b"0000".as_slice(), b"1", b"#001", b"12x4", b"00001"] {
            assert_eq!(
                CanonicalIssueId::parse(invalid),
                Err(ParseCanonicalIssueIdError)
            );
        }
    }
}
