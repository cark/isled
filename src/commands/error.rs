use isled::cache::CacheError;
use isled::filesystem::FilesystemError;
use isled::mutation::MutationError;
use isled::query::QueryError;
use isled::snapshot::SnapshotError;
use std::error::Error;
use std::{fmt, io};

#[derive(Debug)]
pub(crate) enum AppError {
    Cache(CacheError),
    Invocation(String),
    Filesystem(FilesystemError),
    Query(QueryError),
    Snapshot(SnapshotError),
    Json(serde_json::Error),
    Mutation(MutationError),
    Io(io::Error),
    CheckFindings(Vec<u8>),
    ShowFailures,
    CheckOperational(String),
}

impl fmt::Display for AppError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Cache(error) => error.fmt(formatter),
            Self::Invocation(message) => message.fmt(formatter),
            Self::Filesystem(error) => error.fmt(formatter),
            Self::Query(error) => error.fmt(formatter),
            Self::Snapshot(error) => error.fmt(formatter),
            Self::Json(error) => error.fmt(formatter),
            Self::Mutation(error) => error.fmt(formatter),
            Self::Io(error) => error.fmt(formatter),
            Self::ShowFailures => {
                write!(formatter, "one or more requested issues could not be shown")
            }
            Self::CheckFindings(_) => write!(formatter, "ledger integrity findings"),
            Self::CheckOperational(message) => message.fmt(formatter),
        }
    }
}

impl Error for AppError {}

impl From<CacheError> for AppError {
    fn from(error: CacheError) -> Self {
        Self::Cache(error)
    }
}

impl From<FilesystemError> for AppError {
    fn from(error: FilesystemError) -> Self {
        Self::Filesystem(error)
    }
}

impl From<QueryError> for AppError {
    fn from(error: QueryError) -> Self {
        Self::Query(error)
    }
}

impl From<SnapshotError> for AppError {
    fn from(error: SnapshotError) -> Self {
        Self::Snapshot(error)
    }
}

impl From<serde_json::Error> for AppError {
    fn from(error: serde_json::Error) -> Self {
        Self::Json(error)
    }
}

impl From<MutationError> for AppError {
    fn from(error: MutationError) -> Self {
        Self::Mutation(error)
    }
}
