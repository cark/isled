use crate::filesystem::StoredRecord;
use crate::issue::{IssueId, Status};
use crate::record::RecordDocument;

use super::{MutationError, parse_record_view, unique_record};

/// A replacement produced only by the typed mutation operations.
///
/// ```compile_fail
/// use isled::mutation::Replacement;
/// let _ = Replacement { filename: b"../outside".to_vec(), bytes: vec![0xff] };
/// ```
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Replacement {
    record: StoredRecord,
}

impl Replacement {
    pub(super) fn rendered(filename: Vec<u8>, document: RecordDocument) -> Self {
        Self::corrected(filename, document.render(), document)
    }

    pub(super) fn corrected(filename: Vec<u8>, bytes: Vec<u8>, document: RecordDocument) -> Self {
        Self {
            record: StoredRecord::corrected(filename, bytes, document),
        }
    }

    pub(crate) fn record(&self) -> &StoredRecord {
        &self.record
    }

    pub fn filename(&self) -> &[u8] {
        self.record().filename()
    }
    pub fn bytes(&self) -> &[u8] {
        self.record().bytes()
    }
}

/// Opaque publication input; an empty default plan is a valid no-op.
///
/// ```compile_fail
/// use isled::mutation::MutationPlan;
/// let _ = MutationPlan { replacements: vec![] };
/// ```
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct MutationPlan {
    pub(super) replacements: Vec<Replacement>,
}

impl MutationPlan {
    pub fn replacements(&self) -> &[Replacement] {
        &self.replacements
    }
}

/// Whether this plan changes the explicitly selected issue's closed history.
/// Copied-title maintenance in neighbors and byte-identical replacements do not count.
pub fn changes_closed_issue(
    records: &[StoredRecord],
    id: IssueId,
    plan: &MutationPlan,
) -> Result<bool, MutationError> {
    let target = unique_record(records, id)?;
    Ok(parse_record_view(target)?.status() == Status::Closed
        && plan.replacements.iter().any(|replacement| {
            replacement.filename() == target.filename() && replacement.bytes() != target.bytes()
        }))
}

pub(super) fn plan_record_replacement(
    record: &StoredRecord,
    document: RecordDocument,
) -> MutationPlan {
    MutationPlan {
        replacements: vec![Replacement::rendered(record.filename().to_vec(), document)],
    }
}

pub(super) fn plan_document_replacements<'a>(
    documents: impl IntoIterator<Item = (&'a StoredRecord, RecordDocument)>,
) -> MutationPlan {
    let mut replacements = documents
        .into_iter()
        .map(|(record, document)| Replacement::rendered(record.filename().to_vec(), document))
        .collect::<Vec<_>>();
    replacements.sort_by(|left, right| left.filename().cmp(right.filename()));
    MutationPlan { replacements }
}
