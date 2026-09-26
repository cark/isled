use super::error::AppError;
use super::issue_id::parse_issue_id;
use isled::cli::PriorityCommand;
use isled::filesystem::{FilesystemError, ProjectRoot};
use isled::issue::Tag;
use isled::mutation::{self, PriorityOutcome};

pub(crate) fn run(
    command: PriorityCommand,
    project: impl FnOnce() -> Result<ProjectRoot, FilesystemError>,
) -> Result<Vec<u8>, AppError> {
    match command {
        PriorityCommand::Set(arguments) => {
            let id = parse_issue_id(&arguments.issue)?;
            let tag_text = match arguments.level.as_str() {
                "high" => "priority-high",
                "normal" => "priority-normal",
                "low" => "priority-low",
                _ => {
                    return Err(AppError::Invocation(format!(
                        "unknown priority level: {} (use high, normal, or low)",
                        arguments.level
                    )));
                }
            };
            let tag = Tag::parse(tag_text.as_bytes()).expect("static valid priority");
            let project = project()?;
            let lock = project.acquire_lock()?;
            let records = lock.read_issue_records(id)?;
            let (plan, outcome) = mutation::priority_set(&records, id, &tag)?;
            lock.publish(&plan)?;
            lock.finish()?;
            Ok(match outcome {
                PriorityOutcome::Changed => {
                    format!("set priority for issue {id} to {}\n", arguments.level)
                }
                PriorityOutcome::AlreadySet => {
                    format!("priority for issue {id} is already {}\n", arguments.level)
                }
            }
            .into_bytes())
        }
        PriorityCommand::Clear(arguments) => {
            let id = parse_issue_id(&arguments.id)?;
            let project = project()?;
            let lock = project.acquire_lock()?;
            let records = lock.read_issue_records(id)?;
            let plan = mutation::priority_clear(&records, id)?;
            lock.publish(&plan)?;
            lock.finish()?;
            Ok(format!("cleared priority for issue {id}\n").into_bytes())
        }
    }
}
