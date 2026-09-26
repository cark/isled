//! Targeted dependency graph construction and presentation.

use super::{OutputPaths, QueryError};
use crate::issue::{IssueId, Status};
use crate::wire::EncodedBytes;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};

pub const SCHEMA_VERSION: u32 = 2;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Direction {
    Dependencies,
    Dependents,
}

impl Direction {
    fn as_str(self) -> &'static str {
        match self {
            Self::Dependencies => "dependencies",
            Self::Dependents => "dependents",
        }
    }

    fn heading(self) -> &'static str {
        match self {
            Self::Dependencies => "Waits on:",
            Self::Dependents => "Waited on by:",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct Node {
    pub(crate) id: IssueId,
    pub(crate) status: Status,
    pub(crate) ready: bool,
    pub(crate) title: String,
    pub(crate) filename: Vec<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct Edge {
    pub(crate) dependent: IssueId,
    pub(crate) dependency: IssueId,
    pub(crate) reason: String,
    pub(crate) blocking: bool,
}

/// A validated, direction-limited graph independent of filesystem I/O.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DependencyTree {
    root: IssueId,
    direction: Direction,
    nodes: BTreeMap<IssueId, Node>,
    edges: BTreeMap<(IssueId, IssueId), Edge>,
}

impl DependencyTree {
    pub(crate) fn from_parts(
        root: IssueId,
        direction: Direction,
        nodes: BTreeMap<IssueId, Node>,
        edges: BTreeMap<(IssueId, IssueId), Edge>,
    ) -> Self {
        Self {
            root,
            direction,
            nodes,
            edges,
        }
    }

    pub fn filenames(&self) -> impl Iterator<Item = &[u8]> {
        self.nodes.values().map(|node| node.filename.as_slice())
    }

    pub fn render_human(&self, paths: Option<&OutputPaths>) -> Result<Vec<u8>, QueryError> {
        let mut output = format!("{}\n", self.direction.heading()).into_bytes();
        self.append_node(&mut output, self.root, "", paths)?;
        let edges = self.edges_by_parent(self.direction);
        let children = edges.get(&self.root).map(Vec::as_slice).unwrap_or_default();
        if children.is_empty() {
            output.extend_from_slice("└── (none)\n".as_bytes());
            return Ok(output);
        }
        let mut expanded = BTreeSet::from([self.root]);
        let mut pending = children
            .iter()
            .enumerate()
            .rev()
            .map(|(index, edge)| (*edge, String::new(), index + 1 == children.len()))
            .collect::<Vec<_>>();
        while let Some((edge, prefix, last)) = pending.pop() {
            let id = neighbor_id(edge, self.direction);
            let shared = edge.blocking && !expanded.insert(id);
            output.extend_from_slice(prefix.as_bytes());
            output.extend_from_slice(if last { "└── " } else { "├── " }.as_bytes());
            self.append_node(&mut output, id, if shared { " [shared]" } else { "" }, None)?;

            let continuation = format!("{prefix}{}", if last { "    " } else { "│   " });
            output.extend_from_slice(format!("{continuation}reason: {}\n", edge.reason).as_bytes());
            if let Some(paths) = paths {
                let node = self.nodes.get(&id).expect("selected node exists");
                output.extend_from_slice(continuation.as_bytes());
                output.extend_from_slice(b"path: ");
                output.extend_from_slice(paths.get(&node.filename)?);
                output.push(b'\n');
            }
            if !edge.blocking || shared {
                continue;
            }
            let descendants = edges.get(&id).map(Vec::as_slice).unwrap_or_default();
            pending.extend(descendants.iter().enumerate().rev().map(|(index, child)| {
                (*child, continuation.clone(), index + 1 == descendants.len())
            }));
        }
        Ok(output)
    }

    pub fn render_json(&self, paths: Option<&OutputPaths>) -> Result<Vec<u8>, QueryError> {
        let edges = self.edges_by_parent(Direction::Dependencies);
        let issues = self
            .nodes
            .values()
            .map(|node| {
                let waits_on = edges
                    .get(&node.id)
                    .into_iter()
                    .flatten()
                    .map(|edge| WireRelation {
                        id: edge.dependency.to_string(),
                        reason: &edge.reason,
                    })
                    .collect();
                let path = paths
                    .map(|values| values.get(&node.filename).map(EncodedBytes::new))
                    .transpose()?;
                Ok(WireIssue {
                    id: node.id.to_string(),
                    status: node.status.as_str(),
                    ready: node.ready,
                    title: &node.title,
                    path,
                    waits_on,
                })
            })
            .collect::<Result<Vec<_>, QueryError>>()?;
        let mut output = serde_json::to_vec(&WireTree {
            schema_version: SCHEMA_VERSION,
            root: self.root.to_string(),
            direction: self.direction.as_str(),
            issues,
        })
        .map_err(QueryError::Json)?;
        output.push(b'\n');
        Ok(output)
    }

    fn edges_by_parent(&self, direction: Direction) -> BTreeMap<IssueId, Vec<&Edge>> {
        let mut parents = BTreeMap::<_, Vec<_>>::new();
        for edge in self.edges.values() {
            let parent = match direction {
                Direction::Dependencies => edge.dependent,
                Direction::Dependents => edge.dependency,
            };
            parents.entry(parent).or_default().push(edge);
        }
        parents
    }

    fn append_node(
        &self,
        output: &mut Vec<u8>,
        id: IssueId,
        suffix: &str,
        paths: Option<&OutputPaths>,
    ) -> Result<(), QueryError> {
        let node = self.nodes.get(&id).expect("selected node exists");
        let readiness = match (node.status, node.ready) {
            (Status::Open, true) => "open/ready",
            (Status::Open, false) => "open/waiting",
            (Status::Closed, _) => "closed",
        };
        output
            .extend_from_slice(format!("#{id}  {readiness}  {}{suffix}\n", node.title).as_bytes());
        if id == self.root
            && let Some(paths) = paths
        {
            output.extend_from_slice(b"path: ");
            output.extend_from_slice(paths.get(&node.filename)?);
            output.push(b'\n');
        }
        Ok(())
    }
}

fn neighbor_id(edge: &Edge, direction: Direction) -> IssueId {
    match direction {
        Direction::Dependencies => edge.dependency,
        Direction::Dependents => edge.dependent,
    }
}

#[derive(Serialize)]
struct WireTree<'a> {
    schema_version: u32,
    root: String,
    direction: &'static str,
    issues: Vec<WireIssue<'a>>,
}

#[derive(Serialize)]
struct WireIssue<'a> {
    id: String,
    status: &'static str,
    ready: bool,
    title: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    path: Option<EncodedBytes<'a>>,
    waits_on: Vec<WireRelation<'a>>,
}

#[derive(Serialize)]
struct WireRelation<'a> {
    id: String,
    reason: &'a str,
}
