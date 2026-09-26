//! One versioned complete-draft request over stdin/stdout.
use super::error::AppError;
use isled::filesystem::{FilesystemError, ProjectRoot};
use std::io::{self, Read};
pub(crate) fn run(
    root: impl FnOnce() -> Result<ProjectRoot, FilesystemError>,
) -> Result<Vec<u8>, AppError> {
    let mut input = Vec::new();
    io::stdin().read_to_end(&mut input).map_err(AppError::Io)?;
    let mut output = serde_json::to_vec(&isled::editor::respond(&root()?, &input))?;
    output.push(b'\n');
    Ok(output)
}
