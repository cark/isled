//! Validate and execute one work action under the existing ledger lock.
use super::{error::AppError, issue_id::parse_issue_id};
use isled::{
    cli::{OwnerReason, WorkArgs, WorkCommand},
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
    let (target, action) = match arguments.command {
        WorkCommand::Show(args) => {
            let id = parse_issue_id(&args.target.id)?;
            let at = time(args.target.at.as_deref())?;
            let project = project()?;
            let lock = project.acquire_lock()?;
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
        WorkCommand::Queue(args) => (args, WorkAction::Queue),
        WorkCommand::Unqueue(args) => (args, WorkAction::Unqueue),
        WorkCommand::Pause(args) => (args, WorkAction::Pause),
        WorkCommand::Start(args) => {
            let activity = WorkActivity::parse(args.activity.as_deref().unwrap_or(""))
                .map_err(|error| AppError::Invocation(error.to_string()))?;
            (
                args.target,
                WorkAction::Start {
                    timed: !args.no_clock,
                    activity,
                },
            )
        }
        WorkCommand::Await(args) => {
            let wait = match (args.reason, args.question) {
                (OwnerReason::Review, None) => OwnerWait::Review,
                (OwnerReason::Clarification, Some(question)) => OwnerWait::Clarification(
                    OwnerQuestion::parse(&question)
                        .map_err(|error| AppError::Invocation(error.to_string()))?,
                ),
                _ => {
                    return Err(AppError::Invocation(
                        "clarification requires --question TEXT; review has no question".into(),
                    ));
                }
            };
            (args.target, WorkAction::AwaitOwner(wait))
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
    let project = project()?;
    let lock = project.acquire_lock()?;
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
