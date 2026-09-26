//! Sparse drawing steps, sharing only complete sets of outgoing dependencies.
use super::Plan;
use serde::Serialize;
use std::collections::{BTreeSet, HashMap};

#[derive(Debug, Serialize)]
pub struct Drawing {
    lanes: usize,
    steps: Vec<Step>,
}

#[derive(Debug, Serialize)]
struct Step {
    /// Semantic row, or a routing-only shared junction.
    row: Option<usize>,
    lane: usize,
    start: Option<usize>,
    /// Shared junction step, only present on participating source rows.
    #[serde(skip_serializing_if = "Option::is_none")]
    join: Option<usize>,
    /// Semantic destinations, only present on shared junctions.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    targets: Vec<usize>,
    #[serde(skip)]
    outgoing: Vec<usize>,
}

impl Step {
    fn new(row: Option<usize>, targets: Vec<usize>) -> Self {
        Self {
            row,
            lane: 0,
            start: None,
            join: None,
            targets,
            outgoing: Vec::new(),
        }
    }
}

impl Plan {
    /// Drawing metadata supplements the unchanged direct-edge plan. Each group
    /// shares its complete outgoing set, never just overlapping destinations.
    pub fn drawing(&self) -> Drawing {
        let groups = shared_sources(self);
        let mut endings = vec![None; self.rows().len()];
        let mut membership = vec![None; self.rows().len()];
        for (group, sources) in groups.iter().enumerate() {
            endings[*sources.last().unwrap()] = Some(group);
            for &source in sources {
                membership[source] = Some(group);
            }
        }
        let mut positions = Vec::with_capacity(self.rows().len());
        let mut junctions = vec![0; groups.len()];
        let mut steps = Vec::with_capacity(self.rows().len() + groups.len());
        for (row, group) in endings.into_iter().enumerate() {
            positions.push(steps.len());
            steps.push(Step::new(Some(row), Vec::new()));
            if let Some(group) = group {
                junctions[group] = steps.len();
                steps.push(Step::new(None, self.rows()[row].targets().to_vec()));
            }
        }
        for step in &mut steps {
            if let Some(row) = step.row {
                step.join = membership[row].map(|group| junctions[group]);
                step.outgoing = match step.join {
                    Some(junction) => vec![junction],
                    None => self.rows()[row]
                        .targets()
                        .iter()
                        .map(|&r| positions[r])
                        .collect(),
                };
            } else {
                step.outgoing = step.targets.iter().map(|&r| positions[r]).collect();
            }
        }
        let lanes = place_lanes(&mut steps, self.lanes());
        Drawing { lanes, steps }
    }
}

fn shared_sources(plan: &Plan) -> Vec<Vec<usize>> {
    let mut lookup = HashMap::new();
    let mut groups: Vec<Vec<usize>> = Vec::new();
    for (source, row) in plan.rows().iter().enumerate() {
        if row.targets().len() < 2 {
            continue;
        }
        let group = *lookup.entry(row.targets()).or_insert_with(|| {
            groups.push(Vec::new());
            groups.len() - 1
        });
        groups[group].push(source);
    }
    groups
        .into_iter()
        .filter(|sources| sources.len() > 1)
        .collect()
}

fn place_lanes(steps: &mut [Step], preferred_width: usize) -> usize {
    let mut lanes = usize::from(!steps.is_empty());
    let mut free = BTreeSet::new();
    for source in 0..steps.len() {
        let lane = steps[source].lane;
        if lane > 0 {
            free.insert(lane);
        }
        let targets: Vec<_> = steps[source]
            .outgoing
            .iter()
            .copied()
            .filter(|&target| steps[target].start.is_none())
            .collect();
        let allocated =
            allocate_tracks(&mut free, &mut lanes, lane, targets.len(), preferred_width);
        // Visit the right-hand branch first, leaving later branches on its left.
        for (target, lane) in targets.into_iter().zip(allocated.into_iter().rev()) {
            steps[target].lane = lane;
            steps[target].start = Some(source);
        }
    }
    lanes
}

fn allocate_tracks(
    free: &mut BTreeSet<usize>,
    lanes: &mut usize,
    source: usize,
    count: usize,
    preferred_width: usize,
) -> Vec<usize> {
    if count == 0 {
        return Vec::new();
    }
    let above = source.max(1);
    let below = source.checked_sub(count - 1).filter(|&start| start > 0);
    let start = std::iter::once(above)
        .chain(below)
        .filter(|&start| (start..start + count).all(|lane| lane >= *lanes || free.contains(&lane)))
        // The direct-edge plan already provides a useful width allowance.
        // Prefer rightward splits within it, but reuse a block below the source
        // before growing beyond it on consecutive diamonds or shared layers.
        .min_by_key(|&start| preferred_width.max(start + count));
    if let Some(start) = start {
        let result: Vec<_> = (start..start + count).collect();
        for lane in &result {
            free.remove(lane);
        }
        *lanes = (*lanes).max(start + count);
        result
    } else {
        let mut result: Vec<_> = (0..count)
            .map(|_| {
                free.pop_first().unwrap_or_else(|| {
                    let lane = *lanes;
                    *lanes += 1;
                    lane
                })
            })
            .collect();
        result.sort_unstable();
        result
    }
}

#[cfg(test)]
mod tests;
