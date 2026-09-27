//! Switch the public directory link without touching immutable versions.

use super::bundle::{directory, invalid};
use std::path::{Path, PathBuf};
use std::{fs, io};

pub fn selected(root: &Path, link: &Path) -> io::Result<Option<PathBuf>> {
    match fs::symlink_metadata(link) {
        Ok(_) => (),
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    }
    #[cfg(unix)]
    let target = fs::read_link(link)?;
    #[cfg(windows)]
    let target = junction::get_target(link)?;
    #[cfg(not(any(unix, windows)))]
    return Err(invalid("Directory links are unsupported on this platform"));
    let target = if target.is_absolute() {
        target
    } else {
        root.join(target)
    };
    let target = fs::canonicalize(target)?;
    let versions = fs::canonicalize(root.join("versions"))?;
    if target.parent() != Some(versions.as_path()) {
        return Err(invalid(
            "Refusing to replace a current link outside Isled's versions directory",
        ));
    }
    directory(&target)?;
    Ok(Some(target))
}

pub fn recover(root: &Path) -> io::Result<()> {
    let backup = root.join(".previous-current");
    if selected(root, &backup)?.is_some() {
        let current = root.join("current");
        if selected(root, &current)?.is_none() {
            fs::rename(&backup, current)?;
        } else {
            remove_link(&backup)?;
        }
    }
    Ok(())
}

fn remove_link(path: &Path) -> io::Result<()> {
    #[cfg(unix)]
    {
        fs::remove_file(path)
    }
    #[cfg(windows)]
    {
        fs::remove_dir(path)
    }
}

pub fn activate(root: &Path, destination: &Path) -> io::Result<()> {
    let current = root.join("current");
    let previous = selected(root, &current)?;
    if previous.as_deref() == Some(fs::canonicalize(destination)?.as_path()) {
        return Ok(());
    }
    let staging = tempfile::Builder::new()
        .prefix(".activate-")
        .tempdir_in(root)?;
    let next = staging.path().join("current");
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(destination, &next)?;
        fs::rename(next, current)
    }
    #[cfg(windows)]
    {
        junction::create(destination, &next)?;
        // Windows cannot replace an existing directory junction by rename.
        // Keep its old name until the new one is active; the next install
        // recovers an interrupted switch while holding the installation lock.
        let backup = root.join(".previous-current");
        if previous.is_some() {
            fs::rename(&current, &backup)?;
        }
        if let Err(error) = fs::rename(&next, &current) {
            if previous.is_some() {
                fs::rename(&backup, &current).map_err(|restore| {
                    invalid(format!("Activation failed ({error}); restoring current failed ({restore}); rerun install"))
                })?;
            }
            return Err(error);
        }
        if previous.is_some() {
            remove_link(&backup)?;
        }
        Ok(())
    }
}
