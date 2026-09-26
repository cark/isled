use super::{
    FilesystemError,
    paths::{os_bytes, os_name},
};
use std::{
    fs, io,
    path::{Path, PathBuf},
};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProjectRoot {
    pub(super) path: PathBuf,
    pub(super) cache_cleanup: CacheCleanup,
}

/// Reclamation policy for loaded records; filesystem locks are always released.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum CacheCleanup {
    #[default]
    Drop,
    /// Skip cache destructors only when the caller will soon exit its process.
    LeaveToProcessExit,
}

impl ProjectRoot {
    pub fn discover(start: &Path) -> Result<Self, FilesystemError> {
        let mut candidate = start.canonicalize().map_err(FilesystemError::Io)?;
        if !candidate.is_dir() {
            return Err(FilesystemError::RootDoesNotExist);
        }
        loop {
            if candidate.join(".issues").is_dir() {
                return Self::from_canonical(candidate);
            }
            if !candidate.pop() {
                return Err(FilesystemError::NotInitialized);
            }
        }
    }

    pub fn explicit(path: &Path) -> Result<Self, FilesystemError> {
        let canonical = path.canonicalize().map_err(|error| {
            if error.kind() == io::ErrorKind::NotFound {
                FilesystemError::RootDoesNotExist
            } else {
                FilesystemError::Io(error)
            }
        })?;
        if !canonical.is_dir() {
            return Err(FilesystemError::RootDoesNotExist);
        }
        Self::from_canonical(canonical)
    }

    fn from_canonical(path: PathBuf) -> Result<Self, FilesystemError> {
        let issues = path.join(".issues");
        if !issues.is_dir() {
            return Err(FilesystemError::NotInitialized);
        }
        if fs::symlink_metadata(&issues)
            .map_err(FilesystemError::Io)?
            .file_type()
            .is_symlink()
        {
            return Err(FilesystemError::SymlinkedStore);
        }
        Ok(Self {
            path,
            cache_cleanup: CacheCleanup::Drop,
        })
    }

    pub fn with_cache_cleanup(mut self, cleanup: CacheCleanup) -> Self {
        self.cache_cleanup = cleanup;
        self
    }

    pub fn as_path(&self) -> &Path {
        &self.path
    }

    pub fn path_bytes_lossless(&self) -> Result<&[u8], FilesystemError> {
        os_bytes(self.path.as_os_str()).ok_or(FilesystemError::InvalidFilenameEncoding)
    }

    pub fn issues_dir(&self) -> PathBuf {
        self.path.join(".issues")
    }

    pub fn ensure_tsv_output_path(&self) -> Result<(), FilesystemError> {
        let path = self.issues_dir();
        let bytes = os_bytes(path.as_os_str()).ok_or(FilesystemError::InvalidFilenameEncoding)?;
        if bytes.contains(&b'\t') || bytes.contains(&b'\n') {
            Err(FilesystemError::UnrepresentableTsvPath)
        } else {
            Ok(())
        }
    }

    pub fn issue_path_bytes(&self, filename: &[u8]) -> Result<Vec<u8>, FilesystemError> {
        self.ensure_tsv_output_path()?;
        self.issue_path_bytes_lossless(filename)
    }

    pub fn issue_path_bytes_lossless(&self, filename: &[u8]) -> Result<Vec<u8>, FilesystemError> {
        let path = self.issues_dir().join(os_name(filename)?);
        let bytes = os_bytes(path.as_os_str()).ok_or(FilesystemError::InvalidFilenameEncoding)?;
        Ok(bytes.to_vec())
    }

    pub(crate) fn cache_dir(&self) -> Result<PathBuf, FilesystemError> {
        let path = self.issues_dir().join(".cache");
        match fs::create_dir(&path) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(FilesystemError::Io(error)),
        }
        let metadata = fs::symlink_metadata(&path).map_err(FilesystemError::Io)?;
        if !metadata.is_dir() || metadata.file_type().is_symlink() {
            return Err(FilesystemError::UnsafeIssuePath);
        }
        Ok(path)
    }
}
