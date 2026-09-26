//! Statement input, literal selection, and byte-preserving mutation plans.
use super::{MutationError, MutationPlan, Replacement, parse_record_document, unique_record};
use crate::{filesystem::StoredRecord, issue::IssueId, record};
use std::{fmt, num::NonZeroUsize};

pub const DEFAULT_SEPARATOR: &str = "---replacement---";

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StdinStatementText(String);

impl StdinStatementText {
    pub fn parse_stdin(input: &str) -> Result<Self, StatementEditError> {
        Ok(Self(parse_stdin_statement(input)?.to_owned()))
    }
}

fn parse_stdin_statement(input: &str) -> Result<&str, StatementEditError> {
    let text = unframe(input);
    record::parse_statement(text.as_bytes()).map_err(|_| StatementEditError::InvalidResult)?;
    Ok(text)
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum MatchSelection {
    #[default]
    Unique,
    Occurrence(NonZeroUsize),
    All,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StatementReplacement {
    old: String,
    new: String,
}

impl StatementReplacement {
    pub fn parse_stdin(input: &str, separator: &str) -> Result<Self, StatementEditError> {
        if separator.is_empty() || separator.contains(['\n', '\r']) {
            return Err(StatementEditError::InvalidSeparator);
        }
        let mut marker = None;
        let mut offset = 0;
        for line in input.split_inclusive('\n') {
            if unframe(line) == separator {
                if marker.is_some() {
                    return Err(StatementEditError::SeparatorCount);
                }
                marker = Some((offset, offset + line.len()));
            }
            offset += line.len();
        }
        let (start, end) = marker.ok_or(StatementEditError::SeparatorCount)?;
        let old = unframe(&input[..start]);
        if old.is_empty() {
            return Err(StatementEditError::EmptySearch);
        }
        Ok(Self {
            old: old.to_owned(),
            new: unframe(&input[end..]).to_owned(),
        })
    }

    fn apply(
        &self,
        statement: &str,
        selection: MatchSelection,
    ) -> Result<String, StatementEditError> {
        let count = statement.matches(&self.old).count();
        if count == 0 {
            return Err(StatementEditError::NoMatch);
        }
        match selection {
            MatchSelection::Unique if count != 1 => {
                return Err(StatementEditError::Ambiguous(count));
            }
            MatchSelection::Occurrence(n) if n.get() > count => {
                return Err(StatementEditError::MissingOccurrence {
                    requested: n.get(),
                    count,
                });
            }
            _ => {}
        }
        let mut output = String::new();
        let mut cursor = 0;
        for (index, (start, matched)) in statement.match_indices(&self.old).enumerate() {
            output.push_str(&statement[cursor..start]);
            let selected = match selection {
                MatchSelection::Unique | MatchSelection::All => true,
                MatchSelection::Occurrence(n) => index + 1 == n.get(),
            };
            output.push_str(if selected { &self.new } else { matched });
            cursor = start + matched.len();
        }
        output.push_str(&statement[cursor..]);
        Ok(output)
    }
}

fn unframe(input: &str) -> &str {
    input.strip_suffix('\n').unwrap_or(input)
}

pub fn statement_mutate_stdin(
    records: &[StoredRecord],
    id: IssueId,
    action: StatementAction,
    text: &StdinStatementText,
) -> Result<MutationPlan, MutationError> {
    plan_statement_mutation(records, id, action, text.0.as_bytes())
}

pub fn statement_replace(
    records: &[StoredRecord],
    id: IssueId,
    replacement: &StatementReplacement,
    selection: MatchSelection,
) -> Result<MutationPlan, MutationError> {
    let record = unique_record(records, id)?;
    let mut parsed = parse_record_document(record)?;
    let statement = std::str::from_utf8(&parsed.statement).expect("parsed record is UTF-8");
    let updated = replacement.apply(statement, selection)?;
    parsed.statement = updated.into_bytes();
    plan_statement_replacement(record, parsed)
}

// All Statement mutations converge here after parsing the existing record.
fn plan_statement_replacement(
    record: &StoredRecord,
    document: record::RecordDocument,
) -> Result<MutationPlan, MutationError> {
    let statement = &document.statement;
    record::parse_statement(statement).map_err(|_| StatementEditError::InvalidResult)?;
    let range = record::statement_range(record.bytes())?;
    if &record.bytes()[range.clone()] == statement {
        return Ok(MutationPlan::default());
    }
    let mut bytes = record.bytes()[..range.start].to_vec();
    bytes.extend_from_slice(statement);
    bytes.extend_from_slice(&record.bytes()[range.end..]);
    Ok(MutationPlan {
        replacements: vec![Replacement::corrected(
            record.filename().to_vec(),
            bytes,
            document,
        )],
    })
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum StatementEditError {
    InvalidSeparator,
    SeparatorCount,
    EmptySearch,
    NoMatch,
    Ambiguous(usize),
    MissingOccurrence { requested: usize, count: usize },
    InvalidResult,
}

impl fmt::Display for StatementEditError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidSeparator => write!(f, "separator must be one non-empty line"),
            Self::SeparatorCount => write!(
                f,
                "stdin must contain exactly one separator line; use --separator for collisions"
            ),
            Self::EmptySearch => write!(f, "old text must not be empty"),
            Self::NoMatch => write!(
                f,
                "no changes: old text was not found in Statement; read the issue and retry"
            ),
            Self::Ambiguous(n) => write!(
                f,
                "no changes: found {n} matches in Statement; include context or select --occurrence N or --all"
            ),
            Self::MissingOccurrence { requested, count } => write!(
                f,
                "no changes: occurrence {requested} requested but Statement has only {count} matches"
            ),
            Self::InvalidResult => write!(
                f,
                "no changes: Statement must be non-empty, have no leading/trailing newline, and contain no level-two headings; use ### or deeper for subsections"
            ),
        }
    }
}
impl std::error::Error for StatementEditError {}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StatementText(Vec<u8>);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ParseStatementTextError;

impl StatementText {
    pub fn parse(value: &str) -> Option<Self> {
        Self::try_parse(value).ok()
    }
    pub fn try_parse(value: &str) -> Result<Self, ParseStatementTextError> {
        (!value.is_empty() && !value.contains(['\n', '\t']))
            .then(|| Self(value.as_bytes().to_vec()))
            .ok_or(ParseStatementTextError)
    }
    pub fn as_bytes(&self) -> &[u8] {
        &self.0
    }
}

impl fmt::Display for ParseStatementTextError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "text must be one non-empty line without tabs")
    }
}
impl std::error::Error for ParseStatementTextError {}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AddStatementText(Vec<u8>);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ParseAddStatementTextError {
    InvalidLine,
    ReservedHeading,
}

impl AddStatementText {
    pub fn parse(value: &str) -> Result<Self, ParseAddStatementTextError> {
        if value.is_empty() || value.contains('\n') {
            return Err(ParseAddStatementTextError::InvalidLine);
        }
        crate::record::parse_statement(value.as_bytes())
            .map_err(|_| ParseAddStatementTextError::ReservedHeading)?;
        Ok(Self(value.as_bytes().to_vec()))
    }
    pub fn parse_stdin(value: &str) -> Result<Self, StatementEditError> {
        let text = parse_stdin_statement(value)?;
        Ok(Self(text.as_bytes().to_vec()))
    }
    pub fn as_bytes(&self) -> &[u8] {
        &self.0
    }
    pub fn as_str(&self) -> &str {
        std::str::from_utf8(&self.0).expect("validated UTF-8")
    }
}

impl fmt::Display for ParseAddStatementTextError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidLine => write!(formatter, "statement must be one non-empty line"),
            Self::ReservedHeading => write!(
                formatter,
                "Statement cannot contain level-two headings; use ### or deeper for subsections"
            ),
        }
    }
}
impl std::error::Error for ParseAddStatementTextError {}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum StatementAction {
    Set,
    Append,
}

pub fn statement_mutate(
    records: &[StoredRecord],
    id: IssueId,
    action: StatementAction,
    text: &StatementText,
) -> Result<MutationPlan, MutationError> {
    plan_statement_mutation(records, id, action, text.as_bytes())
}

fn plan_statement_mutation(
    records: &[StoredRecord],
    id: IssueId,
    action: StatementAction,
    text: &[u8],
) -> Result<MutationPlan, MutationError> {
    let record = unique_record(records, id)?;
    let mut parsed = parse_record_document(record)?;
    match action {
        StatementAction::Set => parsed.statement = text.to_vec(),
        StatementAction::Append => {
            parsed.statement.extend_from_slice(b"\n\n");
            parsed.statement.extend_from_slice(text);
        }
    }
    plan_statement_replacement(record, parsed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn framing_preserves_literal_payload_and_supports_deletion() {
        let edit = StatementReplacement::parse_stdin("a\n\nCUT\nb\n\n", "CUT").unwrap();
        assert_eq!(edit.old, "a\n");
        assert_eq!(edit.new, "b\n");
        for input in ["a\nCUT", "a\nCUT\n", "a\nCUT\n\n"] {
            let edit = StatementReplacement::parse_stdin(input, "CUT").unwrap();
            assert_eq!(edit.old, "a");
            assert_eq!(edit.new, "");
        }
        assert_eq!(
            StdinStatementText::parse_stdin("café\n\n- `$x`\n")
                .unwrap()
                .0,
            "café\n\n- `$x`"
        );
    }

    #[test]
    fn framing_rejects_missing_or_ambiguous_markers_and_empty_search() {
        for input in ["a\nCUT\nb\nCUT\nc", "a\n CUT\nb", "CUT\nb"] {
            assert!(StatementReplacement::parse_stdin(input, "CUT").is_err());
        }
        for separator in ["", "a\nb", "a\rb"] {
            assert_eq!(
                StatementReplacement::parse_stdin("a", separator),
                Err(StatementEditError::InvalidSeparator)
            );
        }
    }

    #[test]
    fn literal_selection_is_non_overlapping_and_does_not_rematch_replacements() {
        let edit = StatementReplacement::parse_stdin("aa\nCUT\naaaa", "CUT").unwrap();
        assert_eq!(edit.apply("aaa", MatchSelection::Unique).unwrap(), "aaaaa");
        assert_eq!(edit.apply("aaaa", MatchSelection::All).unwrap(), "aaaaaaaa");
        assert_eq!(
            edit.apply(
                "aaaa",
                MatchSelection::Occurrence(NonZeroUsize::new(2).unwrap())
            )
            .unwrap(),
            "aaaaaa"
        );
        assert_eq!(
            edit.apply("aaaa", MatchSelection::Unique),
            Err(StatementEditError::Ambiguous(2))
        );
        assert_eq!(
            edit.apply("AA", MatchSelection::All),
            Err(StatementEditError::NoMatch)
        );
        assert!(matches!(
            edit.apply(
                "aa",
                MatchSelection::Occurrence(NonZeroUsize::new(2).unwrap())
            ),
            Err(StatementEditError::MissingOccurrence { .. })
        ));
    }
}
