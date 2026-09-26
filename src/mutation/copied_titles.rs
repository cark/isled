//! Byte-preserving correction of copied relation titles.
use super::{MutationError, MutationPlan, Replacement};
use crate::{filesystem::StoredRecord, issue::IssueId};
use std::collections::BTreeMap;

pub fn repair_copied_titles<'a, Records>(records: Records) -> Result<MutationPlan, MutationError>
where
    Records: IntoIterator<Item = &'a StoredRecord>,
    Records::IntoIter: Clone,
{
    let records = records.into_iter();
    // Validate every record in input order before producing any replacements.
    let titles = collect_titles(records.clone())?;
    let replacements = records
        .filter_map(|record| rewrite_relation_titles(record, &titles))
        .collect();
    Ok(MutationPlan { replacements })
}

fn collect_titles<'a>(
    records: impl IntoIterator<Item = &'a StoredRecord>,
) -> Result<BTreeMap<IssueId, &'a [u8]>, MutationError> {
    let mut titles = BTreeMap::new();
    for record in records {
        let doc = record.document().map_err(MutationError::Record)?;
        if titles
            .insert(doc.issue.id, doc.issue.title.as_slice())
            .is_some()
        {
            return Err(MutationError::DuplicateId(doc.issue.id));
        }
    }
    Ok(titles)
}

fn rewrite_relation_titles(
    record: &StoredRecord,
    titles: &BTreeMap<IssueId, &[u8]>,
) -> Option<Replacement> {
    let text = std::str::from_utf8(record.bytes()).expect("validated record");
    let rewritten = rewrite_metadata(text, titles)?;
    let mut document = record.document().expect("eagerly validated record").clone();
    update_titles(
        document
            .issue
            .waits
            .iter_mut()
            .map(|relation| (relation.target, &mut relation.title)),
        titles,
    );
    update_titles(
        document
            .issue
            .blocking
            .iter_mut()
            .map(|relation| (relation.target, &mut relation.title)),
        titles,
    );
    Some(Replacement::corrected(
        record.filename().to_vec(),
        rewritten.into_bytes(),
        document,
    ))
}

fn update_titles<'a>(
    relations: impl Iterator<Item = (IssueId, &'a mut Vec<u8>)>,
    titles: &BTreeMap<IssueId, &[u8]>,
) {
    for (target, copied_title) in relations {
        if let Some(title) = titles.get(&target) {
            copied_title.clear();
            copied_title.extend_from_slice(title);
        }
    }
}

fn rewrite_metadata(text: &str, titles: &BTreeMap<IssueId, &[u8]>) -> Option<String> {
    let mut output = None;
    let mut offset = 0;
    let mut copied_until = 0;
    for line in text
        .split_inclusive('\n')
        .take_while(|line| !line.starts_with("## Statement"))
    {
        if let Some((prefix, copied_title, title)) = relation_title(line, titles)
            && copied_title.strip_suffix('\n') != Some(title)
        {
            let output = output.get_or_insert_with(|| String::with_capacity(text.len()));
            output.push_str(&text[copied_until..offset]);
            output.push_str(prefix);
            output.push_str(title);
            output.push('\n');
            copied_until = offset + line.len();
        }
        offset += line.len();
    }
    let mut output = output?;
    output.push_str(&text[copied_until..]);
    Some(output)
}

fn relation_title<'a>(
    line: &'a str,
    titles: &'a BTreeMap<IssueId, &[u8]>,
) -> Option<(&'a str, &'a str, &'a str)> {
    let (id, copied_title) = line.strip_prefix("  - #")?.split_once(" — ")?;
    let title = titles.get(&id.parse::<IssueId>().ok()?)?;
    // Eager record validation establishes canonical ID spelling and UTF-8.
    let prefix = &line[..line.len() - copied_title.len()];
    Some((
        prefix,
        copied_title,
        std::str::from_utf8(title).expect("validated title"),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record(id: u16, title: &str, relations: &str) -> StoredRecord {
        StoredRecord::new(
            format!("{id:04}-issue.md").into_bytes(),
            format!(
                "# {id:04} — {title}\n\n## Metadata\n\n- **Status:** open\n- **Kind:** task\n- **Created:** 2026-09-05\n{relations}\n## Statement\n\n  - #0002 — Prose copy stays.\n\n## Evidence\n\n- Observed.\n\n## Outcome\n\nPending.\n"
            ).into_bytes(),
        ).unwrap()
    }

    #[test]
    fn repairs_only_known_metadata_titles_in_input_order() {
        let records = [
            record(2, "Deux — été", "- **Blocking:**\n  - #0001 — Old first\n"),
            record(
                1,
                "First",
                "- **Waiting on:**\n  - #0002 — Old second\n    - **Reason:** Preserve  spacing.\n  - #0003 — Missing target\n    - **Reason:** Keep missing relation.\n",
            ),
        ];
        let plan = repair_copied_titles(&records).unwrap();
        assert_eq!(plan.replacements().len(), 2);
        for (replacement, original) in plan.replacements().iter().zip(&records) {
            assert_eq!(replacement.filename(), original.filename());
            let expected = std::str::from_utf8(original.bytes())
                .unwrap()
                .replace("#0001 — Old first", "#0001 — First")
                .replace("#0002 — Old second", "#0002 — Deux — été");
            assert_eq!(replacement.bytes(), expected.as_bytes());
            assert_eq!(
                replacement.record().document().unwrap(),
                &crate::record::RecordDocument::parse(replacement.filename(), replacement.bytes())
                    .unwrap()
            );
        }
        let repaired = plan
            .replacements()
            .iter()
            .map(|replacement| {
                StoredRecord::new(
                    replacement.filename().to_vec(),
                    replacement.bytes().to_vec(),
                )
                .unwrap()
            })
            .collect::<Vec<_>>();
        assert!(
            repair_copied_titles(&repaired)
                .unwrap()
                .replacements()
                .is_empty()
        );
        assert!(repair_copied_titles(&[]).unwrap().replacements().is_empty());
    }

    #[test]
    fn preserves_gaps_and_unterminated_prose_between_title_edits() {
        let original = record(
            1,
            "First",
            "- **Waiting on:**\n  - #0002 — Old two\n    - **Reason:** Keep café.\n  - #0004 — Four\n    - **Reason:** Already correct.\n  - #0003 — Old three\n    - **Reason:** Keep this too.\n",
        );
        let mut bytes = original.bytes().to_vec();
        bytes.pop();
        let original = StoredRecord::new(original.filename().to_vec(), bytes).unwrap();
        let records = [
            original,
            record(2, "Two", ""),
            record(3, "Three", ""),
            record(4, "Four", ""),
        ];
        let plan = repair_copied_titles(&records).unwrap();
        let expected = std::str::from_utf8(records[0].bytes())
            .unwrap()
            .replace("#0002 — Old two", "#0002 — Two")
            .replace("#0003 — Old three", "#0003 — Three");
        assert_eq!(plan.replacements().len(), 1);
        assert_eq!(plan.replacements()[0].bytes(), expected.as_bytes());
    }

    #[test]
    fn validates_all_records_and_preserves_first_error() {
        let valid = record(1, "First", "");
        let malformed =
            StoredRecord::new(b"0002-issue.md".to_vec(), b"malformed".to_vec()).unwrap();
        assert!(matches!(
            repair_copied_titles(&[valid.clone(), malformed.clone()]),
            Err(MutationError::Record(_))
        ));
        assert!(matches!(
            repair_copied_titles(&[valid.clone(), valid.clone(), malformed.clone()]),
            Err(MutationError::DuplicateId(id)) if id == IssueId::new(1).unwrap()
        ));
        assert!(matches!(
            repair_copied_titles(&[valid.clone(), malformed, valid]),
            Err(MutationError::Record(_))
        ));
    }
}
