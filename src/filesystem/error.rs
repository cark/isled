use crate::{ledger::LedgerError, record::RecordError};
use std::{error::Error, fmt, io};

#[derive(Debug)]
pub enum FilesystemError {
    RootDoesNotExist,
    NotInitialized,
    SymlinkedStore,
    UnsafeHighWater,
    UnsafeIssuePath,
    UnsafeGitignore,
    NotDirectory,
    Locked,
    TemporaryExists,
    DestinationExists,
    UnexpectedCreationId {
        expected: crate::issue::IssueId,
        actual: crate::issue::IssueId,
    },
    InvalidFilenameEncoding,
    InvalidRecordEncoding {
        filename: Vec<u8>,
        error: RecordError,
    },
    UnrepresentableTsvPath,
    Io(io::Error),
    Record(RecordError),
    Ledger(LedgerError),
}

impl fmt::Display for FilesystemError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::RootDoesNotExist => write!(formatter, "root does not exist"),
            Self::NotInitialized => write!(formatter, "no initialized issue store found"),
            Self::SymlinkedStore => write!(formatter, "issue directory must not be a symlink"),
            Self::UnsafeHighWater => write!(formatter, "invalid next-ID state"),
            Self::UnsafeIssuePath => {
                write!(formatter, "issue path must be a regular non-symlink file")
            }
            Self::UnsafeGitignore => write!(formatter, ".gitignore must be a regular file"),
            Self::NotDirectory => write!(formatter, ".issues is not a directory"),
            Self::Locked => write!(formatter, "issue store is locked"),
            Self::TemporaryExists => write!(formatter, "temporary path already exists"),
            Self::DestinationExists => write!(formatter, "issue path already exists"),
            Self::UnexpectedCreationId { expected, actual } => write!(
                formatter,
                "creation ID {actual} does not match next ID {expected}"
            ),
            Self::InvalidFilenameEncoding => write!(formatter, "invalid filename encoding"),
            Self::InvalidRecordEncoding { filename, error } => write!(
                formatter,
                "cannot read issue {}: {error}",
                display_filename(filename)
            ),
            Self::UnrepresentableTsvPath => {
                write!(formatter, "issue path cannot be represented as TSV")
            }
            Self::Io(error) => error.fmt(formatter),
            Self::Record(error) => error.fmt(formatter),
            Self::Ledger(error) => error.fmt(formatter),
        }
    }
}

impl Error for FilesystemError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Io(error) => Some(error),
            Self::Record(error) => Some(error),
            Self::InvalidRecordEncoding { error, .. } => Some(error),
            Self::Ledger(error) => Some(error),
            _ => None,
        }
    }
}

impl From<RecordError> for FilesystemError {
    fn from(error: RecordError) -> Self {
        Self::Record(error)
    }
}

impl From<LedgerError> for FilesystemError {
    fn from(error: LedgerError) -> Self {
        Self::Ledger(error)
    }
}
fn display_filename(filename: &[u8]) -> String {
    if let Ok(text) = std::str::from_utf8(filename) {
        return text.to_owned();
    }
    let mut output = String::new();
    for byte in filename {
        if byte.is_ascii_graphic() && *byte != b'\\' {
            output.push(char::from(*byte));
        } else {
            output.push_str(&format!("\\x{byte:02X}"));
        }
    }
    output
}
