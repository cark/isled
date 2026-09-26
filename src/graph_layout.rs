//! Window-independent dependency layouts, shared by the frontend and preview.
mod drawing;
mod ordering;
mod plan;
mod range;
pub mod store;
mod text;

pub use drawing::Drawing;
pub use plan::{Plan, Row};
pub use range::{Continuation, LayoutRange, RangeRow, Route};

use crate::issue::IssueId;
use serde::{Deserialize, Serialize};
use std::fmt;

/// Version of the layout algorithm and its experimental stored representation.
pub const VERSION: u32 = 3;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum Direction {
    PrerequisitesFirst,
    DependentsFirst,
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct LayoutError(pub(crate) String);

impl fmt::Display for LayoutError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for LayoutError {}

/// Canonical selected membership and direct dependent -> prerequisite edges.
/// Edges through excluded nodes are discarded, never bridged.
#[derive(Debug, Clone, Eq, PartialEq, Serialize)]
pub struct Graph {
    ids: Vec<u16>,
    edges: Vec<(u16, u16)>,
}

impl Graph {
    pub fn new(
        ids: impl IntoIterator<Item = IssueId>,
        edges: impl IntoIterator<Item = (IssueId, IssueId)>,
        max_edges: usize,
    ) -> Result<Self, LayoutError> {
        let mut ids: Vec<_> = ids.into_iter().map(IssueId::get).collect();
        ids.sort_unstable();
        if ids.windows(2).any(|pair| pair[0] == pair[1]) {
            return Err(LayoutError("duplicate graph issue identity".into()));
        }
        let mut selected = vec![false; usize::from(IssueId::MAX) + 1];
        for &id in &ids {
            selected[usize::from(id)] = true;
        }
        let mut kept = Vec::new();
        for (dependent, prerequisite) in edges {
            if !selected[usize::from(dependent.get())] || !selected[usize::from(prerequisite.get())]
            {
                continue;
            }
            if kept.len() == max_edges {
                return Err(LayoutError(format!(
                    "dependency graph exceeds the edge budget ({max_edges})"
                )));
            }
            kept.push((dependent.get(), prerequisite.get()));
        }
        kept.sort_unstable();
        kept.dedup();
        Ok(Self { ids, edges: kept })
    }

    pub fn node_count(&self) -> usize {
        self.ids.len()
    }

    pub fn edge_count(&self) -> usize {
        self.edges.len()
    }

    pub fn layout(&self, direction: Direction) -> Result<Plan, LayoutError> {
        let outgoing = self.outgoing(direction);
        let order = ordering::order(&outgoing)?;
        Ok(Plan::build(&self.ids, &outgoing, &order))
    }

    pub(crate) fn outgoing(&self, direction: Direction) -> Vec<Vec<usize>> {
        // Issue identities have a domain bound of 9,999; avoid per-edge map lookups.
        let mut index = vec![0; usize::from(IssueId::MAX) + 1];
        for (i, &id) in self.ids.iter().enumerate() {
            index[usize::from(id)] = i;
        }
        let mut outgoing = vec![Vec::new(); self.ids.len()];
        for &(dependent, prerequisite) in &self.edges {
            let (from, to) = match direction {
                Direction::PrerequisitesFirst => (prerequisite, dependent),
                Direction::DependentsFirst => (dependent, prerequisite),
            };
            outgoing[index[usize::from(from)]].push(index[usize::from(to)]);
        }
        outgoing
    }
}

#[cfg(test)]
mod tests;
