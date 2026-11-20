//! Locked callers apply one state/clock transition to one validated issue.
use super::{
    MutationError, MutationPlan, parse_record_document, plan_record_replacement, unique_record,
};
use crate::{
    filesystem::StoredRecord,
    issue::{IssueId, OwnerWait, Status, WorkState},
    work_log::{WorkActivity, WorkTime},
};

#[derive(Clone, Debug)]
pub enum WorkAction {
    Plan,
    Prepare,
    Queue,
    Unqueue,
    Start {
        timed: bool,
        activity: WorkActivity,
    },
    Pause,
    Resume(WorkActivity),
    Set {
        state: WorkState,
        timed: bool,
        activity: WorkActivity,
        explicit_clock: bool,
    },
    AwaitOwner(OwnerWait),
    CorrectStop {
        span: std::num::NonZeroUsize,
        stopped: WorkTime,
    },
}

pub fn work_update(
    records: &[StoredRecord],
    id: IssueId,
    action: &WorkAction,
    at: WorkTime,
) -> Result<MutationPlan, MutationError> {
    let record = unique_record(records, id)?;
    let mut document = parse_record_document(record)?;
    if document.issue.status == Status::Closed && !matches!(action, WorkAction::CorrectStop { .. })
    {
        return Err(MutationError::ClosedWork);
    }
    let old_log = document.work_log.clone();
    match action {
        WorkAction::Plan | WorkAction::Prepare | WorkAction::Queue => {
            document.work_log.stop(at)?;
            let state = match action {
                WorkAction::Plan => WorkState::Planning { since: None },
                WorkAction::Prepare => WorkState::Prepared { since: None },
                _ => WorkState::Queued { since: None },
            };
            transition(&mut document.issue.work_state, state, at);
        }
        WorkAction::Unqueue => {
            document.work_log.stop(at)?;
            document.issue.work_state = None;
        }
        WorkAction::Start { timed, activity } => {
            if *timed {
                document.work_log.start(at, activity)?;
            } else {
                document.work_log.stop(at)?;
            }
            transition(
                &mut document.issue.work_state,
                WorkState::InProgress { since: None },
                at,
            );
        }
        WorkAction::Resume(activity) => {
            if document.work_log.active().is_none() {
                document.work_log.start(at, activity)?;
            }
        }
        WorkAction::Set {
            state,
            timed,
            activity,
            explicit_clock,
        } => {
            let changed = document
                .issue
                .work_state
                .as_ref()
                .is_none_or(|old| !old.same_phase(state));
            if changed {
                document.work_log.stop(at)?;
            }
            if changed || *explicit_clock {
                if *timed {
                    document.work_log.start(at, activity)?;
                } else {
                    document.work_log.stop(at)?;
                }
            }
            transition(&mut document.issue.work_state, state.clone(), at);
        }
        WorkAction::Pause => {
            document.work_log.stop(at)?;
        }
        WorkAction::AwaitOwner(wait) => {
            document.work_log.stop(at)?;
            transition(
                &mut document.issue.work_state,
                WorkState::AwaitingOwner {
                    wait: wait.clone(),
                    since: None,
                },
                at,
            );
        }
        WorkAction::CorrectStop { span, stopped } => {
            document.work_log.correct_stop(span.get() - 1, *stopped)?;
        }
    }
    if old_log != document.work_log {
        document.work_log_source = None;
    }
    if record.document().is_ok_and(|old| old == &document) {
        return Ok(MutationPlan::default());
    }
    Ok(plan_record_replacement(record, document))
}

fn transition(current: &mut Option<WorkState>, next: WorkState, at: WorkTime) {
    let since = match current.as_ref() {
        Some(previous) if previous.same_phase(&next) => {
            if previous.owner_wait().and_then(OwnerWait::question)
                == next.owner_wait().and_then(OwnerWait::question)
            {
                return;
            }
            previous.since()
        }
        _ => Some(at),
    };
    *current = Some(next.with_since(since));
}
