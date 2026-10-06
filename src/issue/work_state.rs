//! Optional scheduling state, independent of lifecycle and dependency readiness.
use std::{fmt, str::FromStr};

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum WorkStateKind {
    #[default]
    NotQueued,
    Queued,
    InProgress,
    AwaitingOwner,
}
impl WorkStateKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::NotQueued => "not-queued",
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
            "queued" => Ok(Self::Queued),
            "in-progress" => Ok(Self::InProgress),
            "awaiting-owner" => Ok(Self::AwaitingOwner),
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
}
impl OwnerWait {
    pub fn reason(&self) -> &'static str {
        match self {
            Self::Review => "review",
            Self::Clarification(_) => "clarification",
        }
    }
    pub fn question(&self) -> Option<&str> {
        match self {
            Self::Review => None,
            Self::Clarification(question) => Some(question.as_str()),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum WorkState {
    Queued,
    InProgress,
    AwaitingOwner(OwnerWait),
}
impl WorkState {
    pub fn kind(&self) -> WorkStateKind {
        match self {
            Self::Queued => WorkStateKind::Queued,
            Self::InProgress => WorkStateKind::InProgress,
            Self::AwaitingOwner(_) => WorkStateKind::AwaitingOwner,
        }
    }
    pub fn owner_wait(&self) -> Option<&OwnerWait> {
        match self {
            Self::AwaitingOwner(wait) => Some(wait),
            _ => None,
        }
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
