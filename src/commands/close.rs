use super::error::AppError;
use super::issue_id::parse_issue_id;
use isled::cli::CloseArgs;
use isled::filesystem::{FilesystemError, ProjectRoot};
use isled::mutation::{self, SectionText};

pub(crate) fn run(
    arguments: CloseArgs,
    project: impl FnOnce() -> Result<ProjectRoot, FilesystemError>,
) -> Result<Vec<u8>, AppError> {
    let id = parse_issue_id(&arguments.id)?;
    let outcome = arguments
        .outcome
        .last()
        .map(|value| {
            SectionText::try_parse(value)
                .map_err(|_| AppError::Invocation("outcome must be one non-empty line".into()))
        })
        .transpose()?;
    let project = project()?;
    let lock = project.acquire_lock()?;
    let records = lock.read_issue_records(id)?;
    let closure = mutation::close_issue(&records, id, outcome.as_ref())?;
    lock.publish(&closure.plan)?;
    lock.finish()?;
    let message = if closure.was_closed {
        format!("issue {id} was already closed\n")
    } else {
        format!("closed {id}\n")
    };
    Ok(message.into_bytes())
}
