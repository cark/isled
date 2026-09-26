use super::cached_read::with_cached_query;
use super::error::AppError;
use super::issue_id::parse_issue_id;
use isled::filesystem::{FilesystemError, ProjectRoot};

pub(crate) fn run(
    arguments: isled::cli::PathArgs,
    root: impl FnOnce() -> Result<ProjectRoot, FilesystemError>,
) -> Result<Vec<u8>, AppError> {
    let project = root()?;
    let ids = arguments
        .ids
        .iter()
        .map(|value| parse_issue_id(value))
        .collect::<Result<Vec<_>, _>>()?;
    project.ensure_tsv_output_path()?;
    with_cached_query(&project, |cache| {
        let mut output = Vec::new();
        for id in &ids {
            let name = cache.filename(*id)?;
            let kind = std::fs::symlink_metadata(project.issues_dir().join(&name))
                .map_err(AppError::Io)?
                .file_type();
            if !kind.is_file() || kind.is_symlink() {
                return Err(FilesystemError::UnsafeIssuePath.into());
            }
            output.extend_from_slice(format!("{id}\t").as_bytes());
            output.extend(project.issue_path_bytes(name.as_bytes())?);
            output.push(b'\n');
        }
        Ok(output)
    })
}
