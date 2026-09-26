use super::{
    FilesystemError, ProjectRoot, StoreEntry, StoreSnapshot, StoredHeader, StoredIdentity,
    StoredRecord,
    paths::{audit_name, require_regular_file, validated_name_bytes},
};
use crate::{
    ledger::{HighWater, Ledger},
    record::IssueRecord,
};
use std::{
    fs::{self, File},
    io::{BufRead, BufReader},
    path::Path,
};

impl ProjectRoot {
    pub fn load_ledger(&self) -> Result<Ledger, FilesystemError> {
        let issues = self.issues_dir();
        let counter = issues.join(".next-id");
        require_regular_file(&counter, true)?;
        let high_water = HighWater::parse(&fs::read(counter).map_err(FilesystemError::Io)?)?;

        let records = self.read_records()?;
        let parsed = records
            .into_iter()
            .map(|record| IssueRecord::parse(record.filename(), record.bytes().to_vec()))
            .collect::<Result<Vec<_>, _>>()?;
        Ledger::new(parsed, high_water).map_err(FilesystemError::Ledger)
    }

    /// Reads candidate records without imposing metadata or counter validity.
    pub fn read_records(&self) -> Result<Vec<StoredRecord>, FilesystemError> {
        self.read_records_matching(None)
    }

    pub fn read_issue_records(
        &self,
        id: crate::issue::IssueId,
    ) -> Result<Vec<StoredRecord>, FilesystemError> {
        self.read_records_matching(Some(id))
    }

    /// Reads only the heading and metadata needed by summary and relation queries.
    pub fn read_headers(&self) -> Result<Vec<StoredHeader>, FilesystemError> {
        let mut headers = Vec::new();
        for entry in self.issue_entries()? {
            let name = entry.file_name();
            let name_bytes = validated_name_bytes(&name)?;
            if !is_issue_candidate(name_bytes) {
                continue;
            }
            require_regular_file(&entry.path(), false)?;
            headers.push(StoredHeader::new(
                name_bytes.to_vec(),
                read_header(&entry.path())?,
            )?);
        }
        Ok(headers)
    }

    /// Reads canonical issue identities without opening record contents.
    pub fn read_identities(&self) -> Result<Vec<StoredIdentity>, FilesystemError> {
        identities(self.issue_entries()?.iter())
    }

    /// Reads every direct store entry for the read-only integrity audit.
    pub fn audit_snapshot(&self) -> Result<StoreSnapshot, FilesystemError> {
        let issues = self.issues_dir();
        let mut directory_entries = fs::read_dir(&issues)
            .map_err(FilesystemError::Io)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(FilesystemError::Io)?;
        directory_entries.sort_by_key(|entry| entry.file_name());

        let mut entries = Vec::new();
        for entry in directory_entries {
            let name = entry.file_name();
            let (name_bytes, filename_is_utf8) = audit_name(&name);
            if matches!(
                name_bytes.as_slice(),
                b".next-id" | b".pre-structured-markdown" | b".cache"
            ) {
                continue;
            }
            require_regular_file(&entry.path(), false)?;
            entries.push(StoreEntry {
                filename: name_bytes,
                filename_is_utf8,
                bytes: fs::read(entry.path()).map_err(FilesystemError::Io)?,
            });
        }

        let counter = issues.join(".next-id");
        let high_water = if counter.exists() || counter.is_symlink() {
            require_regular_file(&counter, true)?;
            Some(fs::read(counter).map_err(FilesystemError::Io)?)
        } else {
            None
        };
        Ok(StoreSnapshot {
            entries,
            high_water,
        })
    }

    fn read_records_matching(
        &self,
        wanted: Option<crate::issue::IssueId>,
    ) -> Result<Vec<StoredRecord>, FilesystemError> {
        self.read_records_with(wanted, |name, path| {
            require_regular_file(path, false)?;
            StoredRecord::new(name.to_vec(), fs::read(path).map_err(FilesystemError::Io)?)
        })
    }

    pub(super) fn read_records_with(
        &self,
        wanted: Option<crate::issue::IssueId>,
        mut load: impl FnMut(&[u8], &Path) -> Result<StoredRecord, FilesystemError>,
    ) -> Result<Vec<StoredRecord>, FilesystemError> {
        let wanted = wanted.map(|id| id.to_string());
        let mut records = Vec::new();
        for entry in self.issue_entries()? {
            let name = entry.file_name();
            let name_bytes = validated_name_bytes(&name)?;
            if !is_issue_candidate(name_bytes) {
                continue;
            }
            if wanted
                .as_ref()
                .is_some_and(|id| &name_bytes[..4] != id.as_bytes())
            {
                continue;
            }
            records.push(load(name_bytes, &entry.path())?);
        }
        Ok(records)
    }

    pub(super) fn issue_entries(&self) -> Result<Vec<fs::DirEntry>, FilesystemError> {
        let mut entries = fs::read_dir(self.issues_dir())
            .map_err(FilesystemError::Io)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(FilesystemError::Io)?;
        entries.sort_by_key(|entry| entry.file_name());
        Ok(entries)
    }
}
pub(super) fn identities<'a>(
    entries: impl IntoIterator<Item = &'a fs::DirEntry>,
) -> Result<Vec<StoredIdentity>, FilesystemError> {
    let mut identities = Vec::new();
    for entry in entries {
        let name = entry.file_name();
        let name_bytes = validated_name_bytes(&name)?;
        if !is_issue_candidate(name_bytes) {
            continue;
        }
        let kind = entry.file_type().map_err(FilesystemError::Io)?;
        if !kind.is_file() || kind.is_symlink() {
            return Err(FilesystemError::UnsafeIssuePath);
        }
        identities.push(StoredIdentity::new(name_bytes.to_vec())?);
    }
    Ok(identities)
}

fn read_header(path: &Path) -> Result<Vec<u8>, FilesystemError> {
    let mut reader = BufReader::new(File::open(path).map_err(FilesystemError::Io)?);
    let mut output = Vec::new();
    let mut line = Vec::new();
    loop {
        line.clear();
        let read = reader
            .read_until(b'\n', &mut line)
            .map_err(FilesystemError::Io)?;
        if read == 0 {
            break;
        }
        output.extend_from_slice(&line);
        let content = line.strip_suffix(b"\n").unwrap_or(&line);
        let content = content.strip_suffix(b"\r").unwrap_or(content);
        if content == b"## Statement" {
            break;
        }
    }
    Ok(output)
}
fn is_issue_candidate(name: &[u8]) -> bool {
    name.len() >= 8
        && name[..4].iter().all(u8::is_ascii_digit)
        && name.get(4) == Some(&b'-')
        && name.ends_with(b".md")
}
