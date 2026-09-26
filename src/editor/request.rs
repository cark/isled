//! Decode editor transport into request identity and complete draft input.
use crate::{
    issue::IssueId,
    mutation::editor::{Draft, FieldError},
};
use serde::Deserialize;
#[derive(Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub(super) enum Mode {
    Load,
    Validate,
    Save,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Input {
    schema_version: u32,
    mode: Mode,
    id: Option<String>,
    expected: Option<String>,
    draft: Option<Draft>,
    #[serde(default)]
    close: bool,
}
pub(super) struct Request {
    pub mode: Mode,
    pub id: Option<IssueId>,
    pub expected: Option<String>,
    pub draft: Option<Draft>,
    pub close: bool,
}
impl Request {
    pub fn parse(bytes: &[u8]) -> Result<Self, FieldError> {
        let input: Input =
            serde_json::from_slice(bytes).map_err(|e| FieldError::new("request", e))?;
        if input.schema_version != 2 {
            return Err(FieldError::new(
                "request",
                "Unsupported editor schema version",
            ));
        }
        let id = input
            .id
            .map(|s| s.parse().map_err(|e| FieldError::new("id", e)))
            .transpose()?;
        if input.close && (id.is_none() || input.mode == Mode::Load) {
            return Err(FieldError::new(
                "request",
                "Closing requires an existing issue draft",
            ));
        }
        Ok(Self {
            mode: input.mode,
            id,
            expected: input.expected,
            draft: input.draft,
            close: input.close,
        })
    }
}
