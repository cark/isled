//! Shared stable work projections for CLI, snapshots and editor responses.
use crate::{
    issue::{Issue, WorkStateKind},
    work_log::{WorkLog, WorkTime},
};
use serde::Serialize;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct WorkSummary {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    pub state: String,
    pub reason: Option<String>,
    pub question: Option<String>,
    pub since: Option<String>,
    pub recorded_seconds: u64,
    pub running_since: Option<String>,
}
impl WorkSummary {
    pub(crate) fn use_workflow(&mut self, workflow: &crate::workflow::Workflow) {
        self.label = Some(workflow.label(&self.state, self.reason.as_deref()).into());
    }
    pub(crate) fn new(issue: &Issue, log: &WorkLog) -> Self {
        let wait = issue.work_state().and_then(|state| state.owner_wait());
        Self {
            label: None,
            state: issue.work_state_kind().as_str().into(),
            reason: wait.map(|wait| wait.reason().to_owned()),
            question: wait.and_then(|wait| wait.question()).map(str::to_owned),
            since: issue
                .work_state()
                .and_then(|state| state.since())
                .map(|time| time.to_string()),
            recorded_seconds: log
                .spans()
                .iter()
                .filter_map(|span| span.stopped().map(|end| end.seconds_since(span.started())))
                .sum(),
            running_since: log.active().map(|span| span.started().to_string()),
        }
    }
    pub(crate) fn from_cached(
        state: WorkStateKind,
        reason: Option<String>,
        question: Option<String>,
        recorded_seconds: u64,
        running_since: Option<WorkTime>,
        since: Option<WorkTime>,
    ) -> Self {
        Self {
            label: None,
            state: state.as_str().into(),
            reason,
            question,
            recorded_seconds,
            running_since: running_since.map(|time| time.to_string()),
            since: since.map(|time| time.to_string()),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct WorkData {
    #[serde(flatten)]
    pub summary: WorkSummary,
    pub spans: Vec<SpanData>,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct SpanData {
    pub started: String,
    pub stopped: Option<String>,
    pub activity: String,
}
impl WorkData {
    pub(crate) fn new(issue: &Issue, log: &WorkLog) -> Self {
        Self {
            summary: WorkSummary::new(issue, log),
            spans: log
                .spans()
                .iter()
                .map(|span| SpanData {
                    started: span.started().to_string(),
                    stopped: span.stopped().map(|time| time.to_string()),
                    activity: span.activity().as_str().into(),
                })
                .collect(),
        }
    }
}
