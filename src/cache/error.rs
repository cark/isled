use crate::filesystem::FilesystemError;
use std::{error::Error, fmt, io};

#[derive(Debug)]
pub enum CacheError {
    Sql(rusqlite::Error),
    Io(io::Error),
    Filesystem(FilesystemError),
    Invalid(String),
    Corrupt(String),
}

impl fmt::Display for CacheError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Sql(e) => write!(f, "cache database: {e}"),
            Self::Io(e) => write!(f, "cache I/O: {e}"),
            Self::Filesystem(e) => e.fmt(f),
            Self::Invalid(e) | Self::Corrupt(e) => e.fmt(f),
        }
    }
}
impl Error for CacheError {}
impl CacheError {
    pub fn is_corruption(&self) -> bool {
        if matches!(
            self,
            Self::Corrupt(_)
                | Self::Sql(
                    rusqlite::Error::InvalidColumnType(..)
                        | rusqlite::Error::FromSqlConversionFailure(..)
                        | rusqlite::Error::QueryReturnedNoRows
                )
        ) {
            return true;
        }
        matches!(self, Self::Sql(rusqlite::Error::SqliteFailure(e, _)) if matches!(e.code,
            rusqlite::ErrorCode::DatabaseCorrupt | rusqlite::ErrorCode::NotADatabase))
    }
}
impl From<rusqlite::Error> for CacheError {
    fn from(e: rusqlite::Error) -> Self {
        Self::Sql(e)
    }
}
impl From<io::Error> for CacheError {
    fn from(e: io::Error) -> Self {
        Self::Io(e)
    }
}
impl From<FilesystemError> for CacheError {
    fn from(e: FilesystemError) -> Self {
        Self::Filesystem(e)
    }
}
