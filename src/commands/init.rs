use super::error::AppError;
use isled::filesystem::{self, FilesystemError};

pub(crate) fn run(roots: Vec<std::path::PathBuf>) -> Result<Vec<u8>, AppError> {
    let root = roots
        .last()
        .cloned()
        .unwrap_or(std::env::current_dir().map_err(FilesystemError::Io)?);
    let issues = filesystem::initialize_ledger(&root)?;
    Ok(format!("Initialized {}\n", issues.display()).into_bytes())
}
