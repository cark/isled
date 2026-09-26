use crate::filesystem::{StoreEntry, StoreSnapshot};
use crate::issue::{Issue, IssueId, Status};
use crate::ledger::HighWater;
use crate::record::RecordDocument;
use crate::wait_graph::{self, Adjacency};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Finding {
    locator: Vec<u8>,
    invariant: &'static str,
    detail: Vec<u8>,
    order: usize,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CheckReport {
    findings: Vec<Finding>,
}

impl CheckReport {
    pub fn has_findings(&self) -> bool {
        !self.findings.is_empty()
    }
    pub fn render(&self) -> Vec<u8> {
        let mut output = Vec::new();
        for finding in &self.findings {
            output.extend_from_slice(&escape_locator(&finding.locator));
            output.push(b'\t');
            output.extend_from_slice(finding.invariant.as_bytes());
            output.push(b'\t');
            output.extend_from_slice(&finding.detail);
            output.push(b'\n');
        }
        output
    }
}

struct ParsedRecord<'a> {
    entry: &'a StoreEntry,
    issue: Issue,
    order: usize,
}

pub fn audit(snapshot: &StoreSnapshot) -> CheckReport {
    let mut names = snapshot
        .entries
        .iter()
        .map(StoreEntry::filename)
        .chain([b".next-id".as_slice()])
        .collect::<Vec<_>>();
    names.sort();
    let order = names
        .into_iter()
        .enumerate()
        .map(|(index, name)| (name, index))
        .collect::<BTreeMap<_, _>>();
    let mut findings = Vec::new();
    let mut parsed = Vec::new();
    for entry in &snapshot.entries {
        let entry_order = order[entry.filename()];
        if !entry.filename_is_utf8() {
            add_finding(
                &mut findings,
                entry,
                entry_order,
                "FILENAME_UTF8",
                b"issue filename is not valid UTF-8",
            );
        }
        if std::str::from_utf8(entry.bytes()).is_err() {
            add_finding(
                &mut findings,
                entry,
                entry_order,
                "CONTENT_UTF8",
                b"issue record is not valid UTF-8",
            );
        }
        match RecordDocument::parse(entry.filename(), entry.bytes()) {
            Ok(record) => parsed.push(ParsedRecord {
                entry,
                issue: record.issue,
                order: entry_order,
            }),
            Err(error) => add_finding(
                &mut findings,
                entry,
                entry_order,
                "RECORD_FORMAT",
                error.to_string().as_bytes(),
            ),
        }
    }
    audit_duplicates(&parsed, &mut findings);
    audit_records(&parsed, &mut findings);
    audit_relations(&parsed, &mut findings);
    audit_high_water(
        snapshot,
        order[b".next-id".as_slice()],
        &parsed,
        &mut findings,
    );
    findings.sort_by(|left, right| {
        (left.order, left.invariant, &left.detail).cmp(&(
            right.order,
            right.invariant,
            &right.detail,
        ))
    });
    CheckReport { findings }
}

fn audit_duplicates(parsed: &[ParsedRecord<'_>], findings: &mut Vec<Finding>) {
    let mut ids = BTreeMap::<IssueId, Vec<&ParsedRecord<'_>>>::new();
    for record in parsed {
        ids.entry(record.issue.id).or_default().push(record);
    }
    for (id, records) in ids {
        if records.len() > 1 {
            for record in records {
                add_finding(
                    findings,
                    record.entry,
                    record.order,
                    "DUPLICATE_ID",
                    format!("duplicate issue ID {id}").as_bytes(),
                );
            }
        }
    }
}

fn audit_records(parsed: &[ParsedRecord<'_>], findings: &mut Vec<Finding>) {
    for record in parsed {
        if record.issue.status == Status::Closed {
            if record.issue.tags.iter().any(|tag| tag.is_priority()) {
                add_finding(
                    findings,
                    record.entry,
                    record.order,
                    "CLOSED_PRIORITY",
                    b"closed issue retains a priority tag",
                );
            }
            if record
                .entry
                .bytes()
                .windows(b"## Evidence\n\n- Pending.".len())
                .any(|part| part == b"## Evidence\n\n- Pending.")
            {
                add_finding(
                    findings,
                    record.entry,
                    record.order,
                    "EVIDENCE_PENDING",
                    b"closed issue retains pending evidence",
                );
            }
            if record.entry.bytes().ends_with(b"## Outcome\n\nPending.\n") {
                add_finding(
                    findings,
                    record.entry,
                    record.order,
                    "OUTCOME_PENDING",
                    b"closed issue retains pending outcome",
                );
            }
        }
    }
}

fn audit_relations(parsed: &[ParsedRecord<'_>], findings: &mut Vec<Finding>) {
    let by_id = parsed
        .iter()
        .map(|record| (record.issue.id, record))
        .collect::<BTreeMap<_, _>>();
    let mut graph = Adjacency::new();
    for record in parsed {
        graph.entry(record.issue.id).or_default();
    }
    for record in parsed {
        let mut waits = BTreeSet::new();
        for relation in &record.issue.waits {
            if !waits.insert(relation.target) {
                add_finding(
                    findings,
                    record.entry,
                    record.order,
                    "RELATION_DUPLICATE",
                    format!("duplicate wait on {}", relation.target).as_bytes(),
                );
                continue;
            }
            let Some(target) = by_id.get(&relation.target) else {
                add_finding(
                    findings,
                    record.entry,
                    record.order,
                    "WAIT_MISSING_TARGET",
                    format!("wait target {} does not exist", relation.target).as_bytes(),
                );
                continue;
            };
            if relation.title != target.issue.title {
                add_finding(
                    findings,
                    record.entry,
                    record.order,
                    "RELATION_TITLE",
                    format!("copied title for {} is stale", relation.target).as_bytes(),
                );
            }
            if !target
                .issue
                .blocking
                .iter()
                .any(|reverse| reverse.target == record.issue.id)
            {
                add_finding(
                    findings,
                    record.entry,
                    record.order,
                    "RELATION_RECIPROCAL",
                    format!(
                        "wait on {} has no reciprocal blocking entry",
                        relation.target
                    )
                    .as_bytes(),
                );
            }
            if record.issue.status == Status::Open && target.issue.status == Status::Open {
                graph
                    .entry(record.issue.id)
                    .or_default()
                    .insert(relation.target);
            }
        }
        let mut blocking = BTreeSet::new();
        for relation in &record.issue.blocking {
            if !blocking.insert(relation.target) {
                add_finding(
                    findings,
                    record.entry,
                    record.order,
                    "RELATION_DUPLICATE",
                    format!("duplicate blocking entry for {}", relation.target).as_bytes(),
                );
                continue;
            }
            let Some(source) = by_id.get(&relation.target) else {
                add_finding(
                    findings,
                    record.entry,
                    record.order,
                    "BLOCKING_MISSING_TARGET",
                    format!("blocked issue {} does not exist", relation.target).as_bytes(),
                );
                continue;
            };
            if relation.title != source.issue.title {
                add_finding(
                    findings,
                    record.entry,
                    record.order,
                    "RELATION_TITLE",
                    format!("copied title for {} is stale", relation.target).as_bytes(),
                );
            }
            if !source
                .issue
                .waits
                .iter()
                .any(|reverse| reverse.target == record.issue.id)
            {
                add_finding(
                    findings,
                    record.entry,
                    record.order,
                    "RELATION_RECIPROCAL",
                    format!(
                        "blocking entry for {} has no reciprocal wait",
                        relation.target
                    )
                    .as_bytes(),
                );
            }
        }
    }
    for component in wait_graph::cyclic_components(&graph) {
        for id in &component {
            if let Some(record) = by_id.get(id) {
                let cycle = component
                    .iter()
                    .map(ToString::to_string)
                    .collect::<Vec<_>>()
                    .join(" -> ");
                add_finding(
                    findings,
                    record.entry,
                    record.order,
                    "WAIT_CYCLE",
                    format!("active wait cycle: {cycle}").as_bytes(),
                );
            }
        }
    }
}

fn audit_high_water(
    snapshot: &StoreSnapshot,
    order: usize,
    parsed: &[ParsedRecord<'_>],
    findings: &mut Vec<Finding>,
) {
    let Some(bytes) = &snapshot.high_water else {
        findings.push(Finding {
            locator: b".next-id".to_vec(),
            invariant: "NEXT_ID_MISSING",
            detail: b"missing .next-id".to_vec(),
            order,
        });
        return;
    };
    match HighWater::parse(bytes) {
        Ok(high_water) => {
            let minimum = parsed
                .iter()
                .map(|record| record.issue.id.get())
                .max()
                .map_or(1, |id| id + 1);
            if high_water.get() < minimum {
                findings.push(Finding {
                    locator: b".next-id".to_vec(),
                    invariant: "NEXT_ID_BEHIND",
                    detail: format!(
                        ".next-id is {}; expected at least {minimum}",
                        high_water.get()
                    )
                    .into_bytes(),
                    order,
                });
            }
        }
        Err(error) => findings.push(Finding {
            locator: b".next-id".to_vec(),
            invariant: "NEXT_ID_INVALID",
            detail: error.to_string().into_bytes(),
            order,
        }),
    }
}

fn add_finding(
    findings: &mut Vec<Finding>,
    entry: &StoreEntry,
    order: usize,
    invariant: &'static str,
    detail: &[u8],
) {
    findings.push(Finding {
        locator: entry.filename().to_vec(),
        invariant,
        detail: sanitize_detail(detail),
        order,
    });
}

fn sanitize_detail(bytes: &[u8]) -> Vec<u8> {
    bytes
        .iter()
        .map(|byte| {
            if matches!(byte, b'\n' | b'\r' | b'\t') {
                b' '
            } else {
                *byte
            }
        })
        .collect()
}

fn escape_locator(bytes: &[u8]) -> Vec<u8> {
    let mut output = Vec::new();
    for byte in bytes {
        match byte {
            b'\\' => output.extend_from_slice(b"\\\\"),
            b'\t' => output.extend_from_slice(b"\\t"),
            b'\n' => output.extend_from_slice(b"\\n"),
            b'\r' => output.extend_from_slice(b"\\r"),
            0x20..=0x7e => output.push(*byte),
            _ => output.extend_from_slice(format!("\\x{byte:02X}").as_bytes()),
        }
    }
    output
}

#[cfg(test)]
mod tests {
    use super::*;

    // Independent current-format input: do not use the production renderer to
    // manufacture the corruption that this audit is supposed to diagnose.
    fn record(id: u16, metadata: &str) -> StoreEntry {
        StoreEntry::for_test(
            format!("{id:04}-issue.md").as_bytes(),
            format!(
                "# {id:04} — Issue\n\n## Metadata\n\n- **Status:** open\n- **Kind:** bug\n- **Created:** 2026-09-05\n{metadata}\n## Statement\n\nText.\n\n## Evidence\n\n- Verified.\n\n## Outcome\n\nDone.\n"
            ).as_bytes(),
        )
    }

    fn snapshot(entries: Vec<StoreEntry>) -> StoreSnapshot {
        StoreSnapshot {
            entries,
            high_water: Some(b"10000\n".to_vec()),
        }
    }

    fn codes(snapshot: &StoreSnapshot) -> Vec<(String, &'static str)> {
        audit(snapshot)
            .findings
            .into_iter()
            .map(|f| (String::from_utf8(f.locator).unwrap(), f.invariant))
            .collect()
    }

    #[test]
    fn clean_empty_and_populated_snapshots_have_no_findings() {
        for entries in [vec![], vec![record(1, "")]] {
            let report = audit(&snapshot(entries));
            assert!(!report.has_findings());
            assert!(report.render().is_empty());
        }
    }

    #[test]
    fn malformed_names_content_and_fields_are_reported() {
        let valid = record(1, "");
        for (name, bytes, expected) in [
            (
                b"notes.txt".as_slice(),
                valid.bytes().to_vec(),
                vec!["RECORD_FORMAT"],
            ),
            (b"0001-issue.md", b"Broken".to_vec(), vec!["RECORD_FORMAT"]),
            (
                b"0001-issue.md",
                b"\xff".to_vec(),
                vec!["CONTENT_UTF8", "RECORD_FORMAT"],
            ),
            (
                b"0001-\xff.md",
                valid.bytes().to_vec(),
                vec!["FILENAME_UTF8", "RECORD_FORMAT"],
            ),
        ] {
            let report = audit(&snapshot(vec![StoreEntry::for_test(name, &bytes)]));
            assert!(report.has_findings());
            assert_eq!(
                report
                    .findings
                    .iter()
                    .map(|f| f.invariant)
                    .collect::<Vec<_>>(),
                expected
            );
        }
        let text = String::from_utf8(valid.bytes().to_vec()).unwrap();
        for (from, to) in [
            ("# 0001", "# 0002"),
            ("**Status:** open", "**Status:** unknown"),
            ("2026-09-05", "not-a-date"),
            ("## Statement", "## Other"),
        ] {
            let entry = StoreEntry::for_test(valid.filename(), text.replace(from, to).as_bytes());
            assert_eq!(
                codes(&snapshot(vec![entry])),
                vec![("0001-issue.md".into(), "RECORD_FORMAT")]
            );
        }
    }

    #[test]
    fn duplicate_ids_report_both_files() {
        let first = record(1, "");
        let second = StoreEntry::for_test(b"0001-other.md", first.bytes());
        assert_eq!(
            codes(&snapshot(vec![second, first])),
            vec![
                ("0001-issue.md".into(), "DUPLICATE_ID"),
                ("0001-other.md".into(), "DUPLICATE_ID"),
            ]
        );
    }

    #[test]
    fn closed_records_accumulate_lifecycle_findings() {
        let entry = record(1, "- **Tags:** priority-high\n");
        let text = String::from_utf8(entry.bytes().to_vec())
            .unwrap()
            .replace("Verified.", "Pending.")
            .replace("Done.", "Pending.");
        // The same pending fields and priority are permitted on an open issue.
        assert!(
            codes(&snapshot(vec![StoreEntry::for_test(
                entry.filename(),
                text.as_bytes()
            )]))
            .is_empty()
        );
        let closed = text.replace("**Status:** open", "**Status:** closed");
        assert_eq!(
            codes(&snapshot(vec![StoreEntry::for_test(
                entry.filename(),
                closed.as_bytes()
            )])),
            vec![
                ("0001-issue.md".into(), "CLOSED_PRIORITY"),
                ("0001-issue.md".into(), "EVIDENCE_PENDING"),
                ("0001-issue.md".into(), "OUTCOME_PENDING"),
            ]
        );
    }

    const WAIT: &str = "- **Waiting on:**\n  - #0002 — Issue\n    - **Reason:** Needed.\n";
    const BLOCK: &str = "- **Blocking:**\n  - #0001 — Issue\n";

    #[test]
    fn relations_cover_both_directions_and_duplicate_entries() {
        let duplicate_wait = format!("{WAIT}  - #0002 — Issue\n    - **Reason:** Again.\n");
        let duplicate_block = format!("{BLOCK}  - #0001 — Issue\n");
        let cases = [
            (WAIT.to_owned(), BLOCK.to_owned(), vec![]),
            (
                WAIT.to_owned(),
                String::new(),
                vec![(1, "RELATION_RECIPROCAL")],
            ),
            (
                String::new(),
                BLOCK.to_owned(),
                vec![(2, "RELATION_RECIPROCAL")],
            ),
            (
                WAIT.replace("Issue", "Stale"),
                BLOCK.to_owned(),
                vec![(1, "RELATION_TITLE")],
            ),
            (
                WAIT.to_owned(),
                BLOCK.replace("Issue", "Stale"),
                vec![(2, "RELATION_TITLE")],
            ),
            (
                duplicate_wait,
                BLOCK.to_owned(),
                vec![(1, "RELATION_DUPLICATE")],
            ),
            (
                WAIT.to_owned(),
                duplicate_block,
                vec![(2, "RELATION_DUPLICATE")],
            ),
            (
                WAIT.replace("0002", "0003"),
                String::new(),
                vec![(1, "WAIT_MISSING_TARGET")],
            ),
            (
                String::new(),
                BLOCK.replace("0001", "0003"),
                vec![(2, "BLOCKING_MISSING_TARGET")],
            ),
        ];
        for (wait, block, expected) in cases {
            let expected = expected
                .into_iter()
                .map(|(id, code)| (format!("{id:04}-issue.md"), code))
                .collect::<Vec<_>>();
            assert_eq!(
                codes(&snapshot(vec![record(1, &wait), record(2, &block)])),
                expected,
                "{wait:?} {block:?}"
            );
        }
    }

    #[test]
    fn cycles_include_self_waits_but_exclude_satisfied_history() {
        let one = record(1, &format!("{WAIT}{}", BLOCK.replace("0001", "0002")));
        let two = record(2, &format!("{}{BLOCK}", WAIT.replace("0002", "0001")));
        assert_eq!(
            codes(&snapshot(vec![one.clone(), two.clone()])),
            vec![
                ("0001-issue.md".into(), "WAIT_CYCLE"),
                ("0002-issue.md".into(), "WAIT_CYCLE"),
            ]
        );
        let closed = String::from_utf8(two.bytes().to_vec())
            .unwrap()
            .replace("**Status:** open", "**Status:** closed");
        assert!(
            codes(&snapshot(vec![
                one,
                StoreEntry::for_test(two.filename(), closed.as_bytes())
            ]))
            .is_empty()
        );
        let self_wait = record(1, &format!("{}{BLOCK}", WAIT.replace("0002", "0001")));
        assert_eq!(
            codes(&snapshot(vec![self_wait])),
            vec![("0001-issue.md".into(), "WAIT_CYCLE")]
        );
    }

    #[test]
    fn high_water_covers_missing_invalid_behind_and_valid_values() {
        for (value, expected) in [
            (None, Some("NEXT_ID_MISSING")),
            (Some(""), Some("NEXT_ID_INVALID")),
            (Some("oops"), Some("NEXT_ID_INVALID")),
            (Some("0"), Some("NEXT_ID_INVALID")),
            (Some("10001"), Some("NEXT_ID_INVALID")),
            (Some("1\n"), Some("NEXT_ID_BEHIND")),
            (Some("2\n"), None),
            (Some("00002\n"), None),
            (Some("10000\n"), None),
        ] {
            let mut state = snapshot(vec![record(1, "")]);
            state.high_water = value.map(|s| s.as_bytes().to_vec());
            assert_eq!(
                codes(&state),
                expected
                    .into_iter()
                    .map(|code| (".next-id".into(), code))
                    .collect::<Vec<_>>(),
                "{value:?}"
            );
        }
    }

    #[test]
    fn findings_accumulate_and_sort_independently_of_input_order() {
        let mut state = snapshot(vec![
            record(2, ""),
            StoreEntry::for_test(b"0001-issue.md", b"Broken"),
            record(3, &BLOCK.replace("0001", "0009")),
        ]);
        state.high_water = None;
        let report = audit(&state);
        state.entries.reverse();
        assert_eq!(audit(&state), report);
        assert_eq!(
            codes(&state),
            vec![
                (".next-id".into(), "NEXT_ID_MISSING"),
                ("0001-issue.md".into(), "RECORD_FORMAT"),
                ("0003-issue.md".into(), "BLOCKING_MISSING_TARGET"),
            ]
        );
    }

    #[test]
    fn rendering_escapes_locators_and_keeps_details_on_one_tsv_row() {
        let entry = StoreEntry::for_test(b"bad\\\t\n\r\xff", b"");
        let mut findings = Vec::new();
        add_finding(
            &mut findings,
            &entry,
            0,
            "EXAMPLE",
            b"one\ttwo\nthree\rfour",
        );
        assert_eq!(
            CheckReport { findings }.render(),
            b"bad\\\\\\t\\n\\r\\xFF\tEXAMPLE\tone two three four\n"
        );
        let report = audit(&snapshot(vec![entry]));
        assert!(String::from_utf8(report.render()).is_ok());
        assert!(
            report
                .render()
                .split(|b| *b == b'\n')
                .filter(|row| !row.is_empty())
                .all(|row| row.iter().filter(|b| **b == b'\t').count() == 2)
        );
    }
}
