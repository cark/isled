use super::error::AppError;
use isled::issue::IssueId;
use isled::{filesystem, mutation};

pub(crate) fn publish_content(
    lock: filesystem::StoreLock<'_>,
    records: &[filesystem::StoredRecord],
    id: IssueId,
    plan: &mutation::MutationPlan,
) -> Result<(), AppError> {
    let warn = mutation::changes_closed_issue(records, id, plan)?;
    lock.publish(plan)?;
    lock.finish()?;
    if warn {
        eprintln!("warning: issue {id} is closed; updating historical record");
    }
    Ok(())
}
