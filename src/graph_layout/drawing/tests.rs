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
    let mut outgoing = vec![Vec::new(); drawing.steps.len()];
    let mut incoming = vec![Vec::new(); drawing.steps.len()];
    let mut intervals = vec![Vec::new(); drawing.lanes];
    for route in &drawing.routes {
        assert!(route.source < route.target);
        assert!(route.lane > 0 && route.lane < drawing.lanes);
        assert!(drawing.steps[route.source].lane <= route.lane);
        assert!(route.lane <= drawing.steps[route.target].lane);
        outgoing[route.source].push(route.target);
        incoming[route.target].push(route.lane);
        intervals[route.lane].push((route.source, route.target));
    }
    let mut next_row = 0;
    for (index, step) in drawing.steps.iter().enumerate() {
        assert_eq!(step.lane == 0, incoming[index].is_empty());
        if let Some(row) = step.row {
            assert_eq!(row, next_row);
            next_row += 1;
            let mut pending = outgoing[index].clone();
            let mut actual = Vec::new();
            while let Some(target) = pending.pop() {
                if let Some(row) = drawing.steps[target].row {
                    actual.push(row);
                } else {
                    pending.extend(&outgoing[target]);
                }
            }
            actual.sort_unstable();
            assert_eq!(
                actual,
                plan.rows()[row].targets(),
                "invented or missing edge"
            );
        } else {
            assert!(!outgoing[index].is_empty());
            let merges = incoming[index].iter().any(|&lane| lane < step.lane);
            let forks = drawing
                .routes
                .iter()
                .any(|r| r.source == index && r.lane > step.lane);
            assert!(!(merges && forks), "mixed merge/fork bar");
        }
        for &(start, end) in &intervals[step.lane] {
            assert!(
                index <= start || index >= end,
                "unrelated track crosses a node"
            );
        }
    }
    assert_eq!(next_row, plan.rows().len());
    for tracks in intervals {
        for pair in tracks.windows(2) {
            if pair[0].1 > pair[1].0 {
                assert_eq!(pair[0].1, pair[1].1);
                assert_eq!(outgoing[pair[1].0].len(), 1, "unsafe shared track");
            }
        }
    }
}

#[test]
fn every_small_dag_preserves_edges_and_right_down_routes() {
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
fn partial_overlap_keeps_the_later_branch_out_of_the_merge() {
    let plan = plan(
        5,
        &[(3, 1), (4, 1), (4, 2), (5, 2)],
        Direction::PrerequisitesFirst,
    );
    verify(&plan);
    assert_eq!(
        plan.rows().iter().map(|r| r.id().get()).collect::<Vec<_>>(),
        [1, 3, 2, 4, 5]
    );
}

#[test]
fn repeated_diamonds_may_widen_but_never_reverse_flow() {
    let edges: Vec<_> = (0..20)
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
    for direction in [Direction::PrerequisitesFirst, Direction::DependentsFirst] {
        let plan = plan(61, &edges, direction);
        verify(&plan);
        assert!(plan.drawing().lanes <= 22);
    }
}

#[test]
fn chain_and_independent_issues_need_no_connector_rows_or_extra_width() {
    let chain: Vec<_> = (2..=9999).map(|n| (n, n - 1)).collect();
    let plan = plan(9999, &chain, Direction::PrerequisitesFirst);
    let drawing = plan.drawing();
    assert_eq!(drawing.lanes, 2);
    assert_eq!(drawing.routes.len(), 9998);
    let empty = super::tests::plan(9999, &[], Direction::PrerequisitesFirst);
    assert_eq!(empty.drawing().lanes, 1);
}

#[test]
fn drawing_case_library_matches_the_frontend_fixtures() {
    use serde_json::{Value, json};
    let inputs: Value = serde_json::from_str(include_str!(
        "../../../tests/fixtures/dependency-cases.json"
    ))
    .unwrap();
    let mut cases = Vec::new();
    for case in inputs.as_array().unwrap() {
        let names = case["nodes"].as_array().unwrap();
        let id = |name: &Value| {
            name.as_str()
                .unwrap()
                .parse::<u16>()
                .unwrap_or_else(|_| (names.iter().position(|n| n == name).unwrap() + 1) as u16)
        };
        let graph = Graph::new(
            names.iter().map(|n| IssueId::new(id(n)).unwrap()),
            case["must_precede"].as_array().unwrap().iter().map(|e| {
                (
                    IssueId::new(id(&e[1])).unwrap(),
                    IssueId::new(id(&e[0])).unwrap(),
                )
            }),
            usize::MAX,
        )
        .unwrap();
        for (name, direction) in [
            ("prerequisites", Direction::PrerequisitesFirst),
            ("dependents", Direction::DependentsFirst),
        ] {
            let plan = graph.layout(direction).unwrap();
            verify(&plan);
            let rows: Vec<_> = plan.rows().iter().map(|r| json!({"id":format!("{:04}",r.id().get()), "lane":r.lane(), "start":r.start(), "targets":r.targets()})).collect();
            cases.push(json!({"case":case["id"],"direction":name,"plan":{"lanes":plan.lanes(),"rows":rows,"drawing":plan.drawing()}}));
        }
    }
    let actual = serde_json::to_string_pretty(&cases).unwrap() + "\n";
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/dependency-drawings.json");
    if std::env::var_os("ISLED_UPDATE_DRAWINGS").is_some() {
        std::fs::write(&path, &actual).unwrap();
    }
    assert_eq!(actual, std::fs::read_to_string(path).unwrap());
}
