use super::content_publication::publish_content;
use super::error::AppError;
use super::issue_id::parse_issue_id;
use super::selected_records::read_selected_records;
use isled::cache::Cache;
use isled::cli::TitleSetArgs;
use isled::filesystem::{FilesystemError, ProjectRoot};
use isled::mutation::{self, TitleText};

pub(crate) fn run(
    arguments: TitleSetArgs,
    project: impl FnOnce() -> Result<ProjectRoot, FilesystemError>,
) -> Result<Vec<u8>, AppError> {
    let id = parse_issue_id(&arguments.issue)?;
    let title = TitleText::parse(&arguments.title)
        .map_err(|error| AppError::Invocation(error.to_string()))?;
    let project = project()?;
    let lock = project.acquire_lock()?;
    let mut cache = Cache::open(&lock)?;
    cache.refresh(Some(id))?;
    let participants = cache.title_participants(id)?;
    cache.report_warnings();
    drop(cache);
    let records = read_selected_records(&lock, participants)?;
    let plan = mutation::title_set(&records, id, &title)?;
    publish_content(lock, &records, id, &plan)?;
    Ok(format!("set title for issue {id}\n").into_bytes())
}
