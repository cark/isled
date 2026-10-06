//! Structured work metadata and the human-readable work-log table codec.
use super::RecordError;
use crate::{
    issue::{OwnerQuestion, OwnerWait, WorkState, WorkStateKind},
    work_log::{WorkActivity, WorkLog, WorkSpan},
};

pub(super) fn parse_state(
    lines: &[&[u8]],
    index: &mut usize,
) -> Result<Option<WorkState>, RecordError> {
    let Some(value) = lines
        .get(*index)
        .and_then(|line| line.strip_prefix(b"- **Work state:** "))
    else {
        return Ok(None);
    };
    *index += 1;
    let kind = std::str::from_utf8(value)
        .ok()
        .and_then(|text| text.parse::<WorkStateKind>().ok())
        .ok_or(RecordError::InvalidWorkState)?;
    Ok(match kind {
        WorkStateKind::NotQueued => None,
        WorkStateKind::Queued => Some(WorkState::Queued),
        WorkStateKind::InProgress => Some(WorkState::InProgress),
        WorkStateKind::AwaitingOwner => {
            let reason = lines
                .get(*index)
                .and_then(|line| line.strip_prefix(b"  - **Reason:** "))
                .ok_or(RecordError::InvalidWorkState)?;
            *index += 1;
            let wait = match reason {
                b"review" => OwnerWait::Review,
                b"clarification" => {
                    let question = lines
                        .get(*index)
                        .and_then(|line| line.strip_prefix(b"  - **Question:** "))
                        .ok_or(RecordError::InvalidWorkState)?;
                    *index += 1;
                    OwnerWait::Clarification(
                        OwnerQuestion::parse(
                            std::str::from_utf8(question)
                                .map_err(|_| RecordError::InvalidWorkState)?,
                        )
                        .map_err(|_| RecordError::InvalidWorkState)?,
                    )
                }
                _ => return Err(RecordError::InvalidWorkState),
            };
            Some(WorkState::AwaitingOwner(wait))
        }
    })
}

pub(super) fn render_state(output: &mut Vec<u8>, state: Option<&WorkState>) {
    if let Some(state) = state {
        output
            .extend_from_slice(format!("- **Work state:** {}\n", state.kind().as_str()).as_bytes());
        if let Some(wait) = state.owner_wait() {
            output.extend_from_slice(format!("  - **Reason:** {}\n", wait.reason()).as_bytes());
            if let Some(question) = wait.question() {
                output.extend_from_slice(format!("  - **Question:** {question}\n").as_bytes());
            }
        }
    }
}

pub(super) fn parse_log(
    bytes: Option<&[u8]>,
    state: Option<&WorkState>,
) -> Result<WorkLog, RecordError> {
    let Some(bytes) = bytes else {
        return Ok(WorkLog::default());
    };
    let text = std::str::from_utf8(bytes).map_err(|_| RecordError::InvalidWorkLog)?;
    let mut lines = text.lines();
    if cells(lines.next().ok_or(RecordError::InvalidWorkLog)?)?
        != ["Started (UTC)", "Stopped (UTC)", "Activity"]
    {
        return Err(RecordError::InvalidWorkLog);
    }
    let separator = cells(lines.next().ok_or(RecordError::InvalidWorkLog)?)?;
    if !separator
        .iter()
        .all(|cell| cell.len() >= 3 && cell.bytes().all(|b| b == b'-'))
    {
        return Err(RecordError::InvalidWorkLog);
    }
    let spans = lines
        .map(|line| {
            let [start, stop, activity] = cells(line)?;
            WorkSpan::new(
                start.parse().map_err(|_| RecordError::InvalidWorkLog)?,
                if stop.is_empty() {
                    None
                } else {
                    Some(stop.parse().map_err(|_| RecordError::InvalidWorkLog)?)
                },
                WorkActivity::parse(activity).map_err(|_| RecordError::InvalidWorkLog)?,
            )
            .map_err(|_| RecordError::InvalidWorkLog)
        })
        .collect::<Result<Vec<_>, _>>()?;
    if spans.is_empty() {
        return Err(RecordError::InvalidWorkLog);
    }
    let log = WorkLog::from_spans(spans).map_err(|_| RecordError::InvalidWorkLog)?;
    if log.active().is_some() && state.map(WorkState::kind) != Some(WorkStateKind::InProgress) {
        return Err(RecordError::InvalidWorkLog);
    }
    Ok(log)
}

fn cells(line: &str) -> Result<[&str; 3], RecordError> {
    let row = line
        .strip_prefix('|')
        .and_then(|s| s.strip_suffix('|'))
        .ok_or(RecordError::InvalidWorkLog)?;
    let mut cells = row.split('|').map(str::trim);
    let result = [cells.next(), cells.next(), cells.next()];
    match result {
        [Some(a), Some(b), Some(c)] if cells.next().is_none() => Ok([a, b, c]),
        _ => Err(RecordError::InvalidWorkLog),
    }
}

pub(super) fn render_log(log: &WorkLog) -> Vec<u8> {
    let mut text = "| Started (UTC)       | Stopped (UTC)       | Activity       |\n|---------------------|---------------------|----------------|".to_owned();
    for span in log.spans() {
        text.push_str(&format!(
            "\n| {:<19} | {:<19} | {:<14} |",
            span.started().to_string(),
            span.stopped()
                .map(|time| time.to_string())
                .unwrap_or_default(),
            span.activity().as_str()
        ));
    }
    text.into_bytes()
}
