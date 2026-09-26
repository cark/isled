//! Opt-in graph transport, conditional on topology rather than issue prose.
use super::{request::Request, wire::live_hash};
use crate::{
    cache::{Cache, CacheError, Summary},
    graph_layout::{Direction, Graph, Plan},
    issue::IssueId,
};
use serde::{Deserialize, Serialize};

// Retain the measured candidate's edge budget. Bound first-layout allocation;
// lane width itself is unrestricted, and no accepted edge is silently omitted.
const MAX_EDGES: usize = 1_000_000;

#[derive(Clone, Copy, Debug, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum GraphDirection {
    Prerequisites,
    Dependents,
}

impl GraphDirection {
    fn layout(self) -> Direction {
        match self {
            Self::Prerequisites => Direction::PrerequisitesFirst,
            Self::Dependents => Direction::DependentsFirst,
        }
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct GraphRequest {
    direction: GraphDirection,
    pub(crate) hash: Option<String>,
}

#[derive(Serialize)]
pub(super) struct GraphResponse {
    hash: String,
    direction: GraphDirection,
    plan: Option<GraphPlan>,
}

#[derive(Serialize)]
struct GraphPlan {
    lanes: usize,
    rows: Vec<GraphRow>,
    drawing: crate::graph_layout::Drawing,
}

#[derive(Serialize)]
struct GraphRow {
    id: String,
    lane: usize,
    start: Option<usize>,
    targets: Vec<usize>,
    #[serde(flatten)]
    filtered: FilteredConnections,
}

#[derive(Clone, Copy, Default, Serialize)]
struct FilteredConnections {
    #[serde(skip_serializing_if = "is_zero")]
    filtered_prerequisites: usize,
    #[serde(skip_serializing_if = "is_zero")]
    filtered_dependents: usize,
}

fn is_zero(value: &usize) -> bool {
    *value == 0
}

impl GraphPlan {
    fn new(plan: Plan, filtered: &[FilteredConnections]) -> Self {
        Self {
            lanes: plan.lanes(),
            drawing: plan.drawing(),
            rows: plan
                .rows()
                .iter()
                .map(|row| GraphRow {
                    id: row.id().to_string(),
                    lane: row.lane(),
                    start: row.start(),
                    targets: row.targets().to_vec(),
                    filtered: filtered[usize::from(row.id().get())],
                })
                .collect(),
        }
    }
}

pub(super) fn prepare(
    cache: &Cache<'_>,
    criteria: &Request,
    request: &GraphRequest,
) -> Result<(Vec<Summary>, GraphResponse), CacheError> {
    let summaries =
        cache.filter_summaries(&criteria.filters, &criteria.kinds, criteria.text.as_ref())?;
    // Strict status selection precedes the additional filters. Only its direct
    // edges can contribute to omitted-connection counts; never bridge a gap.
    let edges = cache.layout_edges(criteria.filters.status, MAX_EDGES)?;
    let filtered = filtered_connections(&summaries, &edges);
    let graph = Graph::new(summaries.iter().map(Summary::id), edges, MAX_EDGES)
        .map_err(|error| CacheError::Invalid(error.to_string()))?;
    let hash = live_hash(&(
        crate::graph_layout::VERSION,
        criteria.filters.status.map(crate::issue::Status::as_str),
        request.direction,
        &graph,
        filtered
            .iter()
            .enumerate()
            .filter(|(_, counts)| counts.filtered_prerequisites + counts.filtered_dependents > 0)
            .collect::<Vec<_>>(),
    ))
    .map_err(super::json_error)?;
    let plan = if request.hash.as_ref() == Some(&hash) {
        None
    } else {
        Some(GraphPlan::new(
            graph
                .layout(request.direction.layout())
                .map_err(|error| CacheError::Invalid(error.to_string()))?,
            &filtered,
        ))
    };
    Ok((
        summaries,
        GraphResponse {
            hash,
            direction: request.direction,
            plan,
        },
    ))
}

fn filtered_connections(
    summaries: &[Summary],
    edges: &[(IssueId, IssueId)],
) -> Vec<FilteredConnections> {
    // The 9,999-ID domain bounds these indexes and makes every edge lookup O(1).
    let size = usize::from(IssueId::MAX) + 1;
    let mut selected = vec![false; size];
    for row in summaries {
        selected[usize::from(row.id().get())] = true;
    }
    let mut filtered = vec![FilteredConnections::default(); size];
    for &(dependent, prerequisite) in edges {
        let dependent = usize::from(dependent.get());
        let prerequisite = usize::from(prerequisite.get());
        match (selected[dependent], selected[prerequisite]) {
            (true, false) => filtered[dependent].filtered_prerequisites += 1,
            (false, true) => filtered[prerequisite].filtered_dependents += 1,
            _ => {}
        }
    }
    filtered
}
