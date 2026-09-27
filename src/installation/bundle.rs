//! Verification of the complete, immutable release payload.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;
use std::fs::{self, File};
use std::io::{self, Read};
use std::path::Path;

pub const SKILL_FILES: [&str; 3] = [
    "skill/SKILL.md",
    "skill/references/mutations.md",
    "skill/references/recovery.md",
];

#[derive(Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct FileEntry {
    pub name: String,
    pub size: u64,
    pub sha256: String,
}

#[derive(Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Bundle {
    pub schema_version: u32,
    pub version: String,
    pub target: String,
    pub files: Vec<FileEntry>,
}

pub fn invalid(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.into())
}

pub fn executable() -> &'static str {
    if cfg!(windows) { "isled.exe" } else { "isled" }
}

pub fn target() -> io::Result<&'static str> {
    if cfg!(all(target_os = "linux", target_arch = "x86_64")) {
        Ok("x86_64-unknown-linux-musl")
    } else if cfg!(all(target_os = "macos", target_arch = "aarch64")) {
        Ok("aarch64-apple-darwin")
    } else if cfg!(all(target_os = "windows", target_arch = "x86_64")) {
        Ok("x86_64-pc-windows-msvc")
    } else {
        Err(invalid(
            "Managed installation is unavailable for this platform; use a source installation",
        ))
    }
}

pub fn regular(path: &Path) -> io::Result<fs::Metadata> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.file_type().is_file() {
        return Err(invalid(format!(
            "Expected a regular bundle file: {}",
            path.display()
        )));
    }
    Ok(metadata)
}

pub fn directory(path: &Path) -> io::Result<()> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.file_type().is_dir() {
        return Err(invalid(format!(
            "Expected a non-link directory: {}",
            path.display()
        )));
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if metadata.file_attributes() & 0x400 != 0 {
            return Err(invalid(format!(
                "Unexpected reparse point: {}",
                path.display()
            )));
        }
    }
    Ok(())
}

pub fn digest(path: &Path) -> io::Result<String> {
    let mut input = File::open(path)?;
    let mut hash = Sha256::new();
    let mut buffer = [0; 65536];
    loop {
        let count = input.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        hash.update(&buffer[..count]);
    }
    let mut output = String::with_capacity(64);
    let digits = b"0123456789abcdef";
    for byte in hash.finalize() {
        output.push(digits[(byte >> 4) as usize] as char);
        output.push(digits[(byte & 15) as usize] as char);
    }
    Ok(output)
}

impl Bundle {
    pub fn read(root: &Path) -> io::Result<Self> {
        directory(root)?;
        let path = root.join("bundle.json");
        if regular(&path)?.len() > 65536 {
            return Err(invalid("Bundle manifest exceeds 64 KiB"));
        }
        let bundle: Self = serde_json::from_slice(&fs::read(path)?).map_err(invalid_json)?;
        bundle.validate()?;
        Ok(bundle)
    }

    pub(super) fn validate(&self) -> io::Result<()> {
        let version = self.version.strip_suffix("-dev").unwrap_or(&self.version);
        let parts: Vec<_> = version.split('.').collect();
        if self.schema_version != 1
            || parts.len() != 3
            || parts
                .iter()
                .any(|part| part.is_empty() || !part.bytes().all(|byte| byte.is_ascii_digit()))
            || self.target != target()?
        {
            return Err(invalid(
                "Bundle version, schema or platform does not match this installer",
            ));
        }
        let expected: BTreeSet<_> = [executable(), "LICENSE"]
            .into_iter()
            .chain(SKILL_FILES)
            .collect();
        let mut found = BTreeSet::new();
        for entry in &self.files {
            let limit = if entry.name == executable() {
                128 * 1024 * 1024
            } else {
                1024 * 1024
            };
            if !expected.contains(entry.name.as_str())
                || !found.insert(entry.name.as_str())
                || entry.size == 0
                || entry.size > limit
                || entry.sha256.len() != 64
                || !entry
                    .sha256
                    .bytes()
                    .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
            {
                return Err(invalid(
                    "Unexpected, duplicate or invalid bundle file descriptor",
                ));
            }
        }
        if expected != found {
            return Err(invalid("Incomplete executable and skill bundle"));
        }
        Ok(())
    }

    pub fn verify(&self, root: &Path) -> io::Result<()> {
        directory(root)?;
        directory(&root.join("skill"))?;
        directory(&root.join("skill/references"))?;
        for entry in &self.files {
            let path = root.join(&entry.name);
            if regular(&path)?.len() != entry.size || digest(&path)? != entry.sha256 {
                return Err(invalid(format!(
                    "Bundle checksum or size mismatch: {}",
                    entry.name
                )));
            }
        }
        Ok(())
    }
}

pub fn invalid_json(error: serde_json::Error) -> io::Error {
    invalid(error.to_string())
}
