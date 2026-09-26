use crate::issue::IssueId;
use std::collections::{BTreeMap, BTreeSet};

pub type Adjacency = BTreeMap<IssueId, BTreeSet<IssueId>>;

pub fn reaches(adjacency: &Adjacency, start: IssueId, goal: IssueId) -> bool {
    let mut pending = vec![start];
    let mut seen = BTreeSet::new();
    while let Some(node) = pending.pop() {
        if node == goal {
            return true;
        }
        if !seen.insert(node) {
            continue;
        }
        if let Some(neighbors) = adjacency.get(&node) {
            pending.extend(neighbors.iter().rev().copied());
        }
    }
    false
}

pub fn cyclic_components(adjacency: &Adjacency) -> Vec<Vec<IssueId>> {
    let mut nodes = BTreeSet::new();
    let mut reverse = Adjacency::new();
    for (&source, targets) in adjacency {
        nodes.insert(source);
        for &target in targets {
            nodes.insert(target);
            reverse.entry(target).or_default().insert(source);
        }
    }

    let mut seen = BTreeSet::new();
    let mut order = Vec::new();
    for &root in &nodes {
        if seen.contains(&root) {
            continue;
        }
        let mut stack = vec![(root, false)];
        while let Some((node, finished)) = stack.pop() {
            if finished {
                order.push(node);
                continue;
            }
            if !seen.insert(node) {
                continue;
            }
            stack.push((node, true));
            if let Some(neighbors) = adjacency.get(&node) {
                for &neighbor in neighbors.iter().rev() {
                    if !seen.contains(&neighbor) {
                        stack.push((neighbor, false));
                    }
                }
            }
        }
    }

    let mut assigned = BTreeSet::new();
    let mut components = Vec::new();
    for root in order.into_iter().rev() {
        if !assigned.insert(root) {
            continue;
        }
        let mut component = Vec::new();
        let mut stack = vec![root];
        while let Some(node) = stack.pop() {
            component.push(node);
            if let Some(neighbors) = reverse.get(&node) {
                for &neighbor in neighbors.iter().rev() {
                    if assigned.insert(neighbor) {
                        stack.push(neighbor);
                    }
                }
            }
        }
        component.sort_unstable();
        let self_loop = component.len() == 1
            && adjacency
                .get(&component[0])
                .is_some_and(|targets| targets.contains(&component[0]));
        if component.len() > 1 || self_loop {
            components.push(component);
        }
    }
    components.sort();
    components
}

#[cfg(test)]
mod tests {
    use super::*;

    fn id(value: u16) -> IssueId {
        IssueId::new(value).unwrap()
    }

    #[test]
    fn iterative_traversal_finds_reachability_and_components() {
        let mut graph = Adjacency::new();
        for value in 1..5_001 {
            graph.entry(id(value)).or_default().insert(id(value + 1));
        }
        graph.entry(id(5_001)).or_default().insert(id(4_999));

        assert!(reaches(&graph, id(1), id(5_001)));
        assert_eq!(
            cyclic_components(&graph),
            vec![vec![id(4_999), id(5_000), id(5_001)]]
        );
    }
}
