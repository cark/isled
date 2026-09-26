//! Filesystem adapters and the locked publication boundary.
mod contents;
mod counter;
mod error;
mod initialize;
mod inventory;
mod loaded;
mod lock;
mod paths;
mod prefetch;
mod read;
mod records;
mod root;
mod write;

pub use error::FilesystemError;
pub use initialize::initialize_ledger;
pub use lock::StoreLock;
pub use records::{
    RecordRead, StoreEntry, StoreSnapshot, StoredHeader, StoredIdentity, StoredRecord,
};
pub use root::{CacheCleanup, ProjectRoot};

#[cfg(test)]
mod tests;

#[cfg(test)]
mod loaded_tests;
