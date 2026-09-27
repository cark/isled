//! Local release installation, independent of ledgers and frontend state.

mod bundle;
mod current;

use bundle::{Bundle, directory, executable, invalid, invalid_json};
use serde::Serialize;
use std::fs::{self, OpenOptions};
use std::io;
use std::path::{Path, PathBuf};

#[derive(Serialize)]
pub struct Installation {
    schema_version: u32,
    pub root: PathBuf,
    pub version: Option<String>,
    pub program: Option<PathBuf>,
    pub executable: PathBuf,
    pub skill: PathBuf,
    pub skill_file: PathBuf,
    pub path_directory: PathBuf,
}

pub fn installation_root(explicit: Option<&Path>) -> io::Result<PathBuf> {
    let path = match explicit {
        Some(path) => path.to_owned(),
        None => dirs::data_local_dir()
            .ok_or_else(|| invalid("Cannot locate user data directory; specify --directory"))?
            .join("isled"),
    };
    std::path::absolute(path)
}

fn report(root: PathBuf, selected: Option<(String, PathBuf)>) -> Installation {
    let path_directory = root.join("current");
    let skill = path_directory.join("skill");
    let (version, program) = match selected {
        Some((version, directory)) => (Some(version), Some(directory.join(executable()))),
        None => (None, None),
    };
    Installation {
        schema_version: 1,
        root,
        version,
        program,
        executable: path_directory.join(executable()),
        skill_file: skill.join("SKILL.md"),
        skill,
        path_directory,
    }
}

pub fn inspect(explicit: Option<&Path>) -> io::Result<Installation> {
    let root = installation_root(explicit)?;
    let selection = current::selected(&root, &root.join("current"))?;
    let selected = match selection {
        Some(path) => {
            let bundle = Bundle::read(&path)?;
            bundle.verify(&path)?;
            if path.file_name() != Some(bundle.version.as_ref()) {
                return Err(invalid(
                    "Selected version directory does not match its bundle",
                ));
            }
            let path = root.join("versions").join(&bundle.version);
            Some((bundle.version, path))
        }
        None => None,
    };
    Ok(report(root, selected))
}

pub fn install(explicit: Option<&Path>) -> io::Result<Installation> {
    let program = fs::canonicalize(std::env::current_exe()?)?;
    let source = program
        .parent()
        .ok_or_else(|| invalid("Cannot locate the release bundle"))?;
    let bundle = Bundle::read(source).map_err(|error| invalid(format!(
        "Cannot load release bundle beside executable ({error}); extract the complete release archive. Cargo and Nix installations remain managed separately")))?;
    if bundle.version != crate::cli::VERSION || program.file_name() != Some(executable().as_ref()) {
        return Err(invalid(
            "Bundle identity does not match the running executable",
        ));
    }
    bundle.verify(source)?;
    install_bundle(source, &bundle, explicit)
}

fn install_bundle(
    source: &Path,
    bundle: &Bundle,
    explicit: Option<&Path>,
) -> io::Result<Installation> {
    let root = installation_root(explicit)?;
    // Check that structured output can represent the paths before changing storage.
    serde_json::to_vec(&report(root.clone(), None)).map_err(invalid_json)?;
    fs::create_dir_all(&root)?;
    directory(&root)?;
    let lock_path = root.join(".install.lock");
    if lock_path.try_exists()? {
        bundle::regular(&lock_path)?;
    }
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(lock_path)?;
    lock.try_lock().map_err(|error| {
        io::Error::other(format!("Installation is busy or cannot be locked: {error}"))
    })?;
    let versions = root.join("versions");
    fs::create_dir_all(&versions)?;
    directory(&versions)?;
    current::recover(&root)?;
    // Refuse unmanaged current paths before copying any release into the collection.
    current::selected(&root, &root.join("current"))?;
    let destination = versions.join(&bundle.version);
    if destination.try_exists()? || fs::symlink_metadata(&destination).is_ok() {
        let existing = Bundle::read(&destination)?;
        if &existing != bundle {
            return Err(invalid(
                "An installed bundle already uses this version with different contents",
            ));
        }
        existing.verify(&destination)?;
    } else {
        let stage = tempfile::Builder::new()
            .prefix(".install-")
            .tempdir_in(&versions)?;
        copy_bundle(source, stage.path(), bundle)?;
        bundle.verify(stage.path())?;
        fs::rename(stage.path(), &destination)?;
    }
    current::activate(&root, &destination)?;
    Ok(report(root, Some((bundle.version.clone(), destination))))
}

fn copy_bundle(source: &Path, stage: &Path, bundle: &Bundle) -> io::Result<()> {
    fs::create_dir_all(stage.join("skill/references"))?;
    for name in
        std::iter::once("bundle.json").chain(bundle.files.iter().map(|entry| entry.name.as_str()))
    {
        fs::copy(source.join(name), stage.join(name))?;
    }
    // A source changed while being copied must never publish a different manifest.
    if Bundle::read(stage)? != *bundle {
        return Err(invalid("Bundle changed during installation"));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(stage.join(executable()), fs::Permissions::from_mode(0o755))?;
    }
    Ok(())
}

impl Installation {
    pub fn output(&self, json: bool) -> io::Result<Vec<u8>> {
        if json {
            let mut output = serde_json::to_vec(self).map_err(invalid_json)?;
            output.push(b'\n');
            Ok(output)
        } else {
            Ok(format!("{}\nExecutable: {}\nSkill directory: {}\nSkill instructions: {}\nAdd to PATH: {}\nInstallation root: {}\nRetrieve paths with: isled installation\nFor custom storage, pass --directory with the installation root above.\n",
                self.version.as_ref().map_or_else(|| "No active managed installation".to_owned(), |version| format!("Isled {version} is ready")),
                self.executable.display(), self.skill.display(), self.skill_file.display(), self.path_directory.display(), self.root.display()).into_bytes())
        }
    }
}

#[cfg(all(
    test,
    any(
        all(target_os = "linux", target_arch = "x86_64"),
        all(target_os = "macos", target_arch = "aarch64"),
        all(target_os = "windows", target_arch = "x86_64")
    )
))]
mod tests;
