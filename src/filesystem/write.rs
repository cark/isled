use super::FilesystemError;
use std::{
    fs::{self, OpenOptions},
    io::{self, Write},
    path::Path,
};

pub(super) fn write_new_file(path: &Path, bytes: &[u8], mode: u32) -> Result<(), FilesystemError> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    let mut file = options.open(path).map_err(|error| {
        if error.kind() == io::ErrorKind::AlreadyExists {
            FilesystemError::TemporaryExists
        } else {
            FilesystemError::Io(error)
        }
    })?;
    if let Err(error) = file.write_all(bytes) {
        drop(file);
        let _ = fs::remove_file(path);
        return Err(FilesystemError::Io(error));
    }
    drop(file);
    if let Err(error) = set_mode(path, mode) {
        let _ = fs::remove_file(path);
        return Err(error);
    }
    Ok(())
}

#[cfg(unix)]
fn set_mode(path: &Path, mode: u32) -> Result<(), FilesystemError> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(mode)).map_err(FilesystemError::Io)
}

#[cfg(not(unix))]
fn set_mode(_path: &Path, _mode: u32) -> Result<(), FilesystemError> {
    Ok(())
}
