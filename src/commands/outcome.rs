use super::content_publication::publish_content;
use super::error::AppError;
use super::issue_id::parse_issue_id;
use isled::cli::ContentTextArgs;
use isled::filesystem::{FilesystemError, ProjectRoot};
use isled::mutation::{self, SectionText};

pub(crate) fn run(
    arguments: ContentTextArgs,
    project: impl FnOnce() -> Result<ProjectRoot, FilesystemError>,
) -> Result<Vec<u8>, AppError> {
    let id = parse_issue_id(&arguments.issue)?;
    let text = SectionText::try_parse(&arguments.text)
        .map_err(|_| AppError::Invocation("outcome must be one non-empty line".into()))?;
    let project = project()?;
    let lock = project.acquire_lock()?;
    let records = lock.read_issue_records(id)?;
    let plan = mutation::outcome_set(&records, id, &text)?;
    publish_content(lock, &records, id, &plan)?;
    Ok(format!("set outcome for issue {id}\n").into_bytes())
}
