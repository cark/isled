//! Sparse right/down routes, with sharing restricted to complete target sets.
use super::Plan;
use serde::Serialize;
use std::collections::{BTreeSet, HashMap};

/// First versioned drawing format; replaces the old unversioned lane steps.
pub const VERSION: u32 = 1;

#[derive(Debug, Serialize)]
pub struct Drawing {
    version: u32,
    lanes: usize,
    steps: Vec<Step>,
    routes: Vec<Route>,
}

#[derive(Debug, Serialize)]
struct Step {
    row: Option<usize>,
    lane: usize,
}

/// Right from source, down this track, then right to target.
#[derive(Debug, Serialize)]
struct Route {
    source: usize,
    target: usize,
    lane: usize,
}

struct Vertex {
    row: Option<usize>,
    targets: Vec<usize>,
}

impl Plan {
    /// O((V + E) log E) time and O(V + E) space; no glyph matrix or search.
    pub fn drawing(&self) -> Drawing {
        place(&vertices(self))
    }
}

/// Factor identical complete target sets through one routing-only fork.
fn vertices(plan: &Plan) -> Vec<Vertex> {
    let mut lookup = HashMap::new();
    let mut groups: Vec<Vec<usize>> = Vec::new();
    for (source, row) in plan.rows().iter().enumerate() {
        if row.targets().len() > 1 {
            let group = *lookup.entry(row.targets()).or_insert_with(|| {
                groups.push(Vec::new());
                groups.len() - 1
            });
            groups[group].push(source);
        }
    }
    let mut endings = vec![None; plan.rows().len()];
    let mut membership = vec![None; plan.rows().len()];
    for (group, sources) in groups.iter().enumerate().filter(|(_, s)| s.len() > 1) {
        endings[*sources.last().unwrap()] = Some(group);
        for &source in sources {
            membership[source] = Some(group);
        }
    }
    let mut positions = Vec::new();
    let mut junctions = vec![0; groups.len()];
    let mut result = Vec::new();
    for (row, group) in endings.into_iter().enumerate() {
        positions.push(result.len());
        result.push(Vertex {
            row: Some(row),
            targets: Vec::new(),
        });
        if let Some(group) = group {
            junctions[group] = result.len();
            result.push(Vertex {
                row: None,
                targets: plan.rows()[row].targets().to_vec(),
            });
        }
    }
    for vertex in &mut result {
        vertex.targets = if let Some(row) = vertex.row {
            membership[row].map_or_else(
                || {
                    plan.rows()[row]
                        .targets()
                        .iter()
                        .map(|&r| positions[r])
                        .collect()
                },
                |group| vec![junctions[group]],
            )
        } else {
            vertex.targets.iter().map(|&r| positions[r]).collect()
        };
    }
    result
}

fn place(vertices: &[Vertex]) -> Drawing {
    let mut incoming = vec![BTreeSet::new(); vertices.len()];
    let reserve = root_pressure(vertices);
    let mut free: BTreeSet<_> = (1..=reserve).collect();
    let mut lanes = if vertices.is_empty() { 0 } else { reserve + 1 };
    let mut nodes = Vec::with_capacity(vertices.len());
    let mut routes = Vec::new();
    let mut split = Vec::new();
    for (source, vertex) in vertices.iter().enumerate() {
        let lane = incoming[source].last().copied().unwrap_or(0);
        nodes.push(lane);
        // A routing-only merge and fork occupy separate lines. Issue nodes
        // already separate their own incoming and outgoing dependencies.
        split.push(vertex.row.is_none() && incoming[source].len() > 1);
        free.extend(incoming[source].iter().copied());
        let shared = if let [target] = vertex.targets[..] {
            incoming[target].range(lane.max(1)..).next().copied()
        } else {
            None
        };
        let mut allocated = shared.map_or_else(
            || allocate(&mut free, &mut lanes, lane, vertex.targets.len(), reserve),
            |track| vec![track],
        );
        allocated.sort_unstable();
        for (&target, track) in vertex.targets.iter().zip(allocated.into_iter().rev()) {
            incoming[target].insert(track);
            routes.push(Route {
                source,
                target,
                lane: track,
            });
        }
    }
    physical_steps(vertices, nodes, routes, split, lanes)
}

fn physical_steps(
    vertices: &[Vertex],
    nodes: Vec<usize>,
    routes: Vec<Route>,
    split: Vec<bool>,
    lanes: usize,
) -> Drawing {
    let mut starts = Vec::new();
    let mut ends = Vec::new();
    let mut steps = Vec::new();
    let mut physical = Vec::new();
    for (index, vertex) in vertices.iter().enumerate() {
        starts.push(steps.len());
        steps.push(Step {
            row: vertex.row,
            lane: nodes[index],
        });
        if split[index] {
            physical.push(Route {
                source: steps.len() - 1,
                target: steps.len(),
                lane: nodes[index],
            });
            steps.push(Step {
                row: None,
                lane: nodes[index],
            });
        }
        ends.push(steps.len() - 1);
    }
    physical.extend(routes.into_iter().map(|r| Route {
        source: ends[r.source],
        target: starts[r.target],
        lane: r.lane,
    }));
    physical.sort_unstable_by_key(|r| (r.source, r.target));
    Drawing {
        version: VERSION,
        lanes,
        steps,
        routes: physical,
    }
}

fn allocate(
    free: &mut BTreeSet<usize>,
    lanes: &mut usize,
    source: usize,
    count: usize,
    reserve: usize,
) -> Vec<usize> {
    let mut result = Vec::with_capacity(count);
    for _ in 0..count {
        let available = if source == 0 {
            free.range(..=reserve)
                .next_back()
                .or_else(|| free.first())
                .copied()
        } else {
            free.range(source..).next().copied()
        };
        let lane = available.unwrap_or_else(|| {
            let lane = *lanes;
            *lanes += 1;
            lane
        });
        free.remove(&lane);
        result.push(lane);
    }
    result
}

/// Simultaneous root tracks; singleton routes to one target may share a track.
fn root_pressure(vertices: &[Vertex]) -> usize {
    let mut incoming = vec![false; vertices.len()];
    for vertex in vertices {
        for &target in &vertex.targets {
            incoming[target] = true;
        }
    }
    let mut endings = vec![0; vertices.len()];
    let mut singletons = BTreeSet::new();
    let (mut active, mut maximum) = (0, 0);
    for (source, vertex) in vertices.iter().enumerate() {
        active -= endings[source];
        if !incoming[source] {
            for &target in &vertex.targets {
                if vertex.targets.len() > 1 || singletons.insert(target) {
                    active += 1;
                    endings[target] += 1;
                }
            }
        }
        maximum = maximum.max(active);
    }
    maximum
}

#[cfg(test)]
mod tests;
