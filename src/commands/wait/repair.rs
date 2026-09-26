use super::super::error::AppError;
use super::super::issue_id::parse_issue_id;
use isled::filesystem::{FilesystemError, ProjectRoot};
use isled::mutation;

pub(super) fn run(
    action: isled::cli::RepairAction,
    issue: String,
    blocker: String,
    reason: Option<String>,
    root: impl FnOnce() -> Result<ProjectRoot, FilesystemError>,
) -> Result<Vec<u8>, AppError> {
    let source = parse_issue_id(&issue)?;
    let target = parse_issue_id(&blocker)?;
    if source == target {
        return Err(AppError::Invocation(
            "self relation repair requires manual inspection".into(),
        ));
    }
    let complete = matches!(action, isled::cli::RepairAction::Complete);
    let reason = reason
        .as_deref()
        .map(|r| isled::issue::WaitReason::parse(r.as_bytes()))
        .transpose()
        .map_err(|e| AppError::Invocation(e.to_string()))?;
    let project = root()?;
    let lock = project.acquire_lock()?;
    let mut records = Vec::new();
    for id in [source, target] {
        let found = lock.read_issue_records(id)?;
        if found.len() > 1 {
            return Err(AppError::Invocation(format!("ambiguous issue {id}")));
        }
        for record in found {
            if record.issue().is_ok() {
                records.push(record);
            } else if complete {
                return Err(AppError::Invocation(format!(
                    "cannot complete relation with unreadable issue {id}"
                )));
            }
        }
    }
    let plan = mutation::relation_repair(&records, source, target, complete, reason.as_ref())?;
    lock.publish(&plan)?;
    lock.finish()?;
    Ok(format!(
        "{} relation {source} waits on {target}\n",
        if complete { "completed" } else { "removed" }
    )
    .into_bytes())
}
