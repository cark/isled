//! Compact response values and hashes of their complete serialized meaning.
use crate::{
    cache::Summary,
    filesystem::ProjectRoot,
    snapshot::{SnapshotIssue, json::WireIssue},
    wire::EncodedBytes,
};
use serde::{Serialize, Serializer};

pub struct Bytes(pub Vec<u8>);
impl Serialize for Bytes {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        EncodedBytes::new(&self.0).serialize(serializer)
    }
}

#[derive(Serialize)]
pub struct SummaryData {
    pub id: String,
    status: &'static str,
    ready: bool,
    kind: String,
    title: Bytes,
    path: Bytes,
    work: crate::work_wire::WorkSummary,
}
impl SummaryData {
    pub fn new(
        root: &ProjectRoot,
        row: &Summary,
    ) -> Result<Self, crate::filesystem::FilesystemError> {
        Ok(Self {
            work: row.work().clone(),
            id: row.id().to_string(),
            status: row.status().as_str(),
            ready: row.ready(),
            kind: row.kind().as_str().into(),
            title: Bytes(row.title().as_bytes().to_vec()),
            path: Bytes(root.issue_path_bytes_lossless(row.filename().as_bytes())?),
        })
    }
}
#[derive(Serialize)]
pub struct Problem {
    pub id: String,
    pub path: Option<Bytes>,
    pub error: String,
}
#[derive(Serialize)]
pub struct View {
    pub issues: Vec<SummaryData>,
    pub unavailable: Vec<Problem>,
}

pub struct Detail {
    pub issue: SnapshotIssue,
    pub targets: Vec<SummaryData>,
    pub unavailable: Vec<Problem>,
}
impl Serialize for Detail {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        #[derive(Serialize)]
        struct Data<'a> {
            issue: WireIssue<'a>,
            targets: &'a [SummaryData],
            unavailable: &'a [Problem],
        }
        Data {
            issue: WireIssue::new(&self.issue),
            targets: &self.targets,
            unavailable: &self.unavailable,
        }
        .serialize(serializer)
    }
}

#[derive(Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Payload {
    Issue { detail: Box<Detail> },
    Deleted,
    Problem { problem: Problem },
}
#[derive(Serialize)]
pub struct Change {
    pub id: String,
    pub hash: String,
    #[serde(flatten)]
    pub payload: Payload,
}
#[derive(Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum WarningTarget {
    Issue { issue: SummaryData },
    Problem { problem: Problem },
}

#[derive(Serialize)]
pub struct Response {
    pub schema_version: u32,
    pub root: Bytes,
    pub view_hash: Option<String>,
    pub view: Option<View>,
    pub changes: Vec<Change>,
    pub first_warning: Option<WarningTarget>,
    pub warning_targets: Vec<WarningTarget>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub choices: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) graph: Option<super::graph::GraphResponse>,
}
pub fn live_hash(value: &impl Serialize) -> Result<String, serde_json::Error> {
    // Hash the complete payload, including derived fields and target summaries.
    Ok(format!(
        "{:016x}",
        xxhash_rust::xxh3::xxh3_64(&serde_json::to_vec(value)?)
    ))
}
