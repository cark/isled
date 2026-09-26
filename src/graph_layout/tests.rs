use super::*;
use std::collections::{BTreeMap, BTreeSet};

fn id(n: u16) -> IssueId {
    IssueId::new(n).unwrap()
}

fn graph(n: u16, edges: &[(u16, u16)]) -> Graph {
    Graph::new(
        (1..=n).map(id),
        edges.iter().map(|&(a, b)| (id(a), id(b))),
        usize::MAX,
    )
    .unwrap()
}

fn verify(plan: &Plan, graph: &Graph, direction: Direction) {
    for row in plan.rows() {
        assert_eq!(row.lane() == 0, row.start().is_none());
    }
    assert_eq!(
        plan.rows()
            .iter()
            .map(|r| r.id().get())
            .collect::<BTreeSet<_>>(),
        graph.ids.iter().copied().collect()
    );
    let actual: BTreeSet<_> = plan
        .rows()
        .iter()
        .enumerate()
        .flat_map(|(i, row)| {
            row.targets().iter().map(move |&target| {
                assert!(target > i);
                match direction {
                    Direction::PrerequisitesFirst => {
                        (plan.rows()[target].id().get(), row.id().get())
                    }
                    Direction::DependentsFirst => (row.id().get(), plan.rows()[target].id().get()),
                }
            })
        })
        .collect();
    assert_eq!(actual, graph.edges.iter().copied().collect());
    assert_eq!(
        &Plan::decode(plan.data.clone(), graph, direction).unwrap(),
        plan
    );
    let full = plan.range(0..plan.rows().len()).unwrap();
    // An independent active-track sweep verifies every possible slice boundary.
    let mut active = BTreeMap::new();
    for start in 0..=full.rows.len() {
        let expected: Vec<_> = active
            .iter()
            .map(|(&lane, &target_row)| Continuation {
                lane,
                target_row,
                target_id: full.rows[target_row].id,
            })
            .collect();
        for end in start..=full.rows.len() {
            let part = plan.range(start..end).unwrap();
            assert_eq!(part.rows, full.rows[start..end]);
            assert_eq!(part.entry, expected);
            assert_eq!(part.exit, plan.range(end..end).unwrap().entry);
        }
        if let Some(row) = full.rows.get(start) {
            if let Some(target) = active.remove(&row.lane) {
                assert_eq!(target, start);
            }
            for route in &row.outgoing {
                if let Some(previous) = active.insert(route.lane, route.target_row) {
                    assert_eq!(previous, route.target_row, "distinct tracks overlap");
                }
            }
        }
    }
    assert!(active.is_empty());
}

#[test]
fn exhaustive_small_dags_preserve_topology_lanes_and_every_range() {
    let possible: Vec<_> = (1_u16..=5)
        .flat_map(|a| (a + 1..=5).map(move |b| (b, a)))
        .collect();
    for bits in 0..1_u32 << possible.len() {
        let edges: Vec<_> = possible
            .iter()
            .enumerate()
            .filter(|(i, _)| bits & (1 << i) != 0)
            .map(|(_, e)| *e)
            .collect();
        for permutation in [[1, 2, 3, 4, 5], [5, 1, 4, 2, 3], [3, 5, 1, 4, 2]] {
            let mapped: Vec<_> = edges
                .iter()
                .map(|&(a, b)| {
                    (
                        permutation[usize::from(a - 1)],
                        permutation[usize::from(b - 1)],
                    )
                })
                .collect();
            let graph = graph(5, &mapped);
            for direction in [Direction::PrerequisitesFirst, Direction::DependentsFirst] {
                let plan = graph.layout(direction).unwrap();
                verify(&plan, &graph, direction);
            }
        }
    }
}

#[test]
fn canonical_inputs_chains_and_disconnected_groups_are_stable() {
    let graph = graph(6, &[(2, 1), (3, 2), (5, 4), (6, 5)]);
    let reordered = Graph::new(
        (1..=6).rev().map(id),
        [(6, 5), (2, 1), (5, 4), (3, 2), (2, 1)].map(|(a, b)| (id(a), id(b))),
        10,
    )
    .unwrap();
    for direction in [Direction::PrerequisitesFirst, Direction::DependentsFirst] {
        let plan = graph.layout(direction).unwrap();
        assert_eq!(plan, reordered.layout(direction).unwrap());
        assert_eq!(plan.lanes(), 2);
        verify(&plan, &graph, direction);
    }
    let edges: Vec<_> = (2..=9999).map(|n| (n, n - 1)).collect();
    let plan = self::graph(9999, &edges)
        .layout(Direction::PrerequisitesFirst)
        .unwrap();
    assert_eq!(plan.lanes(), 2);
    assert_eq!(plan.range(4990..5022).unwrap().rows.len(), 32);
    assert_eq!(plan.lane_tracks.iter().map(Vec::len).sum::<usize>(), 9998);
}

#[test]
fn connected_groups_stay_intact_with_independents_in_id_order() {
    // Independent 1 precedes a group starting at 2; 3 and 4 follow it. Root 8
    // must stay with 2 while their join waits, ahead of unrelated root 5.
    let graph = graph(9, &[(7, 2), (9, 7), (9, 8), (6, 5)]);
    for (direction, expected) in [
        (
            Direction::PrerequisitesFirst,
            vec![1, 2, 7, 8, 9, 3, 4, 5, 6],
        ),
        (Direction::DependentsFirst, vec![1, 9, 8, 7, 2, 3, 4, 6, 5]),
    ] {
        let plan = graph.layout(direction).unwrap();
        assert_eq!(
            plan.rows()
                .iter()
                .map(|row| row.id().get())
                .collect::<Vec<_>>(),
            expected
        );
        verify(&plan, &graph, direction);
    }
}

#[test]
fn selection_never_bridges_excluded_nodes_and_cycles_fail() {
    let selected = Graph::new([id(1), id(3)], [(id(3), id(2)), (id(2), id(1))], 10).unwrap();
    assert_eq!(selected.edge_count(), 0);
    assert!(
        graph(2, &[(1, 2), (2, 1)])
            .layout(Direction::PrerequisitesFirst)
            .is_err()
    );
    assert!(
        graph(1, &[(1, 1)])
            .layout(Direction::DependentsFirst)
            .is_err()
    );
    assert!(Graph::new([id(1), id(1)], [], 10).is_err());
    assert!(Graph::new([id(1), id(2)], [(id(1), id(2))], 0).is_err());
    let empty = graph(0, &[]).layout(Direction::PrerequisitesFirst).unwrap();
    assert_eq!(
        empty
            .range(0..0)
            .unwrap()
            .text(&BTreeMap::new(), 0)
            .unwrap(),
        ""
    );
    assert!(empty.range(1..1).is_err());
}

#[test]
fn invalid_stored_plans_are_rejected_at_the_construction_boundary() {
    let graph = graph(4, &[(2, 1), (3, 1), (4, 2), (4, 3)]);
    let plan = graph.layout(Direction::PrerequisitesFirst).unwrap();
    for corrupt in 0..7 {
        let mut data = plan.data.clone();
        match corrupt {
            0 => data.rows[0].id = 0,
            1 => data.rows[0].id = data.rows[1].id,
            2 => data.rows[0].targets.push(99999),
            3 => data.rows[0].lane = 99999,
            4 => data.rows[1].start = Some(99999),
            5 => data.rows[0].targets.clear(),
            _ => data.lanes = 99999,
        }
        assert!(Plan::decode(data, &graph, Direction::PrerequisitesFirst).is_err());
    }
}

#[test]
fn diagnostic_text_aligns_unique_titles_and_refuses_wide_output() {
    let plan = graph(4, &[(2, 1), (3, 1), (4, 2), (4, 3)])
        .layout(Direction::PrerequisitesFirst)
        .unwrap();
    let labels = (1..=4).map(|i| (i, format!("Issue {i}"))).collect();
    let range = plan.range(0..4).unwrap();
    let text = range.text(&labels, 4).unwrap();
    assert_eq!(text.matches('●').count(), 4);
    let columns: BTreeSet<_> = text
        .lines()
        .filter_map(|line| line.find("Issue").map(|at| line[..at].chars().count()))
        .collect();
    assert_eq!(columns.len(), 1);
    assert!(range.text(&labels, 1).is_err());
    let slice = plan.range(1..3).unwrap().text(&labels, 4).unwrap();
    assert!(slice.contains("continues from earlier"));
    assert!(slice.contains("continue into later"));
}
