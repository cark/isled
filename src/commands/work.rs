//! Validate and execute one work action under the existing ledger lock.
use super::{error::AppError, issue_id::parse_issue_id};
use isled::{
    cli::{WorkArgs, WorkCommand},
    filesystem::{FilesystemError, ProjectRoot},
    issue::{OwnerQuestion, OwnerWait},
    mutation::{self, WorkAction},
    work_log::{WorkActivity, WorkTime},
};

fn time(value: Option<&str>) -> Result<WorkTime, AppError> {
    value
        .map(str::parse)
        .transpose()
        .map(|value| value.unwrap_or_else(WorkTime::now))
        .map_err(|error: isled::work_log::WorkLogError| AppError::Invocation(error.to_string()))
}

pub(crate) fn run(
    arguments: WorkArgs,
    project: impl FnOnce() -> Result<ProjectRoot, FilesystemError>,
) -> Result<Vec<u8>, AppError> {
    let project = project()?;
    let lock = project.acquire_lock()?;
    let workflow = isled::workflow::Workflow::read(&project)
        .map_err(AppError::Io)?
        .0;
    let set = |state: &str,
               reason: Option<&str>,
               question: Option<&str>,
               timed: Option<bool>,
               activity: Option<&str>| {
        use isled::{issue::WorkState, workflow::Clock};
        let definition = workflow.state(state).map_err(AppError::Invocation)?;
        let wait = if let Some(reason) = reason {
            let r = definition
                .reasons
                .get(reason)
                .ok_or_else(|| AppError::Invocation(format!("unknown work reason: {reason}")))?;
            if r.prompt.is_some() != question.is_some() {
                return Err(AppError::Invocation(format!(
                    "{reason}: {}",
                    r.prompt.as_deref().unwrap_or("does not accept a question")
                )));
            }
            let q = question
                .map(OwnerQuestion::parse)
                .transpose()
                .map_err(|e| AppError::Invocation(e.to_string()))?;
            Some(OwnerWait::Configured(reason.into(), q))
        } else {
            if !definition.reasons.is_empty() || question.is_some() {
                return Err(AppError::Invocation(format!("{state} requires --reason")));
            }
            None
        };
        let active = timed.unwrap_or(matches!(definition.clock, Clock::Auto));
        if active && matches!(definition.clock, Clock::Off) {
            return Err(AppError::Invocation(format!("clock is off for {state}")));
        }
        let activity = WorkActivity::parse(activity.unwrap_or(&definition.label))
            .map_err(|e| AppError::Invocation(e.to_string()))?;
        Ok(WorkAction::Set {
            state: WorkState::Configured {
                kind: state
                    .parse()
                    .map_err(|_| AppError::Invocation("invalid state".into()))?,
                wait,
                since: None,
            },
            timed: active,
            activity,
            explicit_clock: timed.is_some(),
        })
    };
    let (target, action) = match arguments.command {
        WorkCommand::Show(args) => {
            let id = parse_issue_id(&args.target.id)?;
            let at = time(args.target.at.as_deref())?;

            let records = lock.read_issue_records(id)?;
            let report = isled::query::work_report(&records, id, at)?;
            lock.finish()?;
            return if args.json {
                let mut data = serde_json::to_vec(&report)?;
                data.push(b'\n');
                Ok(data)
            } else {
                Ok(report.render())
            };
        }
        WorkCommand::Plan(args) => (args, set("planning", None, None, None, None)?),
        WorkCommand::Prepare(args) => (args, set("prepared", None, None, None, None)?),
        WorkCommand::Queue(args) => (args, set("queued", None, None, None, None)?),
        WorkCommand::Unqueue(args) => (args, WorkAction::Unqueue),
        WorkCommand::Pause(args) => (args, WorkAction::Pause),
        WorkCommand::Start(args) => (
            args.target,
            set(
                "in-progress",
                None,
                None,
                Some(!args.no_clock),
                Some(args.activity.as_deref().unwrap_or("")),
            )?,
        ),
        WorkCommand::Await(args) => (
            args.target,
            set(
                "awaiting-owner",
                Some(&args.reason),
                args.question.as_deref(),
                None,
                None,
            )?,
        ),
        WorkCommand::Set {
            target,
            state,
            reason,
            question,
        } => (
            target,
            set(&state, reason.as_deref(), question.as_deref(), None, None)?,
        ),
        WorkCommand::Resume(target) => {
            let id = parse_issue_id(&target.id)?;
            let records = lock.read_issue_records(id)?;
            let report = isled::query::work_report(&records, id, time(target.at.as_deref())?)?;
            let state = workflow
                .state(&report.work.summary.state)
                .map_err(AppError::Invocation)?;
            if matches!(state.clock, isled::workflow::Clock::Off) {
                return Err(AppError::Invocation(format!(
                    "clock is off for {}",
                    report.work.summary.state
                )));
            }
            (
                target,
                WorkAction::Resume(
                    WorkActivity::parse(&state.label)
                        .map_err(|e| AppError::Invocation(e.to_string()))?,
                ),
            )
        }
        WorkCommand::Correct(args) => {
            let stopped = time(Some(&args.stop))?;
            (
                isled::cli::WorkAtArgs {
                    id: args.id,
                    at: None,
                },
                WorkAction::CorrectStop {
                    span: args.span,
                    stopped,
                },
            )
        }
    };
    let id = parse_issue_id(&target.id)?;
    let explicit_at = target
        .at
        .as_deref()
        .map(|text| time(Some(text)))
        .transpose()?;
    let records = lock.read_issue_records(id)?;
    // Read the default time after acquisition so contention cannot backdate a new span.
    let at = explicit_at.unwrap_or_else(WorkTime::now);
    let plan = mutation::work_update(&records, id, &action, at)?;
    let historical = mutation::changes_closed_issue(&records, id, &plan)?;
    lock.publish(&plan)?;
    lock.finish()?;
    if historical {
        eprintln!("warning: issue {id} is closed; updating historical record");
    }
    Ok(format!("updated work for issue {id}\n").into_bytes())
}
