use super::IssueId;
use std::fmt;

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct WaitReason(Vec<u8>);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ParseWaitReasonError;

impl WaitReason {
    pub fn parse(bytes: &[u8]) -> Result<Self, ParseWaitReasonError> {
        if bytes.is_empty() || bytes.contains(&b'\n') || std::str::from_utf8(bytes).is_err() {
            return Err(ParseWaitReasonError);
        }
        Ok(Self(bytes.to_vec()))
    }

    pub fn as_bytes(&self) -> &[u8] {
        &self.0
    }
}

impl fmt::Display for ParseWaitReasonError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "wait reason must be one non-empty line")
    }
}

impl std::error::Error for ParseWaitReasonError {}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WaitRelation {
    pub target: IssueId,
    /// Copied semantic title for human-readable local context.
    pub title: Vec<u8>,
    /// Kept as bytes to preserve the validated UTF-8 record exactly.
    pub reason: Vec<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct IssueRelation {
    pub target: IssueId,
    /// Copied semantic title for human-readable local context.
    pub title: Vec<u8>,
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn wait_reasons_retain_line_and_utf8_proof() {
        assert_eq!(
            WaitReason::parse("because ✓".as_bytes())
                .unwrap()
                .as_bytes(),
            "because ✓".as_bytes()
        );
        for invalid in [b"".as_slice(), b"two\nlines", b"\xff"] {
            assert_eq!(WaitReason::parse(invalid), Err(ParseWaitReasonError));
        }
    }
}
