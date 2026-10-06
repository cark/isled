use crate::issue::{
    CanonicalIssueId, CreatedDate, Issue, IssueId, IssueRelation, Name, Status, Tag, WaitReason,
    WaitRelation,
};
use std::{borrow::Cow, error::Error, fmt};

mod state;
mod work;
use crate::work_log::WorkLog;
pub(crate) use state::RecordState;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct IssueRecord {
    issue: Issue,
    bytes: Vec<u8>,
}

impl IssueRecord {
    pub fn parse(filename: &[u8], bytes: Vec<u8>) -> Result<Self, RecordError> {
        let document = RecordDocument::parse(filename, &bytes)?;
        Ok(Self {
            issue: document.issue,
            bytes,
        })
    }

    pub fn issue(&self) -> &Issue {
        &self.issue
    }
    pub fn bytes(&self) -> &[u8] {
        &self.bytes
    }
}

/// Parsed canonical fields for mutation planning and validated read consumers.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct RecordDocument {
    pub issue: Issue,
    pub statement: Vec<u8>,
    pub evidence: Vec<Vec<u8>>,
    pub outcome: Vec<u8>,
    pub work_log: WorkLog,
    pub work_log_source: Option<Vec<u8>>,
}

impl RecordDocument {
    pub(crate) fn parse(filename: &[u8], bytes: &[u8]) -> Result<Self, RecordError> {
        validate_utf8(filename, bytes)?;
        let (id, slug) = parse_filename(filename)?;
        let sections = split_document(bytes)?;
        let metadata = parse_metadata(sections.metadata)?;
        let work_log = work::parse_log(sections.work_log, metadata.work_state.as_ref())?;
        Ok(Self {
            work_log,
            work_log_source: sections.work_log.map(Vec::from),
            issue: metadata.into_issue(id, slug, parse_heading(sections.heading, id)?.to_vec()),
            statement: parse_statement(sections.statement)?.to_vec(),
            evidence: parse_evidence(sections.evidence)?,
            outcome: parse_outcome(sections.outcome)?.to_vec(),
        })
    }

    pub(crate) fn render(&self) -> Vec<u8> {
        let issue = &self.issue;
        let mut output = format!(
            "# {} — {}\n\n## Metadata\n\n- **Status:** {}\n- **Kind:** {}\n- **Created:** {}\n",
            issue.id,
            std::str::from_utf8(&issue.title).expect("record titles are valid UTF-8"),
            issue.status.as_str(),
            issue.kind,
            issue.created.as_str()
        )
        .into_bytes();
        work::render_state(&mut output, issue.work_state.as_ref());
        if !issue.tags.is_empty() {
            output.extend_from_slice(b"- **Tags:** ");
            for (index, tag) in issue.tags.iter().enumerate() {
                if index > 0 {
                    output.extend_from_slice(b", ");
                }
                output.extend_from_slice(tag.as_str().as_bytes());
            }
            output.push(b'\n');
        }
        if !issue.waits.is_empty() {
            output.extend_from_slice(b"- **Waiting on:**\n");
            for relation in &issue.waits {
                output.extend_from_slice(format!("  - #{} — ", relation.target).as_bytes());
                output.extend_from_slice(&relation.title);
                output.extend_from_slice(b"\n    - **Reason:** ");
                output.extend_from_slice(&relation.reason);
                output.push(b'\n');
            }
        }
        if !issue.blocking.is_empty() {
            output.extend_from_slice(b"- **Blocking:**\n");
            for relation in &issue.blocking {
                output.extend_from_slice(format!("  - #{} — ", relation.target).as_bytes());
                output.extend_from_slice(&relation.title);
                output.push(b'\n');
            }
        }
        output.extend_from_slice(b"\n## Statement\n\n");
        output.extend_from_slice(&self.statement);
        if !self.work_log.spans().is_empty() {
            output.extend_from_slice(b"\n\n## Work log\n\n");
            match &self.work_log_source {
                Some(source) => output.extend_from_slice(source),
                None => output.extend_from_slice(&work::render_log(&self.work_log)),
            }
        }
        output.extend_from_slice(b"\n\n## Evidence\n\n");
        for entry in &self.evidence {
            output.extend_from_slice(b"- ");
            output.extend_from_slice(entry);
            output.push(b'\n');
        }
        output.extend_from_slice(b"\n## Outcome\n\n");
        output.extend_from_slice(&self.outcome);
        output.push(b'\n');
        output
    }
}

/// A validated metadata view retaining parsed fields and borrowing source bytes.
#[derive(Debug)]
pub struct RecordView<'a> {
    id: IssueId,
    filename: &'a [u8],
    bytes: &'a [u8],
    header: Cow<'a, Issue>,
}

impl<'a> RecordView<'a> {
    pub fn new(filename: &'a [u8], bytes: &'a [u8]) -> Result<Self, RecordError> {
        validate_utf8(filename, bytes)?;
        let (id, slug) = parse_filename(filename)?;
        let parsed = parse_header(bytes, id)?;
        let header = Cow::Owned(parsed.metadata.into_issue(id, slug, parsed.title.to_vec()));
        Ok(Self {
            id,
            filename,
            bytes,
            header,
        })
    }
    pub(crate) fn retained(
        record: &'a crate::filesystem::StoredRecord,
    ) -> Result<Self, RecordError> {
        let header = record.header()?;
        Ok(Self {
            id: header.id(),
            filename: record.filename(),
            bytes: record.bytes(),
            header: Cow::Borrowed(header),
        })
    }

    pub fn id(&self) -> IssueId {
        self.id
    }
    pub fn filename(&self) -> &'a [u8] {
        self.filename
    }
    pub fn bytes(&self) -> &'a [u8] {
        self.bytes
    }
    pub fn title(&self) -> &[u8] {
        &self.header.title
    }
    pub fn status(&self) -> Status {
        self.header.status
    }
    pub fn kind(&self) -> &Name {
        &self.header.kind
    }
    pub fn work_state_kind(&self) -> crate::issue::WorkStateKind {
        self.header.work_state_kind()
    }
    pub fn work_state(&self) -> Option<&crate::issue::WorkState> {
        self.header.work_state()
    }
    pub fn has_tags(&self, wanted: &[Tag]) -> bool {
        wanted.iter().all(|tag| self.tags().contains(tag))
    }
    pub fn tags(&self) -> &[Tag] {
        &self.header.tags
    }
    pub fn waits(&self) -> &[WaitRelation] {
        &self.header.waits
    }
    pub fn blocking(&self) -> &[IssueRelation] {
        &self.header.blocking
    }
}

struct Sections<'a> {
    statement_range: std::ops::Range<usize>,
    heading: &'a [u8],
    metadata: &'a [u8],
    statement: &'a [u8],
    work_log: Option<&'a [u8]>,
    evidence: &'a [u8],
    outcome: &'a [u8],
}

fn split_document(bytes: &[u8]) -> Result<Sections<'_>, RecordError> {
    let (heading, rest) = split_once(bytes, b"\n\n## Metadata\n\n")?;
    let (metadata, rest) = split_once(rest, b"\n\n## Statement\n\n")?;
    let start = bytes.len() - rest.len();
    let (body, rest) = split_once(rest, b"\n\n## Evidence\n\n")?;
    let (statement, work_log) = match find_bytes(body, b"\n\n## Work log\n\n") {
        Some(index) => (
            &body[..index],
            Some(&body[index + b"\n\n## Work log\n\n".len()..]),
        ),
        None => (body, None),
    };
    let (evidence, outcome) = split_once(rest, b"\n\n## Outcome\n\n")?;
    Ok(Sections {
        statement_range: start..start + statement.len(),
        heading,
        metadata,
        statement,
        work_log,
        evidence,
        outcome,
    })
}

fn split_once<'a>(bytes: &'a [u8], delimiter: &[u8]) -> Result<(&'a [u8], &'a [u8]), RecordError> {
    let index = find_bytes(bytes, delimiter).ok_or(RecordError::InvalidStructure)?;
    Ok((&bytes[..index], &bytes[index + delimiter.len()..]))
}

#[derive(Debug)]
struct ParsedHeader<'a> {
    title: &'a [u8],
    metadata: Metadata,
}

fn parse_header(bytes: &[u8], id: IssueId) -> Result<ParsedHeader<'_>, RecordError> {
    let (heading, metadata) = header_parts(bytes)?;
    Ok(ParsedHeader {
        title: parse_heading(heading, id)?,
        metadata: parse_metadata(metadata)?,
    })
}

fn header_parts(bytes: &[u8]) -> Result<(&[u8], &[u8]), RecordError> {
    let (heading, rest) = split_once(bytes, b"\n\n## Metadata\n\n")?;
    let end = find_bytes(rest, b"\n\n## Statement").unwrap_or_else(|| {
        rest.strip_suffix(b"\n")
            .map_or(rest.len(), |_| rest.len() - 1)
    });
    Ok((heading, &rest[..end]))
}

fn parse_heading(line: &[u8], id: IssueId) -> Result<&[u8], RecordError> {
    let prefix = format!("# {id} — ").into_bytes();
    line.strip_prefix(prefix.as_slice())
        .filter(|title| !title.is_empty() && !title.contains(&b'\n'))
        .ok_or(RecordError::InvalidHeading)
}

#[derive(Clone, Debug)]
struct Metadata {
    status: Status,
    kind: Name,
    created: CreatedDate,
    work_state: Option<crate::issue::WorkState>,
    tags: Vec<Tag>,
    waits: Vec<WaitRelation>,
    blocking: Vec<IssueRelation>,
}

impl Metadata {
    fn into_issue(self, id: IssueId, slug: Name, title: Vec<u8>) -> Issue {
        Issue {
            id,
            slug,
            title,
            status: self.status,
            kind: self.kind,
            created: self.created,
            work_state: self.work_state,
            tags: self.tags,
            waits: self.waits,
            blocking: self.blocking,
        }
    }
}

fn parse_metadata(bytes: &[u8]) -> Result<Metadata, RecordError> {
    let lines = bytes.split(|byte| *byte == b'\n').collect::<Vec<_>>();
    if lines.len() < 3 {
        return Err(RecordError::InvalidMetadata);
    }
    let status = Status::try_parse(required_field(lines[0], b"Status")?)
        .map_err(|_| RecordError::InvalidStatus)?;
    let kind = Name::try_parse(required_field(lines[1], b"Kind")?)
        .map_err(|_| RecordError::InvalidKind)?;
    let created = CreatedDate::try_parse(required_field(lines[2], b"Created")?)
        .map_err(|_| RecordError::InvalidCreated)?;
    let mut tags = Vec::new();
    let mut waits = Vec::new();
    let mut blocking = Vec::new();
    let mut index = 3;
    let work_state = work::parse_state(&lines, &mut index)?;
    if status == Status::Closed && work_state.is_some() {
        return Err(RecordError::InvalidWorkState);
    }
    if lines
        .get(index)
        .is_some_and(|line| line.starts_with(b"- **Tags:**"))
    {
        for value in required_field(lines[index], b"Tags")?.split(|byte| *byte == b',') {
            tags.push(
                Tag::try_parse(value.strip_prefix(b" ").unwrap_or(value))
                    .map_err(|_| RecordError::InvalidTag)?,
            );
        }
        index += 1;
    }
    if lines.get(index) == Some(&b"- **Waiting on:**".as_slice()) {
        index += 1;
        while lines
            .get(index)
            .is_some_and(|line| line.starts_with(b"  - #"))
        {
            let (target, title) = parse_relation(lines[index])?;
            let reason = WaitReason::parse(required_indented_field(
                lines.get(index + 1).ok_or(RecordError::InvalidWait)?,
                b"Reason",
            )?)
            .map_err(|_| RecordError::InvalidWait)?;
            waits.push(WaitRelation {
                target,
                title: title.to_vec(),
                reason: reason.as_bytes().to_vec(),
            });
            index += 2;
        }
        if waits.is_empty() {
            return Err(RecordError::InvalidWait);
        }
    }
    if lines.get(index) == Some(&b"- **Blocking:**".as_slice()) {
        index += 1;
        while let Some(line) = lines.get(index) {
            let (target, title) = parse_relation(line)?;
            blocking.push(IssueRelation {
                target,
                title: title.to_vec(),
            });
            index += 1;
        }
        if blocking.is_empty() {
            return Err(RecordError::InvalidBlocking);
        }
    }
    if index != lines.len() {
        return Err(RecordError::InvalidMetadata);
    }
    Ok(Metadata {
        status,
        kind,
        created,
        work_state,
        tags,
        waits,
        blocking,
    })
}

fn required_field<'a>(line: &'a [u8], name: &[u8]) -> Result<&'a [u8], RecordError> {
    let mut prefix = b"- **".to_vec();
    prefix.extend_from_slice(name);
    prefix.extend_from_slice(b":** ");
    line.strip_prefix(prefix.as_slice())
        .filter(|value| !value.is_empty())
        .ok_or(RecordError::InvalidMetadata)
}

fn required_indented_field<'a>(line: &'a [u8], name: &[u8]) -> Result<&'a [u8], RecordError> {
    let mut prefix = b"    - **".to_vec();
    prefix.extend_from_slice(name);
    prefix.extend_from_slice(b":** ");
    line.strip_prefix(prefix.as_slice())
        .filter(|value| !value.is_empty())
        .ok_or(RecordError::InvalidWait)
}

fn parse_relation(line: &[u8]) -> Result<(IssueId, &[u8]), RecordError> {
    let value = line
        .strip_prefix(b"  - #")
        .ok_or(RecordError::InvalidRelation)?;
    if value.len() < 9 || value.get(4..9) != Some(" — ".as_bytes()) {
        return Err(RecordError::InvalidRelation);
    }
    let target = CanonicalIssueId::parse(&value[..4])
        .map(CanonicalIssueId::issue_id)
        .map_err(|_| RecordError::InvalidRelation)?;
    let title = &value[9..];
    if title.is_empty() {
        return Err(RecordError::InvalidRelation);
    }
    Ok((target, title))
}

pub(crate) fn statement_range(bytes: &[u8]) -> Result<std::ops::Range<usize>, RecordError> {
    Ok(split_document(bytes)?.statement_range)
}

pub(crate) fn parse_statement(bytes: &[u8]) -> Result<&[u8], RecordError> {
    if bytes.is_empty()
        || bytes.starts_with(b"\n")
        || bytes.ends_with(b"\n")
        || bytes
            .split(|byte| *byte == b'\n')
            .any(|line| line.starts_with(b"## "))
    {
        return Err(RecordError::InvalidStatement);
    }
    Ok(bytes)
}

pub(crate) fn parse_evidence(bytes: &[u8]) -> Result<Vec<Vec<u8>>, RecordError> {
    let evidence = bytes
        .split(|byte| *byte == b'\n')
        .map(|line| {
            line.strip_prefix(b"- ")
                .filter(|entry| !entry.is_empty())
                .map(Vec::from)
                .ok_or(RecordError::InvalidEvidence)
        })
        .collect::<Result<Vec<_>, _>>()?;
    if evidence.is_empty()
        || (evidence.iter().any(|entry| entry == b"Pending.") && evidence.len() != 1)
    {
        Err(RecordError::InvalidEvidence)
    } else {
        Ok(evidence)
    }
}

pub(crate) fn parse_outcome(bytes: &[u8]) -> Result<&[u8], RecordError> {
    let value = bytes.strip_suffix(b"\n").unwrap_or(bytes);
    if value.is_empty()
        || value.windows(2).any(|part| part == b"\n\n")
        || value
            .split(|byte| *byte == b'\n')
            .any(|line| line.starts_with(b"## ") || line.is_empty())
    {
        Err(RecordError::InvalidOutcome)
    } else {
        Ok(value)
    }
}

pub(crate) fn validate_utf8(filename: &[u8], bytes: &[u8]) -> Result<(), RecordError> {
    std::str::from_utf8(filename).map_err(|_| RecordError::InvalidFilenameEncoding)?;
    std::str::from_utf8(bytes).map_err(|_| RecordError::InvalidContentEncoding)?;
    Ok(())
}

pub(crate) fn parse_filename(filename: &[u8]) -> Result<(IssueId, Name), RecordError> {
    if filename.len() < 9 || filename.get(4) != Some(&b'-') || !filename.ends_with(b".md") {
        return Err(RecordError::InvalidFilename);
    }
    let id = CanonicalIssueId::parse(&filename[..4])
        .map(CanonicalIssueId::issue_id)
        .map_err(|_| RecordError::InvalidFilename)?;
    let slug = Name::try_parse(&filename[5..filename.len() - 3])
        .map_err(|_| RecordError::InvalidFilename)?;
    Ok((id, slug))
}

fn find_bytes(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .position(|part| part == needle)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RecordError {
    InvalidFilenameEncoding,
    InvalidContentEncoding,
    InvalidFilename,
    InvalidHeading,
    InvalidStructure,
    InvalidMetadata,
    InvalidStatus,
    InvalidKind,
    InvalidCreated,
    InvalidTag,
    InvalidWorkState,
    InvalidWorkLog,
    InvalidWait,
    InvalidBlocking,
    InvalidRelation,
    InvalidStatement,
    InvalidEvidence,
    InvalidOutcome,
}

impl fmt::Display for RecordError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let message = match self {
            Self::InvalidFilenameEncoding => "issue filename is not valid UTF-8",
            Self::InvalidContentEncoding => "issue record is not valid UTF-8",
            Self::InvalidFilename => "invalid issue filename",
            Self::InvalidHeading => "invalid issue title heading",
            Self::InvalidStructure => "invalid or out-of-order record sections",
            Self::InvalidMetadata => "invalid or out-of-order metadata",
            Self::InvalidStatus => "invalid Status field",
            Self::InvalidKind => "invalid Kind field",
            Self::InvalidCreated => "invalid Created field",
            Self::InvalidWorkState => "invalid Work state metadata",
            Self::InvalidWorkLog => {
                "invalid Work log (check UTC times, span order and running clock state)"
            }
            Self::InvalidTag => "invalid Tags field",
            Self::InvalidWait => "invalid wait relation",
            Self::InvalidBlocking => "invalid blocking relation",
            Self::InvalidRelation => "invalid copied issue relation",
            Self::InvalidStatement => "invalid Statement section",
            Self::InvalidEvidence => "invalid Evidence section",
            Self::InvalidOutcome => "invalid Outcome section",
        };
        write!(formatter, "{message}")
    }
}
impl Error for RecordError {}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    pub(crate) const RECORD: &[u8] = b"# 0001 \xe2\x80\x94 Example\n\n## Metadata\n\n- **Status:** open\n- **Kind:** feature\n- **Created:** 2026-09-02\n- **Tags:** rust, frontend\n- **Waiting on:**\n  - #0002 \xe2\x80\x94 Foundation\n    - **Reason:** Needed first.\n- **Blocking:**\n  - #0003 \xe2\x80\x94 Consumer\n\n## Statement\n\nStatement with caf\xc3\xa9.\n\n### Detail\n\nMore prose.\n\n## Evidence\n\n- Pending.\n\n## Outcome\n\nPending.\n";
    #[test]
    fn parses_and_renders_the_canonical_document() {
        let parsed = RecordDocument::parse(b"0001-example.md", RECORD).unwrap();
        assert_eq!(parsed.issue.waits[0].title, b"Foundation");
        assert_eq!(parsed.issue.blocking[0].target.get(), 3);
        assert_eq!(parsed.render(), RECORD);
    }
    #[test]
    fn metadata_only_view_reads_the_prefix() {
        let end = find_bytes(RECORD, b"\n\n## Statement").unwrap() + 1;
        let view = RecordView::new(b"0001-example.md", &RECORD[..end]).unwrap();
        assert_eq!(view.title(), b"Example");
        assert_eq!(view.waits()[0].target.get(), 2);
    }
    #[test]
    fn rejects_the_legacy_layout() {
        let old =
            b"# 0001 \xe2\x80\x94 Example\n\nStatus: open\nKind: feature\nCreated: 2026-09-02\n";
        assert_eq!(
            IssueRecord::parse(b"0001-example.md", old.to_vec()),
            Err(RecordError::InvalidStructure)
        );
    }

    #[test]
    fn accepts_a_wrapped_outcome_paragraph() {
        let wrapped = RECORD
            .strip_suffix(b"Pending.\n")
            .unwrap()
            .iter()
            .copied()
            .chain(b"First line\ncontinues here.\n".iter().copied())
            .collect::<Vec<_>>();
        let parsed = RecordDocument::parse(b"0001-example.md", &wrapped).unwrap();
        assert_eq!(parsed.outcome, b"First line\ncontinues here.");
        assert_eq!(parsed.render(), wrapped);
    }
}
