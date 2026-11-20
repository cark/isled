use super::error::AppError;
use isled::check;
use isled::cli::CheckArgs;
use isled::filesystem::{FilesystemError, ProjectRoot};

pub(crate) fn run(
    arguments: CheckArgs,
    project: impl FnOnce() -> Result<ProjectRoot, FilesystemError>,
) -> Result<Vec<u8>, AppError> {
    if !arguments.unexpected.is_empty() {
        return Err(AppError::CheckOperational(
            "check accepts no arguments".into(),
        ));
    }
    let project = project().map_err(|error| AppError::CheckOperational(error.to_string()))?;
    let snapshot = project
        .audit_snapshot()
        .map_err(|error| AppError::CheckOperational(error.to_string()))?;
    let workflow = isled::workflow::Workflow::read(&project)
        .map_err(|e| AppError::CheckOperational(e.to_string()))?
        .0;
    let report = check::audit_with_workflow(&snapshot, Some(&workflow));
    if report.has_findings() {
        Err(AppError::CheckFindings(report.render()))
    } else {
        Ok(Vec::new())
    }
}
