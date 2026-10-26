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
    let mut reservations = root_reservations(vertices).into_iter().peekable();
    let mut free = BTreeSet::new();
    let (mut reserve, mut next_lane, mut lanes) = (0, 0, 0);
    let mut nodes = Vec::with_capacity(vertices.len());
    let mut routes = Vec::new();
    let mut split = Vec::new();
    for (source, vertex) in vertices.iter().enumerate() {
        if let Some((_, pressure)) = reservations.next_if(|&(start, _)| start == source) {
            reserve = pressure;
            free = (1..=reserve).collect();
            next_lane = reserve + 1;
        }
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
            || {
                allocate(
                    &mut free,
                    &mut next_lane,
                    lane,
                    vertex.targets.len(),
                    reserve,
                )
            },
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
        lanes = lanes.max(next_lane);
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

/// Reserve simultaneous root tracks separately for each contiguous component.
/// Singleton routes to one target may share a track.
fn root_reservations(vertices: &[Vertex]) -> Vec<(usize, usize)> {
    let mut incoming = vec![false; vertices.len()];
    for vertex in vertices {
        for &target in &vertex.targets {
            incoming[target] = true;
        }
    }
    let mut endings = vec![0; vertices.len()];
    let mut singletons = BTreeSet::new();
    let (mut active, mut maximum) = (0, 0);
    let (mut start, mut end) = (0, 0);
    let mut reservations = Vec::new();
    for (source, vertex) in vertices.iter().enumerate() {
        // Ordering keeps components contiguous. Once no edge reaches beyond
        // this row, the next row starts an independent lane allocation.
        end = end.max(vertex.targets.last().copied().unwrap_or(source));
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
        if source == end {
            reservations.push((start, maximum));
            start = source + 1;
            maximum = 0;
            singletons.clear();
        }
    }
    reservations
}

#[cfg(test)]
mod tests;
