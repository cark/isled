//! Build reciprocal dependency changes against the proposed final graph.
use super::{FieldError, Records, document};
use crate::{
    issue::{IssueId, IssueRelation, Status, WaitReason, WaitRelation},
    record::RecordDocument,
    wait_graph::{self, Adjacency},
};
use std::collections::{BTreeMap, BTreeSet};

pub(super) fn update(
    records: &Records,
    original: RecordDocument,
    mut updated: RecordDocument,
    waiting: &[(IssueId, WaitReason)],
    blocking: &[(IssueId, WaitReason)],
    graph: &Adjacency,
) -> Result<BTreeMap<IssueId, RecordDocument>, FieldError> {
    let id = original.issue.id;
    let neighbors: BTreeSet<_> = original
        .issue
        .waits
        .iter()
        .map(|r| r.target)
        .chain(original.issue.blocking.iter().map(|r| r.target))
        .chain(waiting.iter().chain(blocking).map(|(id, _)| *id))
        .collect();
    let mut documents = neighbors
        .iter()
        .map(|&n| document(records, n).map(|d| (n, d.clone())))
        .collect::<Result<BTreeMap<_, _>, _>>()?;
    validate_mirrors(&original, &documents)?;
    let mut final_graph = graph.clone();
    final_graph.remove(&id);
    for edges in final_graph.values_mut() {
        edges.remove(&id);
    }
    updated.issue.waits.clear();
    updated.issue.blocking.clear();
    for neighbor in documents.values_mut() {
        neighbor.issue.waits.retain(|r| r.target != id);
        neighbor.issue.blocking.retain(|r| r.target != id);
    }
    for (field, incoming, values) in [("waiting_on", false, waiting), ("blocking", true, blocking)]
    {
        for (index, (neighbor, reason)) in values.iter().enumerate() {
            let field = format!("{field}.{index}");
            if *neighbor == id {
                return Err(FieldError::new(field, "An issue cannot depend on itself"));
            }
            let other = documents.get_mut(neighbor).expect("selected neighbor");
            let (source, target) = if incoming {
                (*neighbor, id)
            } else {
                (id, *neighbor)
            };
            let existed = if incoming {
                original
                    .issue
                    .blocking
                    .iter()
                    .any(|r| r.target == *neighbor)
            } else {
                original.issue.waits.iter().any(|r| r.target == *neighbor)
            };
            if !existed
                && (original.issue.status != Status::Open || other.issue.status != Status::Open)
            {
                return Err(FieldError::new(
                    field,
                    "New dependencies require two open issues",
                ));
            }
            final_graph.entry(source).or_default().insert(target);
            if incoming {
                other.issue.waits.push(WaitRelation {
                    target: id,
                    title: updated.issue.title.clone(),
                    reason: reason.as_bytes().to_vec(),
                });
                updated.issue.blocking.push(IssueRelation {
                    target: *neighbor,
                    title: other.issue.title.clone(),
                });
            } else {
                updated.issue.waits.push(WaitRelation {
                    target: *neighbor,
                    title: other.issue.title.clone(),
                    reason: reason.as_bytes().to_vec(),
                });
                other.issue.blocking.push(IssueRelation {
                    target: id,
                    title: updated.issue.title.clone(),
                });
            }
        }
    }
    for (field, incoming, values) in [("waiting_on", false, waiting), ("blocking", true, blocking)]
    {
        for (index, (neighbor, _)) in values.iter().enumerate() {
            let (source, target) = if incoming {
                (*neighbor, id)
            } else {
                (id, *neighbor)
            };
            if wait_graph::reaches(&final_graph, target, source) {
                return Err(FieldError::new(
                    format!("{field}.{index}"),
                    "This dependency would create a cycle",
                ));
            }
        }
    }
    documents.insert(id, updated);
    for doc in documents.values_mut() {
        doc.issue.waits.sort_by_key(|r| r.target);
        doc.issue.blocking.sort_by_key(|r| r.target);
    }
    Ok(documents)
}
fn validate_mirrors(
    original: &RecordDocument,
    neighbors: &BTreeMap<IssueId, RecordDocument>,
) -> Result<(), FieldError> {
    let id = original.issue.id;
    for r in &original.issue.waits {
        if !neighbors[&r.target]
            .issue
            .blocking
            .iter()
            .any(|e| e.target == id)
        {
            return Err(FieldError::new(
                "waiting_on",
                "Incomplete dependency; use wait repair first",
            ));
        }
    }
    for r in &original.issue.blocking {
        if !neighbors[&r.target]
            .issue
            .waits
            .iter()
            .any(|e| e.target == id)
        {
            return Err(FieldError::new(
                "blocking",
                "Incomplete dependency; use wait repair first",
            ));
        }
    }
    Ok(())
}
