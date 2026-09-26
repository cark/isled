//! Issue contents and failures retained for one held-lock lifetime.
use super::contents::{self, FileContents, ReadFailure};
use super::{FilesystemError, ProjectRoot, StoredRecord};
use std::{
    cell::{Cell, RefCell},
    collections::BTreeMap,
    fs, io,
    rc::Rc,
};

#[derive(Default)]
pub(super) struct LoadedIssues {
    entries: RefCell<BTreeMap<Vec<u8>, Result<LoadedFile, LoadFailure>>>,
    reads: Cell<usize>,
}

#[derive(Clone)]
pub(crate) struct LoadedFile {
    record: Result<StoredRecord, Rc<io::Error>>,
    pub(crate) metadata: Result<fs::Metadata, Rc<io::Error>>,
}

#[derive(Clone)]
enum LoadFailure {
    Unsafe,
    Io(Rc<io::Error>),
}

impl LoadFailure {
    fn filesystem_error(&self) -> FilesystemError {
        match self {
            Self::Unsafe => FilesystemError::UnsafeIssuePath,
            Self::Io(error) => FilesystemError::Io(match error.raw_os_error() {
                Some(code) => io::Error::from_raw_os_error(code),
                None => io::Error::new(error.kind(), error.to_string()),
            }),
        }
    }
}

impl From<ReadFailure> for LoadFailure {
    fn from(error: ReadFailure) -> Self {
        match error {
            ReadFailure::Unsafe => Self::Unsafe,
            ReadFailure::Io(error) => Self::Io(Rc::new(error)),
        }
    }
}

impl LoadedIssues {
    pub(super) fn get(
        &self,
        root: &ProjectRoot,
        filename: &[u8],
    ) -> Result<LoadedFile, FilesystemError> {
        if let Some(entry) = self.entries.borrow().get(filename) {
            return entry.clone().map_err(|error| error.filesystem_error());
        }
        self.remember(filename, contents::load(root, filename));
        self.entries.borrow()[filename]
            .clone()
            .map_err(|error| error.filesystem_error())
    }

    pub(super) fn contains(&self, filename: &[u8]) -> bool {
        self.entries.borrow().contains_key(filename)
    }

    pub(super) fn remember(&self, filename: &[u8], contents: Result<FileContents, ReadFailure>) {
        let entry = contents
            .map(|contents| {
                self.reads.set(self.reads.get() + 1);
                LoadedFile {
                    metadata: Ok(contents.metadata),
                    record: contents
                        .bytes
                        .map(|bytes| StoredRecord::from_bytes(filename.to_vec(), bytes))
                        .map_err(Rc::new),
                }
            })
            .map_err(LoadFailure::from);
        self.entries.borrow_mut().insert(filename.to_vec(), entry);
    }

    /// Called only after this replacement's rename succeeded. A metadata failure
    /// cannot undo publication or justify reading its contents again.
    pub(super) fn published(&self, root: &ProjectRoot, record: &StoredRecord) {
        let path = root
            .issues_dir()
            .join(std::str::from_utf8(record.filename()).expect("checked filename"));
        let metadata = fs::symlink_metadata(path).map_err(Rc::new);
        self.entries.borrow_mut().insert(
            record.filename().to_vec(),
            Ok(LoadedFile {
                record: Ok(record.clone()),
                metadata,
            }),
        );
    }

    pub(super) fn reads(&self) -> usize {
        self.reads.get()
    }
}

impl LoadedFile {
    pub(crate) fn record(&self) -> Result<StoredRecord, FilesystemError> {
        self.record
            .clone()
            .map_err(|error| LoadFailure::Io(error).filesystem_error())
    }
}
