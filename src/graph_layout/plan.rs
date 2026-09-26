//! Sparse destination tracks: a lane is shared by edges ending at the same node.
use super::{Direction, Graph, LayoutError};
use crate::issue::IssueId;
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;

#[derive(Debug, Clone, Eq, PartialEq, Serialize, Deserialize)]
pub struct Row {
    #[serde(deserialize_with = "deserialize_id")]
    pub(super) id: u16,
    pub(super) lane: usize,
    /// Earliest incoming source row, or None for a root.
    pub(super) start: Option<usize>,
    /// Direct outgoing targets as absolute row indices, in ascending row order.
    pub(super) targets: Vec<usize>,
}

impl Row {
    pub fn id(&self) -> IssueId {
        IssueId::new(self.id).expect("plan construction validates identities")
    }

    pub fn lane(&self) -> usize {
        self.lane
    }

    pub fn targets(&self) -> &[usize] {
        &self.targets
    }

    /// First source row on this node's incoming track, or no track for a root.
    pub fn start(&self) -> Option<usize> {
        self.start
    }
}

/// Deserialization is private and must pass `Plan::decode` before use.
#[derive(Debug, Clone, Eq, PartialEq, Serialize, Deserialize)]
pub(super) struct PlanData {
    pub rows: Vec<Row>,
    pub lanes: usize,
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct Plan {
    pub(super) data: PlanData,
    /// Sorted intervals for boundary lookup without scanning all earlier rows.
    pub(super) lane_tracks: Vec<Vec<usize>>,
}

impl Plan {
    pub fn rows(&self) -> &[Row] {
        &self.data.rows
    }

    pub fn lanes(&self) -> usize {
        self.data.lanes
    }

    pub(super) fn build(ids: &[u16], outgoing: &[Vec<usize>], order: &[usize]) -> Self {
        let mut positions = vec![0; order.len()];
        for (row, &node) in order.iter().enumerate() {
            positions[node] = row;
        }
        let mut rows: Vec<_> = order
            .iter()
            .map(|&node| {
                let mut targets: Vec<_> = outgoing[node].iter().map(|&n| positions[n]).collect();
                targets.sort_unstable();
                Row {
                    id: ids[node],
                    lane: 0,
                    start: None,
                    targets,
                }
            })
            .collect();
        let mut free = BTreeSet::new();
        // Lane zero is exclusively for roots; incoming tracks use higher lanes.
        let mut lanes = usize::from(!rows.is_empty());
        for source in 0..rows.len() {
            let node_lane = rows[source].lane;
            // The incoming track ends here. Prefer continuing this same lane.
            if node_lane != 0 {
                free.insert(node_lane);
            }
            for i in 0..rows[source].targets.len() {
                let target = rows[source].targets[i];
                if rows[target].start.is_none() {
                    let lane = if free.remove(&node_lane) {
                        node_lane
                    } else {
                        allocate_lane(&mut free, &mut lanes)
                    };
                    rows[target].lane = lane;
                    rows[target].start = Some(source);
                }
            }
        }
        Self::index(PlanData { rows, lanes })
    }

    fn index(data: PlanData) -> Self {
        let mut lane_tracks = vec![Vec::new(); data.lanes];
        for (i, row) in data.rows.iter().enumerate() {
            if row.start.is_some() {
                lane_tracks[row.lane].push(i);
            }
        }
        Self { data, lane_tracks }
    }

    pub(super) fn decode(
        data: PlanData,
        graph: &Graph,
        direction: Direction,
    ) -> Result<Self, LayoutError> {
        let invalid = || LayoutError("invalid stored dependency layout".into());
        if data.rows.len() != graph.node_count()
            || data.lanes > graph.node_count()
            || (data.lanes == 0) != data.rows.is_empty()
        {
            return Err(invalid());
        }
        let mut positions = vec![None; usize::from(IssueId::MAX) + 1];
        for (i, row) in data.rows.iter().enumerate() {
            if graph.ids.binary_search(&row.id).is_err()
                || positions[usize::from(row.id)].replace(i).is_some()
                || row.lane >= data.lanes
                || (row.lane == 0) != row.start.is_none()
            {
                return Err(invalid());
            }
        }
        let mut expected = vec![Vec::new(); graph.node_count()];
        for &(dependent, prerequisite) in &graph.edges {
            let (from, to) = match direction {
                Direction::PrerequisitesFirst => (prerequisite, dependent),
                Direction::DependentsFirst => (dependent, prerequisite),
            };
            expected[positions[usize::from(from)].ok_or_else(invalid)?]
                .push(positions[usize::from(to)].ok_or_else(invalid)?);
        }
        let mut starts = vec![None; graph.node_count()];
        for (i, targets) in expected.iter_mut().enumerate() {
            targets.sort_unstable();
            if data.rows[i].targets != *targets || targets.iter().any(|&t| t <= i) {
                return Err(invalid());
            }
            for &target in targets.iter() {
                starts[target].get_or_insert(i);
            }
        }
        let mut occupied_until = vec![None; data.lanes];
        // Destination rows are ordered; intervals in each lane may touch, not overlap.
        for (i, row) in data.rows.iter().enumerate() {
            if row.start != starts[i] {
                return Err(invalid());
            }
            let start = row.start.unwrap_or(i);
            if occupied_until[row.lane].is_some_and(|end| end > start) {
                return Err(invalid());
            }
            if occupied_until[row.lane] == Some(start)
                && data.rows[start].targets.binary_search(&i).is_err()
            {
                return Err(invalid());
            }
            occupied_until[row.lane] = Some(i);
        }
        Ok(Self::index(data))
    }
}

fn deserialize_id<'de, D: serde::Deserializer<'de>>(deserializer: D) -> Result<u16, D::Error> {
    let value = u16::deserialize(deserializer)?;
    IssueId::new(value)
        .map(IssueId::get)
        .ok_or_else(|| serde::de::Error::custom("invalid graph issue ID"))
}

fn allocate_lane(free: &mut BTreeSet<usize>, lanes: &mut usize) -> usize {
    free.pop_first().unwrap_or_else(|| {
        let lane = *lanes;
        *lanes += 1;
        lane
    })
}
