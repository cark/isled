use crate::issue::{CreatedDate, Issue, IssueId, Name, Status, Tag};
use crate::record::RecordDocument;

use super::{AddStatementText, Replacement, TitleText};

pub fn add_record_validated(
    id: IssueId,
    slug: &Name,
    kind: &Name,
    title: &TitleText,
    statement: &AddStatementText,
    created: &CreatedDate,
    tags: &[Tag],
) -> Replacement {
    let filename = format!("{id}-{slug}.md").into_bytes();
    let document = RecordDocument {
        work_log: crate::work_log::WorkLog::default(),
        work_log_source: None,
        issue: Issue {
            id,
            slug: slug.clone(),
            title: title.as_bytes().to_vec(),
            status: Status::Open,
            kind: kind.clone(),
            created: created.clone(),
            work_state: None,
            tags: tags.to_vec(),
            waits: Vec::new(),
            blocking: Vec::new(),
        },
        statement: statement.as_bytes().to_vec(),
        evidence: vec![b"Pending.".to_vec()],
        outcome: b"Pending.".to_vec(),
    };
    Replacement::rendered(filename, document)
}

pub fn derive_slug(title: &str) -> Name {
    let mut slug = Vec::new();
    let mut pending_hyphen = false;
    for mut byte in title.bytes() {
        if byte.is_ascii_uppercase() {
            byte = byte.to_ascii_lowercase();
        }
        if byte.is_ascii_lowercase() || byte.is_ascii_digit() {
            if pending_hyphen && !slug.is_empty() {
                slug.push(b'-');
            }
            pending_hyphen = false;
            slug.push(byte);
        } else {
            pending_hyphen = true;
        }
    }
    Name::parse(&slug).unwrap_or_else(|| Name::parse(b"issue").expect("static valid name"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slug_derivation_matches_ascii_bash_rule() {
        assert_eq!(derive_slug("  Café & HTTP 2 ").as_str(), "caf-http-2");
        assert_eq!(derive_slug("世界").as_str(), "issue");
    }

    #[test]
    fn creation_uses_the_structured_layout() {
        let id = IssueId::new(1).unwrap();
        let slug = Name::parse(b"example").unwrap();
        let kind = Name::parse(b"feature").unwrap();
        let title = TitleText::parse("A").unwrap();
        let record = add_record_validated(
            id,
            &slug,
            &kind,
            &title,
            &AddStatementText::parse("Body café").unwrap(),
            &CreatedDate::try_parse(b"2026-09-02").unwrap(),
            &[],
        );
        assert!(
            record
                .bytes()
                .starts_with(b"# 0001 \xe2\x80\x94 A\n\n## Metadata\n")
        );
        assert!(record.bytes().ends_with(b"## Outcome\n\nPending.\n"));
    }
}
