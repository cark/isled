use super::content_publication::publish_content;
use super::error::AppError;
use super::issue_id::parse_issue_id;
use isled::cli::EvidenceCommand;
use isled::filesystem::{FilesystemError, ProjectRoot};
use isled::mutation::{self, SectionText};

pub(crate) fn run(
    arguments: isled::cli::EvidenceArgs,
    root: impl FnOnce() -> Result<ProjectRoot, FilesystemError>,
) -> Result<Vec<u8>, AppError> {
    match arguments.command {
        EvidenceCommand::Add(arguments) => {
            let id = parse_issue_id(&arguments.issue)?;
            let entries = arguments
                .text
                .iter()
                .map(|value| {
                    SectionText::try_parse(value).map_err(|_| {
                        AppError::Invocation("evidence text must be one non-empty line".into())
                    })
                })
                .collect::<Result<Vec<_>, _>>()?;
            let project = root()?;
            let lock = project.acquire_lock()?;
            let records = lock.read_issue_records(id)?;
            let plan = mutation::evidence_add(&records, id, &entries)?;
            publish_content(lock, &records, id, &plan)?;
            Ok(format!("added evidence to issue {id}\n").into_bytes())
        }
    }
}
