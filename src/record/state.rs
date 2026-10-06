//! Immutable source bytes with reusable, operation-scoped parse results.
use super::*;
use std::cell::OnceCell;

#[derive(Debug)]
pub(crate) struct RecordState {
    filename: Vec<u8>,
    bytes: Vec<u8>,
    fingerprint: OnceCell<u64>,
    encoding: OnceCell<Result<(), RecordError>>,
    heading: OnceCell<Result<Vec<u8>, RecordError>>,
    metadata: OnceCell<Result<Metadata, RecordError>>,
    header: OnceCell<Result<Issue, RecordError>>,
    document: OnceCell<Result<RecordDocument, RecordError>>,
    #[cfg(test)]
    counts: std::cell::Cell<[usize; 3]>,
}

impl RecordState {
    pub(crate) fn new(filename: Vec<u8>, bytes: Vec<u8>) -> Self {
        Self {
            filename,
            bytes,
            fingerprint: OnceCell::new(),
            encoding: OnceCell::new(),
            heading: OnceCell::new(),
            metadata: OnceCell::new(),
            header: OnceCell::new(),
            document: OnceCell::new(),
            #[cfg(test)]
            counts: std::cell::Cell::new([0; 3]),
        }
    }

    /// Trusted mutation output: callers update fields and preserved bytes together.
    pub(crate) fn corrected(filename: Vec<u8>, bytes: Vec<u8>, document: RecordDocument) -> Self {
        let state = Self::new(filename, bytes);
        state.encoding.set(Ok(())).expect("trusted UTF-8 output");
        state.document.set(Ok(document)).expect("new state");
        state
    }

    pub(crate) fn filename(&self) -> &[u8] {
        &self.filename
    }
    pub(crate) fn bytes(&self) -> &[u8] {
        &self.bytes
    }

    pub(crate) fn fingerprint(&self) -> u64 {
        *self
            .fingerprint
            .get_or_init(|| xxhash_rust::xxh3::xxh3_64(&self.bytes))
    }

    pub(crate) fn encoding(&self) -> Result<(), RecordError> {
        *self
            .encoding
            .get_or_init(|| validate_utf8(&self.filename, &self.bytes))
    }

    pub(crate) fn document(&self) -> Result<&RecordDocument, RecordError> {
        self.document
            .get_or_init(|| self.parse_document())
            .as_ref()
            .map_err(Clone::clone)
    }

    pub(crate) fn header(&self) -> Result<&Issue, RecordError> {
        if let Some(Ok(document)) = self.document.get() {
            return Ok(&document.issue);
        }
        self.header
            .get_or_init(|| {
                self.encoding()?;
                let (id, slug) = parse_filename(&self.filename)?;
                let (heading, metadata) = header_parts(&self.bytes)?;
                // Header queries historically validate the heading before metadata.
                let title = self.heading(heading, id)?;
                let metadata = self.metadata(metadata)?;
                Ok(Self::issue(id, slug, title, metadata))
            })
            .as_ref()
            .map_err(Clone::clone)
    }

    fn parse_document(&self) -> Result<RecordDocument, RecordError> {
        #[cfg(test)]
        self.count_parse(0);
        self.encoding()?;
        let (id, slug) = parse_filename(&self.filename)?;
        let sections = split_document(&self.bytes)?;
        // Complete records historically validate structure, metadata, then heading.
        // A malformed header can end at a noncanonical Statement marker. Its
        // different metadata slice must not stand in for complete-record validation.
        let alternate;
        let metadata = if header_parts(&self.bytes)?.1 == sections.metadata {
            self.metadata(sections.metadata)?
        } else {
            #[cfg(test)]
            self.count_parse(2);
            alternate = parse_metadata(sections.metadata)?;
            &alternate
        };
        let title = self.heading(sections.heading, id)?;
        let work_log = work::parse_log(sections.work_log, metadata.work_state.as_ref())?;
        Ok(RecordDocument {
            work_log,
            work_log_source: sections.work_log.map(Vec::from),
            issue: Self::issue(id, slug, title, metadata),
            statement: parse_statement(sections.statement)?.to_vec(),
            evidence: parse_evidence(sections.evidence)?,
            outcome: parse_outcome(sections.outcome)?.to_vec(),
        })
    }

    fn heading(&self, bytes: &[u8], id: IssueId) -> Result<&[u8], RecordError> {
        self.heading
            .get_or_init(|| {
                #[cfg(test)]
                self.count_parse(1);
                parse_heading(bytes, id).map(<[u8]>::to_vec)
            })
            .as_deref()
            .map_err(Clone::clone)
    }

    fn metadata(&self, bytes: &[u8]) -> Result<&Metadata, RecordError> {
        self.metadata
            .get_or_init(|| {
                #[cfg(test)]
                self.count_parse(2);
                parse_metadata(bytes)
            })
            .as_ref()
            .map_err(Clone::clone)
    }

    #[cfg(test)]
    fn count_parse(&self, index: usize) {
        let mut counts = self.counts.get();
        counts[index] += 1;
        self.counts.set(counts);
    }

    #[cfg(test)]
    pub(crate) fn parse_counts(&self) -> [usize; 3] {
        self.counts.get()
    }

    fn issue(id: IssueId, slug: Name, title: &[u8], metadata: &Metadata) -> Issue {
        metadata.clone().into_issue(id, slug, title.to_vec())
    }
}

impl PartialEq for RecordState {
    fn eq(&self, other: &Self) -> bool {
        self.filename == other.filename && self.bytes == other.bytes
    }
}
impl Eq for RecordState {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cached_parsing_preserves_scope_and_error_order() {
        let original = std::str::from_utf8(super::super::tests::RECORD).unwrap();
        let inputs = [
            original.to_owned(),
            original.replace("## Evidence", "## Broken"),
            original
                .replace("# 0001", "# 0002")
                .replace("Status:** open", "Status:** bad"),
            original.replace("## Statement", "## Statement extra\n\n## Statement"),
            original
                .split("\n\n## Statement")
                .next()
                .unwrap()
                .to_owned(),
            "malformed".to_owned(),
        ];
        for input in inputs {
            let name = b"0001-example.md";
            let expected_document = RecordDocument::parse(name, input.as_bytes());
            let expected_header = RecordView::new(name, input.as_bytes());
            for header_first in [true, false] {
                let state = RecordState::new(name.to_vec(), input.as_bytes().to_vec());
                if header_first {
                    let _ = state.header();
                }
                assert_eq!(
                    state.document(),
                    expected_document.as_ref().map_err(Clone::clone)
                );
                match &expected_header {
                    Ok(header) => assert_eq!(state.header().unwrap().title(), header.title()),
                    Err(error) => assert_eq!(state.header(), Err(*error)),
                }
                // Neither repeated successes nor failures run their parser again.
                let document = state.document.get().unwrap() as *const _;
                for _ in 0..3 {
                    let _ = state.header();
                    let _ = state.document();
                }
                assert_eq!(document, state.document.get().unwrap() as *const _);
            }
        }
    }
}
