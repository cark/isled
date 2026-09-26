use super::super::error::AppError;
use super::super::issue_id::parse_issue_id;
use super::super::selected_records::read_selected_records;
use isled::filesystem::{FilesystemError, ProjectRoot};
use isled::mutation;

pub(super) fn run(
    arguments: isled::cli::WaitRemoveArgs,
    root: impl FnOnce() -> Result<ProjectRoot, FilesystemError>,
) -> Result<Vec<u8>, AppError> {
    let source = parse_issue_id(&arguments.issue)?;
    let target = parse_issue_id(&arguments.blocker)?;
    let project = root()?;
    let lock = project.acquire_lock()?;
    let records = read_selected_records(&lock, [source, target])?;
    let plan = mutation::wait_remove(&records, source, target)?;
    lock.publish(&plan)?;
    lock.finish()?;
    Ok(format!("removed wait on {target} from issue {source}\n").into_bytes())
}
