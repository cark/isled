//! Parse weak frontend JSON into validated request values.
use super::graph::GraphRequest;
use crate::{
    issue::{IssueId, Name, Status, Tag},
    query::{Filters, SearchSnippets},
};
use serde::Deserialize;
use std::collections::BTreeMap;

#[derive(Clone, Copy, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum Mode {
    Refresh,
    View,
    Details,
    Choices,
}

pub struct Request {
    pub(super) mode: Mode,
    pub(super) filters: Filters,
    pub(super) kinds: Vec<Name>,
    pub(super) text: Option<SearchSnippets>,
    pub(super) choice_filter: Option<Criteria>,
    pub(super) view_hash: Option<String>,
    pub(super) details: BTreeMap<IssueId, Option<String>>,
    pub(super) graph: Option<GraphRequest>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Input {
    schema_version: u32,
    mode: Mode,
    #[serde(default)]
    filter: Filter,
    choice_filter: Option<Filter>,
    view_hash: Option<String>,
    #[serde(default)]
    details: Vec<Detail>,
    graph: Option<GraphRequest>,
}
#[derive(Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct Filter {
    status: Option<String>,
    kind: Option<String>,
    work_state: Option<String>,
    #[serde(default)]
    tags: Vec<String>,
    #[serde(default)]
    kinds: Vec<String>,
    #[serde(default)]
    text: Vec<String>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Detail {
    id: String,
    hash: Option<String>,
}

impl Request {
    pub fn mode(&self) -> Mode {
        self.mode
    }

    pub fn parse(bytes: &[u8]) -> Result<Self, String> {
        let input: Input = serde_json::from_slice(bytes).map_err(|e| e.to_string())?;
        if input.schema_version != 4 {
            return Err("unsupported frontend request version".into());
        }
        let criteria = Criteria::parse(input.filter)?;
        let choice_filter = input.choice_filter.map(Criteria::parse).transpose()?;
        let view_hash = validate_hash(input.view_hash)?;
        if let Some(graph) = &input.graph {
            validate_hash(graph.hash.clone())?;
            if !matches!(input.mode, Mode::View | Mode::Refresh) {
                return Err("graph layouts require view or refresh mode".into());
            }
        }
        let mut details = BTreeMap::new();
        for item in input.details {
            let id: IssueId = item.id.parse().map_err(|_| "invalid detail ID")?;
            if id.to_string() != item.id {
                return Err("detail IDs must use four digits".into());
            }
            if details.insert(id, validate_hash(item.hash)?).is_some() {
                return Err("duplicate detail ID".into());
            }
        }
        if input.mode == Mode::Choices && (!details.is_empty() || view_hash.is_some()) {
            return Err("choices requests cannot include details or a view hash".into());
        }
        if input.mode == Mode::Details && choice_filter.is_some() {
            return Err("detail requests cannot include a choice filter".into());
        }
        Ok(Self {
            mode: input.mode,
            filters: criteria.filters,
            kinds: criteria.kinds,
            text: criteria.text,
            choice_filter,
            view_hash,
            details,
            graph: input.graph,
        })
    }
}

/// Validated criteria shared by view selection and contextual completion.
pub(crate) struct Criteria {
    pub(crate) filters: Filters,
    pub(crate) kinds: Vec<Name>,
    pub(crate) text: Option<SearchSnippets>,
}

impl Criteria {
    fn parse(filter: Filter) -> Result<Self, String> {
        let filters = Filters {
            work_state: filter
                .work_state
                .map(|value| {
                    value
                        .parse()
                        .map_err(|e: crate::issue::WorkStateError| e.to_string())
                })
                .transpose()?,
            status: match filter.status.as_deref().unwrap_or("open") {
                "all" => None,
                text => Some(Status::try_parse(text.as_bytes()).map_err(|e| e.to_string())?),
            },
            kind: filter
                .kind
                .map(|s| Name::try_parse(s.as_bytes()).map_err(|e| e.to_string()))
                .transpose()?,
            tags: filter
                .tags
                .iter()
                .map(|s| Tag::try_parse(s.as_bytes()).map_err(|e| e.to_string()))
                .collect::<Result<_, _>>()?,
            ..Filters::default()
        };
        let kinds = filter
            .kinds
            .iter()
            .map(|s| Name::try_parse(s.as_bytes()).map_err(|e| e.to_string()))
            .collect::<Result<Vec<_>, _>>()?;
        let text = if filter.text.is_empty() {
            None
        } else {
            Some(SearchSnippets::parse(filter.text).map_err(|e| e.to_string())?)
        };
        Ok(Self {
            filters,
            kinds,
            text,
        })
    }
}

fn validate_hash(value: Option<String>) -> Result<Option<String>, String> {
    if value.as_ref().is_some_and(|s| {
        s.len() != 16
            || !s
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    }) {
        return Err("live hash must be 16 lowercase hexadecimal digits".into());
    }
    Ok(value)
}
