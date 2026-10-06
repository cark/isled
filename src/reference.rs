//! Pure recognition of issue-reference occurrences in structured records.

use crate::issue::IssueId;
use std::collections::BTreeSet;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ReferenceField {
    WaitingOn,
    Blocking,
    Statement,
    Evidence,
    Outcome,
}

impl ReferenceField {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::WaitingOn => "waiting_on",
            Self::Blocking => "blocking",
            Self::Statement => "statement",
            Self::Evidence => "evidence",
            Self::Outcome => "outcome",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ReferenceResolution {
    Resolved,
    Missing,
}

impl ReferenceResolution {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Resolved => "resolved",
            Self::Missing => "missing",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct InlineIssueReference {
    field: ReferenceField,
    entry: usize,
    authored: String,
    target: IssueId,
    resolution: ReferenceResolution,
    byte_start: usize,
    byte_length: usize,
    character_start: usize,
    character_length: usize,
}

impl InlineIssueReference {
    pub fn field(&self) -> ReferenceField {
        self.field
    }

    pub fn entry(&self) -> usize {
        self.entry
    }

    pub fn authored(&self) -> &str {
        &self.authored
    }

    pub fn target(&self) -> IssueId {
        self.target
    }

    pub fn resolution(&self) -> ReferenceResolution {
        self.resolution
    }

    pub(crate) fn resolve(&mut self, present: bool) {
        self.resolution = if present {
            ReferenceResolution::Resolved
        } else {
            ReferenceResolution::Missing
        };
    }

    pub fn byte_start(&self) -> usize {
        self.byte_start
    }

    pub fn byte_length(&self) -> usize {
        self.byte_length
    }

    pub fn character_start(&self) -> usize {
        self.character_start
    }

    pub fn character_length(&self) -> usize {
        self.character_length
    }
}

#[derive(Clone, Copy)]
enum Region {
    Header,
    Relation(ReferenceField),
    Prose(ReferenceField),
}

#[derive(Default)]
struct MarkdownState {
    fence: Option<(u8, usize)>,
    code_span: Option<usize>,
}

struct ProseLine<'a> {
    content: &'a str,
    text: &'a str,
    byte_start: usize,
    character_start: usize,
    field: ReferenceField,
    entry: usize,
}

pub fn recognize_issue_references(
    content: &str,
    known_targets: &BTreeSet<IssueId>,
) -> Vec<InlineIssueReference> {
    let mut references = Vec::new();
    let mut region = Region::Header;
    let mut entries = [0_usize; 5];
    let mut markdown = MarkdownState::default();
    let mut byte_start = 0;
    let mut character_start = 0;

    for (line_number, line_with_ending) in content.split_inclusive('\n').enumerate() {
        let line = line_with_ending
            .strip_suffix('\n')
            .unwrap_or(line_with_ending);
        if line_number == 0 {
            advance_line_offsets(line_with_ending, &mut byte_start, &mut character_start);
            continue;
        }

        region = next_region(region, line);
        match region {
            Region::Relation(field) => {
                let entry = entries[field_index(field)];
                if recognize_relation_line(
                    ProseLine {
                        content,
                        text: line,
                        byte_start,
                        character_start,
                        field,
                        entry,
                    },
                    known_targets,
                    &mut references,
                ) {
                    entries[field_index(field)] += 1;
                }
            }
            Region::Prose(field) if !line.is_empty() && !is_section_heading(line) => {
                let entry = entries[field_index(field)];
                recognize_line(
                    ProseLine {
                        content,
                        text: line,
                        byte_start,
                        character_start,
                        field,
                        entry,
                    },
                    known_targets,
                    &mut markdown,
                    &mut references,
                );
                entries[field_index(field)] += 1;
            }
            Region::Header | Region::Prose(_) => {}
        }
        advance_line_offsets(line_with_ending, &mut byte_start, &mut character_start);
    }
    references
}

fn next_region(region: Region, line: &str) -> Region {
    match region {
        Region::Header if line == "- **Waiting on:**" => {
            Region::Relation(ReferenceField::WaitingOn)
        }
        Region::Header | Region::Relation(_) if line == "- **Blocking:**" => {
            Region::Relation(ReferenceField::Blocking)
        }
        Region::Header | Region::Relation(_) if line == "## Statement" => {
            Region::Prose(ReferenceField::Statement)
        }
        Region::Prose(_) if line == "## Work log" => Region::Header,
        Region::Header if line == "## Evidence" => Region::Prose(ReferenceField::Evidence),
        Region::Prose(_) if line == "## Evidence" => Region::Prose(ReferenceField::Evidence),
        Region::Prose(_) if line == "## Outcome" => Region::Prose(ReferenceField::Outcome),
        _ => region,
    }
}

fn is_section_heading(line: &str) -> bool {
    matches!(
        line,
        "## Statement" | "## Work log" | "## Evidence" | "## Outcome"
    )
}

fn field_index(field: ReferenceField) -> usize {
    match field {
        ReferenceField::WaitingOn => 0,
        ReferenceField::Blocking => 1,
        ReferenceField::Statement => 2,
        ReferenceField::Evidence => 3,
        ReferenceField::Outcome => 4,
    }
}

fn recognize_relation_line(
    line: ProseLine<'_>,
    known_targets: &BTreeSet<IssueId>,
    references: &mut Vec<InlineIssueReference>,
) -> bool {
    let Some(rest) = line.text.strip_prefix("  - ") else {
        return false;
    };
    let Some((authored, _title)) = rest.split_once(" — ") else {
        return false;
    };
    if authored.len() != 5 || !authored.starts_with('#') {
        return false;
    }
    let Ok(target) = authored.parse::<IssueId>() else {
        return false;
    };
    push_reference(&line, 4, authored, target, known_targets, references);
    true
}

fn recognize_line(
    line: ProseLine<'_>,
    known_targets: &BTreeSet<IssueId>,
    markdown: &mut MarkdownState,
    references: &mut Vec<InlineIssueReference>,
) {
    if update_fence(line.text, markdown) {
        return;
    }

    let bytes = line.text.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'`' {
            let run = repeated_byte_count(bytes, index, b'`');
            match markdown.code_span {
                Some(opening) if run == opening => markdown.code_span = None,
                None if has_closing_code_span(line.content, line.byte_start + index + run, run) => {
                    markdown.code_span = Some(run)
                }
                _ => {}
            }
            index += run;
            continue;
        }
        if markdown.code_span.is_some() {
            index += utf8_character_width(line.text, index);
            continue;
        }
        if bytes[index] == b'['
            && let Some(end) = markdown_link_end(bytes, index)
        {
            index = end;
            continue;
        }
        if bytes[index] != b'#'
            || is_escaped(bytes, index)
            || embedded_before(line.text, index)
            || inside_url(bytes, index)
        {
            index += utf8_character_width(line.text, index);
            continue;
        }

        let digits_end = bytes[index + 1..]
            .iter()
            .take_while(|byte| byte.is_ascii_digit())
            .count()
            + index
            + 1;
        let digits = digits_end - index - 1;
        if digits == 0
            || digits > 4
            || bytes.get(digits_end).is_some_and(u8::is_ascii_digit)
            || embedded_after(line.text, digits_end)
        {
            index += 1;
            continue;
        }
        let authored = &line.text[index..digits_end];
        let Ok(target) = authored.parse::<IssueId>() else {
            index = digits_end;
            continue;
        };
        push_reference(&line, index, authored, target, known_targets, references);
        index = digits_end;
    }
}

fn push_reference(
    line: &ProseLine<'_>,
    index: usize,
    authored: &str,
    target: IssueId,
    known_targets: &BTreeSet<IssueId>,
    references: &mut Vec<InlineIssueReference>,
) {
    let absolute_byte_start = line.byte_start + index;
    references.push(InlineIssueReference {
        field: line.field,
        entry: line.entry,
        authored: authored.to_owned(),
        target,
        resolution: if known_targets.contains(&target) {
            ReferenceResolution::Resolved
        } else {
            ReferenceResolution::Missing
        },
        byte_start: absolute_byte_start,
        byte_length: authored.len(),
        character_start: line.character_start + line.text[..index].chars().count(),
        character_length: authored.chars().count(),
    });
    debug_assert_eq!(
        &line.content[absolute_byte_start..absolute_byte_start + authored.len()],
        authored
    );
}

fn has_closing_code_span(content: &str, start: usize, length: usize) -> bool {
    let bytes = content.as_bytes();
    let mut index = start;
    while index < bytes.len() {
        if bytes[index] != b'`' {
            index += utf8_character_width(content, index);
            continue;
        }
        let run = repeated_byte_count(bytes, index, b'`');
        if run == length {
            return true;
        }
        index += run;
    }
    false
}

fn update_fence(line: &str, markdown: &mut MarkdownState) -> bool {
    let Some((marker, length)) = fence_marker(line) else {
        return markdown.fence.is_some();
    };
    match markdown.fence {
        Some((opening, opening_length)) if marker == opening && length >= opening_length => {
            markdown.fence = None;
        }
        None => markdown.fence = Some((marker, length)),
        _ => {}
    }
    true
}

fn fence_marker(line: &str) -> Option<(u8, usize)> {
    let bytes = line.as_bytes();
    let indentation = bytes.iter().take_while(|byte| **byte == b' ').count();
    if indentation > 3 {
        return None;
    }
    let marker = *bytes.get(indentation)?;
    if !matches!(marker, b'`' | b'~') {
        return None;
    }
    let length = repeated_byte_count(bytes, indentation, marker);
    (length >= 3).then_some((marker, length))
}

fn markdown_link_end(bytes: &[u8], start: usize) -> Option<usize> {
    let label_end = matching_delimiter(bytes, start, b'[', b']')?;
    match bytes.get(label_end) {
        Some(b'(') => matching_delimiter(bytes, label_end, b'(', b')'),
        Some(b'[') => matching_delimiter(bytes, label_end, b'[', b']'),
        _ => None,
    }
}

fn matching_delimiter(bytes: &[u8], start: usize, open: u8, close: u8) -> Option<usize> {
    let mut depth = 0_usize;
    let mut index = start;
    while index < bytes.len() {
        if is_escaped(bytes, index) {
            index += 1;
            continue;
        }
        if bytes[index] == open {
            depth += 1;
        } else if bytes[index] == close {
            depth -= 1;
            if depth == 0 {
                return Some(index + 1);
            }
        }
        index += 1;
    }
    None
}

fn is_escaped(bytes: &[u8], index: usize) -> bool {
    bytes[..index]
        .iter()
        .rev()
        .take_while(|byte| **byte == b'\\')
        .count()
        % 2
        == 1
}

fn embedded_before(line: &str, index: usize) -> bool {
    line[..index]
        .chars()
        .next_back()
        .is_some_and(token_character)
}

fn embedded_after(line: &str, index: usize) -> bool {
    line[index..].chars().next().is_some_and(token_character)
}

fn token_character(character: char) -> bool {
    character.is_alphanumeric() || matches!(character, '_' | '-')
}

fn inside_url(bytes: &[u8], index: usize) -> bool {
    let start = bytes[..index]
        .iter()
        .rposition(u8::is_ascii_whitespace)
        .map_or(0, |position| position + 1);
    let prefix = &bytes[start..index];
    prefix.windows(3).any(|window| window == b"://")
        || prefix.starts_with(b"www.")
        || (prefix.contains(&b'.') && prefix.contains(&b'/'))
}

fn repeated_byte_count(bytes: &[u8], start: usize, wanted: u8) -> usize {
    bytes[start..]
        .iter()
        .take_while(|byte| **byte == wanted)
        .count()
}

fn utf8_character_width(value: &str, index: usize) -> usize {
    value[index..]
        .chars()
        .next()
        .expect("index is within UTF-8 text")
        .len_utf8()
}

fn advance_line_offsets(line: &str, byte_start: &mut usize, character_start: &mut usize) {
    *byte_start += line.len();
    *character_start += line.chars().count();
}

#[cfg(test)]
mod tests {
    use super::*;

    fn id(value: u16) -> IssueId {
        IssueId::new(value).expect("valid test ID")
    }

    fn known(values: &[u16]) -> BTreeSet<IssueId> {
        values.iter().copied().map(id).collect()
    }

    #[test]
    fn recognizes_aliases_with_absolute_byte_and_character_offsets() {
        let content = "# 0001 — Title #9\n\n## Metadata\n\n- **Status:** open\n- **Kind:** feature\n- **Created:** 2026-09-03\n\n## Statement\n\nCafé #2 then #0002 and #3.\n\n## Evidence\n\n- Saw #2.\n\n## Outcome\n\nUse #0042.\n";

        let references = recognize_issue_references(content, &known(&[2, 42]));

        assert_eq!(references.len(), 5);
        assert_eq!(references[0].field(), ReferenceField::Statement);
        assert_eq!(references[0].entry(), 0);
        assert_eq!(references[0].authored(), "#2");
        assert_eq!(references[0].target(), id(2));
        assert_eq!(references[0].resolution(), ReferenceResolution::Resolved);
        assert_eq!(references[1].authored(), "#0002");
        assert_eq!(references[2].resolution(), ReferenceResolution::Missing);
        assert_eq!(references[3].field(), ReferenceField::Evidence);
        assert_eq!(references[3].entry(), 0);
        assert_eq!(references[4].field(), ReferenceField::Outcome);
        for reference in references {
            let bytes = reference.byte_start()..reference.byte_start() + reference.byte_length();
            let characters = reference.character_start()
                ..reference.character_start() + reference.character_length();
            assert_eq!(&content[bytes], reference.authored());
            assert_eq!(
                content
                    .chars()
                    .skip(characters.start)
                    .take(characters.len())
                    .collect::<String>(),
                reference.authored()
            );
        }
    }

    #[test]
    fn ignores_invalid_embedded_escaped_linked_url_and_code_forms() {
        let content = r#"# 0001 — Title

## Metadata

- **Status:** open
- **Kind:** feature
- **Created:** 2026-09-03

## Statement

#0 #0000 #00000 word#2 #2word before-#2-after \#2
`#2` ``code #2`` and [label #2](https://example.test/#2)
[label][#2] https://example.test/path?target=#2 www.example.test/#2
```text
#2
```
~~~
#2
~~~
Visible #2.

## Evidence

- Pending.

## Outcome

Pending.
"#;

        let references = recognize_issue_references(content, &known(&[2]));

        assert_eq!(references.len(), 1);
        assert_eq!(references[0].authored(), "#2");
        assert_eq!(references[0].field(), ReferenceField::Statement);
    }

    #[test]
    fn retains_duplicate_occurrences_and_indexes_nonempty_field_lines() {
        let content = "# 0001 — Title\n\n## Metadata\n\n- **Status:** open\n- **Kind:** feature\n- **Created:** 2026-09-03\n\n## Statement\n\nFirst #2.\n\nSecond #2 and #2.\n\n## Evidence\n\n- First entry.\n- Second #2.\n\n## Outcome\n\nChosen #2.\n";

        let references = recognize_issue_references(content, &known(&[2]));

        assert_eq!(references.len(), 5);
        assert_eq!(references[0].entry(), 0);
        assert_eq!(references[1].entry(), 1);
        assert_eq!(references[2].entry(), 1);
        assert_eq!(references[3].field(), ReferenceField::Evidence);
        assert_eq!(references[3].entry(), 1);
        assert_eq!(references[4].field(), ReferenceField::Outcome);
        assert_eq!(references[4].entry(), 0);
    }

    #[test]
    fn recognizes_only_structured_relation_targets_in_metadata() {
        let content = "# 0001 — Café #9\n\n## Metadata\n\n- **Status:** open\n- **Kind:** feature\n- **Created:** 2026-09-03\n- **Waiting on:**\n  - #0002 — Blocker #4\n    - **Reason:** Need #5 first.\n- **Blocking:**\n  - #0003 — Consumer\n\n## Statement\n\nBody.\n\n## Evidence\n\n- Pending.\n\n## Outcome\n\nPending.\n";

        let references = recognize_issue_references(content, &known(&[2, 3, 4, 5, 9]));

        assert_eq!(references.len(), 2);
        assert_eq!(references[0].field(), ReferenceField::WaitingOn);
        assert_eq!(references[0].entry(), 0);
        assert_eq!(references[0].authored(), "#0002");
        assert_eq!(references[0].target(), id(2));
        assert_eq!(references[1].field(), ReferenceField::Blocking);
        assert_eq!(references[1].entry(), 0);
        assert_eq!(references[1].authored(), "#0003");
        for reference in references {
            let bytes = reference.byte_start()..reference.byte_start() + reference.byte_length();
            let characters = reference.character_start()
                ..reference.character_start() + reference.character_length();
            assert_eq!(&content[bytes], reference.authored());
            assert_eq!(
                content
                    .chars()
                    .skip(characters.start)
                    .take(characters.len())
                    .collect::<String>(),
                reference.authored()
            );
        }
    }
}
