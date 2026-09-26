use super::super::error::AppError;
use super::super::issue_id::parse_issue_id;
use super::super::selected_records::read_selected_records;
use isled::filesystem::{FilesystemError, ProjectRoot};
use isled::{cache::Cache, issue::WaitReason, mutation};

pub(super) fn run(
    arguments: isled::cli::WaitAddArgs,
    root: impl FnOnce() -> Result<ProjectRoot, FilesystemError>,
) -> Result<Vec<u8>, AppError> {
    let source = parse_issue_id(&arguments.issue)?;
    let target = parse_issue_id(&arguments.blocker)?;
    let reason = WaitReason::parse(arguments.reason.as_bytes())
        .map_err(|error| AppError::Invocation(error.to_string()))?;
    let project = root()?;
    let lock = project.acquire_lock()?;
    let records = read_selected_records(&lock, [source, target])?;
    let mut cache = Cache::open(&lock)?;
    cache.refresh(Some(source))?;
    cache.refresh(Some(target))?;
    let graph = cache.adjacency()?;
    cache.report_warnings();
    drop(cache);
    let plan = mutation::wait_add_indexed(&records, &graph, source, target, &reason)?;
    lock.publish(&plan)?;
    lock.finish()?;
    Ok(format!("issue {source} now waits on {target}\n").into_bytes())
}
