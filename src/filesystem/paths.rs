use super::FilesystemError;
use crate::record::RecordError;
use std::{ffi::OsStr, fs, path::Path};

pub(super) fn validated_name_bytes(name: &OsStr) -> Result<&[u8], FilesystemError> {
    let bytes = os_bytes(name).ok_or(FilesystemError::InvalidFilenameEncoding)?;
    if std::str::from_utf8(bytes).is_err() {
        return Err(FilesystemError::InvalidRecordEncoding {
            filename: bytes.to_vec(),
            error: RecordError::InvalidFilenameEncoding,
        });
    }
    Ok(bytes)
}
#[cfg(unix)]
pub(super) fn os_name(bytes: &[u8]) -> Result<std::ffi::OsString, FilesystemError> {
    use std::os::unix::ffi::OsStringExt;
    Ok(std::ffi::OsString::from_vec(bytes.to_vec()))
}

#[cfg(not(unix))]
pub(super) fn os_name(bytes: &[u8]) -> Result<std::ffi::OsString, FilesystemError> {
    String::from_utf8(bytes.to_vec())
        .map(std::ffi::OsString::from)
        .map_err(|_| FilesystemError::InvalidFilenameEncoding)
}

pub(super) fn require_regular_file(path: &Path, counter: bool) -> Result<(), FilesystemError> {
    let metadata = fs::symlink_metadata(path).map_err(FilesystemError::Io)?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(if counter {
            FilesystemError::UnsafeHighWater
        } else {
            FilesystemError::UnsafeIssuePath
        });
    }
    Ok(())
}
#[cfg(unix)]
pub(super) fn audit_name(value: &OsStr) -> (Vec<u8>, bool) {
    use std::os::unix::ffi::OsStrExt;
    let bytes = value.as_bytes().to_vec();
    let valid = std::str::from_utf8(&bytes).is_ok();
    (bytes, valid)
}

#[cfg(not(unix))]
pub(super) fn audit_name(value: &OsStr) -> (Vec<u8>, bool) {
    match value.to_str() {
        Some(text) => (text.as_bytes().to_vec(), true),
        None => (value.to_string_lossy().into_owned().into_bytes(), false),
    }
}
#[cfg(unix)]
pub(super) fn os_bytes(value: &OsStr) -> Option<&[u8]> {
    use std::os::unix::ffi::OsStrExt;
    Some(value.as_bytes())
}

#[cfg(not(unix))]
pub(super) fn os_bytes(value: &OsStr) -> Option<&[u8]> {
    value.to_str().map(str::as_bytes)
}
