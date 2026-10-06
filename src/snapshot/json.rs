//! Versioned JSON serialization for the application snapshot.

use super::Snapshot;
use crate::reference::InlineIssueReference;
use crate::wire::EncodedBytes;
use serde::Serialize;

pub const SCHEMA_VERSION: u32 = 4;

pub fn render(snapshot: &Snapshot) -> Result<Vec<u8>, serde_json::Error> {
    let issues = snapshot.issues().iter().map(WireIssue::new).collect();
    let mut output = serde_json::to_vec(&WireSnapshot {
        schema_version: SCHEMA_VERSION,
        root: EncodedBytes::new(snapshot.root()),
        issues,
        unavailable: snapshot
            .unavailable()
            .iter()
            .map(|issue| WireUnavailable {
                id: issue.id().to_string(),
                path: EncodedBytes::new(issue.path()),
                error: issue.error(),
            })
            .collect(),
    })?;
    output.push(b'\n');
    Ok(output)
}

#[derive(Serialize)]
struct WireSnapshot<'a> {
    schema_version: u32,
    root: EncodedBytes<'a>,
    issues: Vec<WireIssue<'a>>,
    unavailable: Vec<WireUnavailable<'a>>,
}

#[derive(Serialize)]
struct WireUnavailable<'a> {
    id: String,
    path: EncodedBytes<'a>,
    error: &'a str,
}

#[derive(Serialize)]
pub(crate) struct WireIssue<'a> {
    id: String,
    status: &'static str,
    ready: bool,
    kind: &'a str,
    title: EncodedBytes<'a>,
    path: EncodedBytes<'a>,
    content: EncodedBytes<'a>,
    references: Vec<WireReference<'a>>,
    work: &'a crate::work_wire::WorkData,
    warnings: Vec<WireWarning<'a>>,
}

impl<'a> WireIssue<'a> {
    pub(crate) fn new(issue: &'a super::SnapshotIssue) -> Self {
        Self {
            work: issue.work(),
            id: issue.id().to_string(),
            status: issue.status().as_str(),
            ready: issue.is_ready(),
            kind: issue.kind().as_str(),
            title: EncodedBytes::new(issue.title()),
            path: EncodedBytes::new(issue.path()),
            content: EncodedBytes::new(issue.content()),
            references: issue.references().iter().map(WireReference::new).collect(),
            warnings: issue
                .warnings()
                .iter()
                .map(|warning| WireWarning {
                    code: warning.code(),
                    message: warning.message(),
                    related_ids: vec![warning.related_id().to_string()],
                    source_id: warning.source_id().to_string(),
                    target_id: warning.target_id().to_string(),
                    needs_reason: warning.needs_reason(),
                })
                .collect(),
        }
    }
}

#[derive(Serialize)]
struct WireWarning<'a> {
    code: &'static str,
    message: &'a str,
    related_ids: Vec<String>,
    source_id: String,
    target_id: String,
    needs_reason: bool,
}

#[derive(Serialize)]
struct WireReference<'a> {
    field: &'static str,
    entry: usize,
    authored: &'a str,
    target_id: String,
    resolution: &'static str,
    byte_start: usize,
    byte_length: usize,
    character_start: usize,
    character_length: usize,
}

impl<'a> WireReference<'a> {
    fn new(reference: &'a InlineIssueReference) -> Self {
        Self {
            field: reference.field().as_str(),
            entry: reference.entry(),
            authored: reference.authored(),
            target_id: reference.target().to_string(),
            resolution: reference.resolution().as_str(),
            byte_start: reference.byte_start(),
            byte_length: reference.byte_length(),
            character_start: reference.character_start(),
            character_length: reference.character_length(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::filesystem::StoredRecord;
    use crate::snapshot::SnapshotSource;

    #[test]
    fn renders_utf8_records_and_lossless_opaque_paths() {
        let content = "# 0001 — Title\n\n## Metadata\n\n- **Status:** open\n- **Kind:** feature\n- **Created:** 2026-09-02\n\n## Statement\n\nCafé #1 and #2.\n\n## Evidence\n\n- Pending.\n\n## Outcome\n\nPending.\n".as_bytes();
        let source_record_0 =
            StoredRecord::new(b"0001-title.md".to_vec(), (content).to_vec()).unwrap();
        let sources = [SnapshotSource::record(
            &source_record_0,
            b"/project-\xff/.issues/0001-title.md",
        )];
        let snapshot = Snapshot::build(b"/project-\xff", &sources).expect("valid snapshot");

        let output = render(&snapshot).expect("serializable snapshot");
        let value: serde_json::Value = serde_json::from_slice(&output).expect("valid JSON");

        assert_eq!(value["schema_version"], 4);
        assert_eq!(value["root"]["encoding"], "base64");
        assert_eq!(value["issues"][0]["id"], "0001");
        assert_eq!(value["issues"][0]["status"], "open");
        assert_eq!(value["issues"][0]["kind"], "feature");
        assert!(value["issues"][0]["ready"].as_bool().unwrap());
        assert_eq!(value["issues"][0]["title"]["encoding"], "utf-8");
        assert_eq!(value["issues"][0]["title"]["value"], "Title");
        assert_eq!(value["issues"][0]["path"]["encoding"], "base64");
        assert_eq!(value["issues"][0]["content"]["encoding"], "utf-8");
        assert_eq!(
            value["issues"][0]["content"]["value"],
            std::str::from_utf8(content).expect("UTF-8 content")
        );
        assert_eq!(value["issues"][0]["references"][0]["authored"], "#1");
        assert_eq!(value["issues"][0]["references"][0]["target_id"], "0001");
        assert_eq!(
            value["issues"][0]["references"][0]["resolution"],
            "resolved"
        );
        assert_eq!(value["issues"][0]["references"][1]["resolution"], "missing");
        assert_eq!(output.last(), Some(&b'\n'));
    }

    #[test]
    fn renders_structural_relations_with_prose_references() {
        let waiting = b"# 0001 \xe2\x80\x94 Waiting\n\n## Metadata\n\n- **Status:** open\n- **Kind:** feature\n- **Created:** 2026-09-04\n- **Waiting on:**\n  - #0002 \xe2\x80\x94 Blocker\n    - **Reason:** Needed first.\n\n## Statement\n\nAlso see #2.\n\n## Evidence\n\n- Pending.\n\n## Outcome\n\nPending.\n";
        let blocker = b"# 0002 \xe2\x80\x94 Blocker\n\n## Metadata\n\n- **Status:** closed\n- **Kind:** feature\n- **Created:** 2026-09-04\n- **Blocking:**\n  - #0001 \xe2\x80\x94 Waiting\n\n## Statement\n\nDone.\n\n## Evidence\n\n- Verified.\n\n## Outcome\n\nDone.\n";
        let source_record_0 =
            StoredRecord::new(b"0001-waiting.md".to_vec(), (waiting).to_vec()).unwrap();
        let source_record_1 =
            StoredRecord::new(b"0002-blocker.md".to_vec(), (blocker).to_vec()).unwrap();
        let sources = [
            SnapshotSource::record(&source_record_0, b"/project/.issues/0001-waiting.md"),
            SnapshotSource::record(&source_record_1, b"/project/.issues/0002-blocker.md"),
        ];
        let snapshot = Snapshot::build(b"/project", &sources).expect("valid snapshot");

        let output = render(&snapshot).expect("serializable snapshot");
        let value: serde_json::Value = serde_json::from_slice(&output).expect("valid JSON");
        let references = value["issues"][0]["references"].as_array().unwrap();

        assert_eq!(references[0]["field"], "waiting_on");
        assert_eq!(references[0]["authored"], "#0002");
        assert_eq!(references[1]["field"], "statement");
        assert_eq!(references[1]["authored"], "#2");
    }
}
