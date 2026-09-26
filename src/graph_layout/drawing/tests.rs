use super::*;
use crate::{
    graph_layout::{Direction, Graph},
    issue::IssueId,
};

fn plan(count: u16, edges: &[(u16, u16)], direction: Direction) -> Plan {
    Graph::new(
        (1..=count).map(|n| IssueId::new(n).unwrap()),
        edges
            .iter()
            .map(|&(a, b)| (IssueId::new(a).unwrap(), IssueId::new(b).unwrap())),
        usize::MAX,
    )
    .unwrap()
    .layout(direction)
    .unwrap()
}

fn verify(plan: &Plan) {
    let drawing = plan.drawing();
    let mut incoming = vec![None; drawing.steps.len()];
    let mut occupied = vec![None; drawing.lanes];
    let mut next_row = 0;
    for (index, step) in drawing.steps.iter().enumerate() {
        assert_eq!(step.start, incoming[index]);
        assert_eq!(step.lane == 0, step.start.is_none());
        if let Some(end) = occupied[step.lane] {
            assert!(end <= step.start.unwrap_or(index));
        }
        occupied[step.lane] = Some(index);
        for &target in &step.outgoing {
            assert!(target > index);
            incoming[target].get_or_insert(index);
        }
        if let Some(row) = step.row {
            assert_eq!(row, next_row);
            next_row += 1;
            let mut actual: Vec<_> = step
                .outgoing
                .iter()
                .flat_map(|&target| {
                    let destination = &drawing.steps[target];
                    if let Some(row) = destination.row {
                        vec![row]
                    } else {
                        destination.targets.clone()
                    }
                })
                .collect();
            actual.sort_unstable();
            assert_eq!(
                actual,
                plan.rows()[row].targets(),
                "sharing invented or lost an edge"
            );
        } else {
            assert!(step.targets.len() > 1);
            assert!(
                step.outgoing
                    .iter()
                    .all(|&target| drawing.steps[target].row.is_some())
            );
        }
    }
    assert_eq!(next_row, plan.rows().len());
}

#[test]
fn every_small_dag_keeps_exact_edges_when_sharing_and_placing_tracks() {
    let pairs: Vec<_> = (1..=5)
        .flat_map(|a| (a + 1..=5).map(move |b| (b, a)))
        .collect();
    for bits in 0..1 << pairs.len() {
        let edges: Vec<_> = pairs
            .iter()
            .enumerate()
            .filter(|(i, _)| bits & (1 << i) != 0)
            .map(|(_, e)| *e)
            .collect();
        for direction in [Direction::PrerequisitesFirst, Direction::DependentsFirst] {
            verify(&plan(5, &edges, direction));
        }
    }
}

#[test]
fn illustrative_shared_prerequisites_merge_before_they_split() {
    let plan = plan(
        9,
        &[
            (2, 1),
            (4, 1),
            (5, 2),
            (5, 4),
            (8, 2),
            (8, 4),
            (6, 5),
            (7, 5),
            (9, 6),
            (9, 7),
            (9, 8),
        ],
        Direction::PrerequisitesFirst,
    );
    verify(&plan);
    let drawing = plan.drawing();
    let actual: Vec<_> = drawing
        .steps
        .iter()
        .map(|s| (s.row.map(|r| plan.rows()[r].id().get()), s.lane))
        .collect();
    assert_eq!(
        actual,
        vec![
            (Some(1), 0),
            (Some(2), 2),
            (Some(4), 1),
            (None, 2),
            (Some(8), 3),
            (Some(5), 2),
            (Some(6), 2),
            (Some(7), 1),
            (Some(9), 3),
            (Some(3), 0)
        ]
    );
}

#[test]
fn overlapping_destination_sets_are_not_shared() {
    let plan = plan(
        5,
        &[(3, 1), (4, 1), (3, 2), (5, 2)],
        Direction::PrerequisitesFirst,
    );
    let drawing = plan.drawing();
    assert!(drawing.steps.iter().all(|step| step.row.is_some()));
    verify(&plan);
}

#[test]
fn repeated_branches_reuse_width_instead_of_drifting_right() {
    let diamonds: Vec<_> = (0..20)
        .flat_map(|n| {
            let root = 1 + n * 3;
            [
                (root + 1, root),
                (root + 2, root),
                (root + 3, root + 1),
                (root + 3, root + 2),
            ]
        })
        .collect();
    let layers: Vec<_> = (0..19)
        .flat_map(|layer| {
            (1..=4).flat_map(move |source| {
                (1..=4).map(move |target| ((layer + 1) * 4 + target, layer * 4 + source))
            })
        })
        .collect();
    for direction in [Direction::PrerequisitesFirst, Direction::DependentsFirst] {
        let diamonds = plan(61, &diamonds, direction);
        verify(&diamonds);
        assert_eq!(diamonds.drawing().lanes, 3);
        let layers = plan(80, &layers, direction);
        verify(&layers);
        assert!(layers.drawing().lanes <= layers.lanes());
    }
}
