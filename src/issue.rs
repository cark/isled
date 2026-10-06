//! Parsed issue aggregate and its validated value types.
mod created_date;
mod identity;
mod name;
mod relation;
mod status;
mod tag;
mod work_state;
pub use created_date::{CreatedDate, ParseCreatedDateError};
pub use identity::{CanonicalIssueId, IssueId, ParseCanonicalIssueIdError, ParseIssueIdError};
pub use name::{Name, ParseNameError};
pub use relation::{IssueRelation, ParseWaitReasonError, WaitReason, WaitRelation};
pub use status::{ParseStatusError, Status};
pub use tag::{ParseTagError, Tag};
pub use work_state::{OwnerQuestion, OwnerWait, WorkState, WorkStateError, WorkStateKind};

/// Parsed issue data, publicly readable but not externally constructible or mutable.
///
/// ```compile_fail
/// use isled::issue::Issue;
/// fn corrupt(issue: &mut Issue) { issue.title = vec![0xff]; }
/// ```
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Issue {
    pub(crate) id: IssueId,
    pub(crate) slug: Name,
    /// Kept as bytes to preserve the validated UTF-8 record exactly.
    pub(crate) title: Vec<u8>,
    pub(crate) status: Status,
    pub(crate) kind: Name,
    pub(crate) created: CreatedDate,
    pub(crate) work_state: Option<WorkState>,
    pub(crate) tags: Vec<Tag>,
    pub(crate) waits: Vec<WaitRelation>,
    pub(crate) blocking: Vec<IssueRelation>,
}

impl Issue {
    pub fn id(&self) -> IssueId {
        self.id
    }
    pub fn slug(&self) -> &Name {
        &self.slug
    }
    pub fn title(&self) -> &[u8] {
        &self.title
    }
    pub fn status(&self) -> Status {
        self.status
    }
    pub fn kind(&self) -> &Name {
        &self.kind
    }
    pub fn created(&self) -> &CreatedDate {
        &self.created
    }
    pub fn tags(&self) -> &[Tag] {
        &self.tags
    }
    pub fn work_state(&self) -> Option<&WorkState> {
        self.work_state.as_ref()
    }
    pub fn work_state_kind(&self) -> WorkStateKind {
        self.work_state
            .as_ref()
            .map_or(WorkStateKind::NotQueued, WorkState::kind)
    }
    pub fn waits(&self) -> &[WaitRelation] {
        &self.waits
    }
    pub fn blocking(&self) -> &[IssueRelation] {
        &self.blocking
    }
}
