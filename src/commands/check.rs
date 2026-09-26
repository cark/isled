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
    let report = check::audit(&snapshot);
    if report.has_findings() {
        Err(AppError::CheckFindings(report.render()))
    } else {
        Ok(Vec::new())
    }
}
