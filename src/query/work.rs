//! State and timing inspection, retaining deterministic span history.
use super::QueryError;
use crate::{filesystem::StoredRecord, issue::IssueId, work_log::WorkTime, work_wire::WorkData};
use serde::Serialize;

#[derive(Serialize)]
pub struct WorkReport {
    pub schema_version: u32,
    pub id: String,
    pub total_seconds: u64,
    #[serde(flatten)]
    pub work: WorkData,
}
pub fn work_report(
    records: &[StoredRecord],
    id: IssueId,
    at: WorkTime,
) -> Result<WorkReport, QueryError> {
    let mut selected = None;
    for record in records {
        if crate::record::parse_filename(record.filename())?.0 == id
            && selected.replace(record).is_some()
        {
            return Err(QueryError::DuplicateId(id));
        }
    }
    let document = selected.ok_or(QueryError::MissingIssue(id))?.document()?;
    Ok(WorkReport {
        schema_version: 1,
        id: id.to_string(),
        total_seconds: document.work_log.total_seconds(at),
        work: WorkData::new(&document.issue, &document.work_log),
    })
}
impl WorkReport {
    pub fn render(&self) -> Vec<u8> {
        let summary = &self.work.summary;
        let mut text = format!("Issue {}\nWork state: {}\n", self.id, summary.state);
        if let Some(reason) = summary.reason {
            text.push_str(&format!("Reason: {reason}\n"));
        }
        if let Some(question) = &summary.question {
            text.push_str(&format!("Question: {question}\n"));
        }
        text.push_str(&format!(
            "Work time: {}h {:02}m {:02}s{}\n",
            self.total_seconds / 3600,
            (self.total_seconds / 60) % 60,
            self.total_seconds % 60,
            if summary.running_since.is_some() {
                " (running)"
            } else {
                ""
            }
        ));
        if !self.work.spans.is_empty() {
            text.push_str("\nSpans (UTC):\n");
        }
        for (index, span) in self.work.spans.iter().enumerate() {
            text.push_str(&format!(
                "{}\t{}\t{}\t{}\n",
                index + 1,
                span.started,
                span.stopped.as_deref().unwrap_or("running"),
                span.activity
            ));
        }
        text.into_bytes()
    }
}
