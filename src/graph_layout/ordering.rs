//! Keep connected groups intact in ID order, following newly ready branches.
use super::LayoutError;

pub(super) fn order(outgoing: &[Vec<usize>]) -> Result<Vec<usize>, LayoutError> {
    let mut incoming = vec![Vec::new(); outgoing.len()];
    for (source, targets) in outgoing.iter().enumerate() {
        for &target in targets {
            incoming[target].push(source);
        }
    }
    let groups = component_roots(outgoing, &incoming);
    let mut remaining: Vec<_> = incoming.iter().map(Vec::len).collect();
    let mut order = Vec::with_capacity(incoming.len());
    for mut ready in groups {
        while let Some(node) = ready.pop() {
            order.push(node);
            // Follow newly unblocked work before another root of this group.
            let mut unblocked = Vec::new();
            for &target in &outgoing[node] {
                remaining[target] -= 1;
                if remaining[target] == 0 {
                    unblocked.push(target);
                }
            }
            // Finish narrower branches before opening another broad branch.
            unblocked.sort_unstable_by_key(|&target| {
                std::cmp::Reverse((outgoing[target].len(), target))
            });
            ready.extend(unblocked);
        }
    }
    if order.len() != outgoing.len() {
        return Err(LayoutError(
            "selected dependency graph contains a cycle; run isled check".into(),
        ));
    }
    Ok(order)
}

/// Node indices follow ascending issue IDs. Each weak component is placed at
/// its smallest ID, including singleton independent issues between threads.
fn component_roots(outgoing: &[Vec<usize>], incoming: &[Vec<usize>]) -> Vec<Vec<usize>> {
    let mut membership = vec![usize::MAX; outgoing.len()];
    let mut roots = Vec::new();
    let mut pending = Vec::new();
    for first in 0..outgoing.len() {
        if membership[first] != usize::MAX {
            continue;
        }
        let group = roots.len();
        roots.push(Vec::new());
        membership[first] = group;
        pending.push(first);
        while let Some(node) = pending.pop() {
            for &neighbor in outgoing[node].iter().chain(&incoming[node]) {
                if membership[neighbor] == usize::MAX {
                    membership[neighbor] = group;
                    pending.push(neighbor);
                }
            }
        }
    }
    // Reverse insertion makes the smallest root the first popped in each group.
    for node in (0..outgoing.len()).rev() {
        if incoming[node].is_empty() {
            roots[membership[node]].push(node);
        }
    }
    roots
}
