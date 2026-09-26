use crate::issue::IssueId;
use crate::record::RecordError;
use std::error::Error;
use std::fmt;

use super::StatementEditError;

#[derive(Debug)]
pub enum MutationError {
    RepairReasonRequired,
    StatementEdit(StatementEditError),
    Record(RecordError),
    MissingIssue(IssueId),
    DuplicateId(IssueId),
    ClosedPriority,
    ClosedWaitSource(IssueId),
    ClosedWaitTarget(IssueId),
    DuplicateWait {
        source: IssueId,
        target: IssueId,
    },
    MissingWait {
        source: IssueId,
        target: IssueId,
    },
    Cycle {
        source: IssueId,
        target: IssueId,
    },
    InvalidGraphSource {
        operation: &'static str,
        source: IssueId,
    },
    InvalidEvidence,
    MixedPendingEvidence,
    InvalidOutcome,
    EvidencePending,
    OutcomePending,
    OutcomeAlreadyRecorded,
}

impl fmt::Display for MutationError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::RepairReasonRequired => write!(
                formatter,
                "completing a Blocking-only relation requires --reason TEXT"
            ),
            Self::StatementEdit(error) => error.fmt(formatter),
            Self::Record(error) => error.fmt(formatter),
            Self::MissingIssue(id) => write!(formatter, "issue not found: {id}"),
            Self::DuplicateId(id) => write!(formatter, "multiple issue files found for {id}"),
            Self::ClosedPriority => write!(formatter, "closed issue cannot gain a priority"),
            Self::ClosedWaitSource(_) => write!(formatter, "closed issue cannot gain a wait"),
            Self::ClosedWaitTarget(_) => write!(formatter, "cannot wait on a closed issue"),
            Self::DuplicateWait { source, target } => {
                write!(formatter, "issue {source} already waits on {target}")
            }
            Self::MissingWait { source, target } => {
                write!(formatter, "issue {source} does not wait on {target}")
            }
            Self::Cycle { source, target } => {
                write!(
                    formatter,
                    "cannot add wait: {target} already reaches {source} (cycle)"
                )
            }
            Self::InvalidGraphSource { operation, source } => write!(
                formatter,
                "cannot {operation}: relation metadata for issue {source} is inconsistent"
            ),
            Self::InvalidEvidence => write!(formatter, "issue has an invalid Evidence section"),
            Self::MixedPendingEvidence => write!(
                formatter,
                "Pending. cannot be mixed with other evidence; add concrete evidence instead"
            ),
            Self::InvalidOutcome => {
                write!(formatter, "issue has an invalid Outcome section")
            }
            Self::EvidencePending => write!(
                formatter,
                "issue evidence is pending; use evidence add ISSUE TEXT"
            ),
            Self::OutcomePending => {
                write!(formatter, "issue outcome is pending; use --outcome TEXT")
            }
            Self::OutcomeAlreadyRecorded => {
                write!(formatter, "issue already has a recorded outcome")
            }
        }
    }
}

impl Error for MutationError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::StatementEdit(error) => Some(error),
            Self::Record(error) => Some(error),
            _ => None,
        }
    }
}

impl From<RecordError> for MutationError {
    fn from(error: RecordError) -> Self {
        Self::Record(error)
    }
}

impl From<StatementEditError> for MutationError {
    fn from(error: StatementEditError) -> Self {
        Self::StatementEdit(error)
    }
}
