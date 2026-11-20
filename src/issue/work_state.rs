//! Optional scheduling state, independent of lifecycle and dependency readiness.
use crate::work_log::WorkTime;
use std::{fmt, str::FromStr};

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub enum WorkStateKind {
    #[default]
    NotQueued,
    Planning,
    Prepared,
    Queued,
    InProgress,
    AwaitingOwner,
    Custom(String),
}
impl WorkStateKind {
    pub fn as_str(&self) -> &str {
        match self {
            Self::Custom(id) => id,
            Self::NotQueued => "not-queued",
            Self::Planning => "planning",
            Self::Prepared => "prepared",
            Self::Queued => "queued",
            Self::InProgress => "in-progress",
            Self::AwaitingOwner => "awaiting-owner",
        }
    }
}
impl FromStr for WorkStateKind {
    type Err = WorkStateError;
    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "not-queued" => Ok(Self::NotQueued),
            "planning" => Ok(Self::Planning),
            "prepared" => Ok(Self::Prepared),
            "queued" => Ok(Self::Queued),
            "in-progress" => Ok(Self::InProgress),
            "awaiting-owner" => Ok(Self::AwaitingOwner),
            id if crate::workflow::id(id) => Ok(Self::Custom(id.into())),
            _ => Err(WorkStateError),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OwnerQuestion(String);
impl OwnerQuestion {
    pub fn parse(value: &str) -> Result<Self, WorkStateError> {
        if value.trim().is_empty() || value.contains(['\n', '\r', '\0']) {
            return Err(WorkStateError);
        }
        Ok(Self(value.into()))
    }
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum OwnerWait {
    Review,
    Clarification(OwnerQuestion),
    Configured(String, Option<OwnerQuestion>),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum OwnerWaitReason {
    Review,
    Clarification,
    Custom(String),
}
impl OwnerWaitReason {
    pub fn as_str(&self) -> &str {
        match self {
            Self::Custom(id) => id,
            Self::Review => "review",
            Self::Clarification => "clarification",
        }
    }
}
impl FromStr for OwnerWaitReason {
    type Err = WorkStateError;
    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "review" => Ok(Self::Review),
            "clarification" => Ok(Self::Clarification),
            id if crate::workflow::id(id) => Ok(Self::Custom(id.into())),
            _ => Err(WorkStateError),
        }
    }
}
impl OwnerWait {
    pub fn reason(&self) -> &str {
        match self {
            Self::Review => "review",
            Self::Clarification(_) => "clarification",
            Self::Configured(id, _) => id,
        }
    }
    pub fn question(&self) -> Option<&str> {
        match self {
            Self::Review => None,
            Self::Configured(_, q) => q.as_ref().map(OwnerQuestion::as_str),
            Self::Clarification(question) => Some(question.as_str()),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum WorkState {
    Configured {
        kind: WorkStateKind,
        wait: Option<OwnerWait>,
        since: Option<WorkTime>,
    },
    Planning {
        since: Option<WorkTime>,
    },
    Prepared {
        since: Option<WorkTime>,
    },
    Queued {
        since: Option<WorkTime>,
    },
    InProgress {
        since: Option<WorkTime>,
    },
    AwaitingOwner {
        wait: OwnerWait,
        since: Option<WorkTime>,
    },
}
impl WorkState {
    pub fn kind(&self) -> WorkStateKind {
        match self {
            Self::Configured { kind, .. } => kind.clone(),
            Self::Planning { .. } => WorkStateKind::Planning,
            Self::Prepared { .. } => WorkStateKind::Prepared,
            Self::Queued { .. } => WorkStateKind::Queued,
            Self::InProgress { .. } => WorkStateKind::InProgress,
            Self::AwaitingOwner { .. } => WorkStateKind::AwaitingOwner,
        }
    }
    pub fn owner_wait(&self) -> Option<&OwnerWait> {
        match self {
            Self::AwaitingOwner { wait, .. } => Some(wait),
            Self::Configured { wait, .. } => wait.as_ref(),
            _ => None,
        }
    }
    pub fn since(&self) -> Option<WorkTime> {
        match self {
            Self::Configured { since, .. }
            | Self::Planning { since }
            | Self::Prepared { since }
            | Self::Queued { since }
            | Self::InProgress { since }
            | Self::AwaitingOwner { since, .. } => *since,
        }
    }
    pub(crate) fn with_since(mut self, value: Option<WorkTime>) -> Self {
        match &mut self {
            Self::Configured { since, .. }
            | Self::Planning { since }
            | Self::Prepared { since }
            | Self::Queued { since }
            | Self::InProgress { since }
            | Self::AwaitingOwner { since, .. } => *since = value,
        }
        self
    }
    pub(crate) fn same_phase(&self, other: &Self) -> bool {
        self.kind() == other.kind()
            && self.owner_wait().map(OwnerWait::reason) == other.owner_wait().map(OwnerWait::reason)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct WorkStateError;
impl fmt::Display for WorkStateError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("invalid work state or owner question (use one non-empty line)")
    }
}
impl std::error::Error for WorkStateError {}
