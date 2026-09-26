use super::FilesystemError;
use std::rc::Rc;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StoredRecord {
    state: Rc<crate::record::RecordState>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StoredHeader {
    record: StoredRecord,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StoredIdentity {
    id: crate::issue::IssueId,
    filename: Vec<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StoreEntry {
    pub(super) filename: Vec<u8>,
    pub(super) filename_is_utf8: bool,
    pub(super) bytes: Vec<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StoreSnapshot {
    pub entries: Vec<StoreEntry>,
    pub high_water: Option<Vec<u8>>,
}

/// Snapshot transport: identity is checked, content can carry a per-file I/O error.
pub struct RecordRead {
    pub identity: StoredIdentity,
    pub content: Result<StoredRecord, String>,
}

impl StoredRecord {
    pub(crate) fn new(filename: Vec<u8>, bytes: Vec<u8>) -> Result<Self, FilesystemError> {
        let record = Self::from_bytes(filename, bytes);
        record.require_encoding()?;
        Ok(record)
    }

    pub(super) fn from_bytes(filename: Vec<u8>, bytes: Vec<u8>) -> Self {
        Self {
            state: Rc::new(crate::record::RecordState::new(filename, bytes)),
        }
    }

    pub(super) fn require_encoding(&self) -> Result<(), FilesystemError> {
        self.state
            .encoding()
            .map_err(|error| FilesystemError::InvalidRecordEncoding {
                filename: self.filename().to_vec(),
                error,
            })
    }

    /// Complete-record validity, reusing this record's retained parse result.
    pub fn issue(&self) -> Result<&crate::issue::Issue, crate::record::RecordError> {
        self.document().map(|document| &document.issue)
    }

    pub(crate) fn corrected(
        filename: Vec<u8>,
        bytes: Vec<u8>,
        document: crate::record::RecordDocument,
    ) -> Self {
        Self {
            state: Rc::new(crate::record::RecordState::corrected(
                filename, bytes, document,
            )),
        }
    }

    pub fn filename(&self) -> &[u8] {
        self.state.filename()
    }

    pub fn bytes(&self) -> &[u8] {
        self.state.bytes()
    }

    pub(crate) fn fingerprint(&self) -> u64 {
        self.state.fingerprint()
    }

    #[cfg(test)]
    pub(super) fn weak_state(&self) -> std::rc::Weak<crate::record::RecordState> {
        Rc::downgrade(&self.state)
    }

    #[cfg(test)]
    pub(crate) fn parse_counts(&self) -> [usize; 3] {
        self.state.parse_counts()
    }

    pub(crate) fn document(
        &self,
    ) -> Result<&crate::record::RecordDocument, crate::record::RecordError> {
        self.state.document()
    }

    pub(crate) fn header(&self) -> Result<&crate::issue::Issue, crate::record::RecordError> {
        self.state.header()
    }
}

impl StoredHeader {
    pub(super) fn new(filename: Vec<u8>, bytes: Vec<u8>) -> Result<Self, FilesystemError> {
        let record = StoredRecord::new(filename, bytes)?;
        record.header().map_err(FilesystemError::Record)?;
        Ok(Self { record })
    }

    pub fn filename(&self) -> &[u8] {
        self.record.filename()
    }
    pub fn bytes(&self) -> &[u8] {
        self.record.bytes()
    }
    pub(crate) fn record(&self) -> &StoredRecord {
        &self.record
    }
}

impl StoredIdentity {
    pub(crate) fn new(filename: Vec<u8>) -> Result<Self, FilesystemError> {
        let (id, _) = crate::record::parse_filename(&filename)?;
        Ok(Self { id, filename })
    }

    pub fn id(&self) -> crate::issue::IssueId {
        self.id
    }

    pub fn filename(&self) -> &[u8] {
        &self.filename
    }
}

impl StoreEntry {
    #[cfg(test)]
    pub(crate) fn for_test(filename: &[u8], bytes: &[u8]) -> Self {
        Self {
            filename: filename.to_vec(),
            filename_is_utf8: std::str::from_utf8(filename).is_ok(),
            bytes: bytes.to_vec(),
        }
    }

    pub fn filename(&self) -> &[u8] {
        &self.filename
    }

    pub fn filename_is_utf8(&self) -> bool {
        self.filename_is_utf8
    }

    pub fn bytes(&self) -> &[u8] {
        &self.bytes
    }
}
