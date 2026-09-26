//! Deterministic graph shapes shared by the diagnostic executable and tests.
use clap::ValueEnum;
use isled::{
    graph_layout::{Graph, LayoutError},
    issue::IssueId,
};

#[derive(Debug, Clone, Copy, ValueEnum)]
pub enum Shape {
    ShortChains,
    Chain,
    Fanout,
    Fanin,
    Diamonds,
    Joins,
    LongSpans,
    Dense,
}

pub fn graph(shape: Shape, nodes: u16, max_edges: usize) -> Result<Graph, LayoutError> {
    let mut edges = Vec::new();
    match shape {
        Shape::ShortChains => {
            for i in 2..=nodes {
                if i % 5 != 1 {
                    edges.push((i, i - 1));
                }
            }
        }
        Shape::Chain => {
            for i in 2..=nodes {
                edges.push((i, i - 1));
            }
        }
        Shape::Fanout => {
            for i in 2..=nodes {
                edges.push((i, 1));
            }
        }
        Shape::Fanin => {
            for i in 1..nodes {
                edges.push((nodes, i));
            }
        }
        Shape::Diamonds => {
            for root in (1..nodes).step_by(3) {
                for branch in root + 1..=(root + 2).min(nodes) {
                    edges.push((branch, root));
                    if root + 3 <= nodes {
                        edges.push((root + 3, branch));
                    }
                }
            }
        }
        Shape::Joins | Shape::Dense => {
            let width = if matches!(shape, Shape::Dense) { 64 } else { 8 };
            for target in width + 1..=nodes {
                let prior = ((target - 1) / width - 1) * width + 1;
                for source in prior..prior + width {
                    edges.push((target, source));
                }
            }
        }
        Shape::LongSpans => {
            for i in 2..=nodes {
                edges.push((i, i - 1));
            }
            for i in nodes / 2 + 1..=nodes {
                if i > 1 {
                    edges.push((i, i - nodes / 2));
                }
            }
        }
    }
    Graph::new(
        (1..=nodes).map(|n| IssueId::new(n).unwrap()),
        edges
            .into_iter()
            .map(|(a, b)| (IssueId::new(a).unwrap(), IssueId::new(b).unwrap())),
        max_edges,
    )
}
