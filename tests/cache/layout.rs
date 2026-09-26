//! Selection, freshness and bounded-reading contracts for candidate layout inputs.
use super::fixture::{fixture, record, run_successfully};
use isled::{
    cache::Cache,
    filesystem::ProjectRoot,
    graph_layout::{
        Direction,
        store::{Reuse, load_or_compute},
    },
    issue::Status,
};
use std::fs;

#[test]
fn graph_selection_is_strict_and_readiness_uses_the_actual_ledger() {
    let temp = fixture();
    let dir = temp.path().join(".issues");
    // Open 1 -> closed 2 -> open 3: neither selected open node may be bridged.
    fs::write(
        dir.join("0002-second.md"),
        record(
            2,
            "Second",
            "",
            "- **Waiting on:**\n  - #0003 — Third\n    - **Reason:** Needed.\n",
            "- **Blocking:**\n  - #0001 — First\n",
        )
        .replace("**Status:** open", "**Status:** closed"),
    )
    .unwrap();
    fs::write(
        dir.join("0003-third.md"),
        record(3, "Third", "", "", "- **Blocking:**\n  - #0002 — Second\n"),
    )
    .unwrap();
    run_successfully(temp.path(), &["cache", "refresh"]);
    let root = ProjectRoot::explicit(temp.path()).unwrap();
    let lock = root.acquire_lock().unwrap();
    let cache = Cache::open(&lock).unwrap();
    let (open, graph) = cache.layout_inputs(Some(Status::Open), 10).unwrap();
    assert_eq!(
        open.iter().map(|s| s.id().get()).collect::<Vec<_>>(),
        [1, 3]
    );
    assert!(open[0].ready());
    assert_eq!(graph.edge_count(), 0);
    let (closed, graph) = cache.layout_inputs(Some(Status::Closed), 10).unwrap();
    assert_eq!(closed.len(), 1);
    assert!(!closed[0].ready());
    assert_eq!(graph.edge_count(), 0);
    let (_, graph) = cache.layout_inputs(None, 10).unwrap();
    assert_eq!(graph.edge_count(), 2);
    assert_eq!(
        graph
            .layout(Direction::PrerequisitesFirst)
            .unwrap()
            .rows()
            .iter()
            .map(|r| r.id().get())
            .collect::<Vec<_>>(),
        [3, 2, 1]
    );
    assert_eq!(
        cache.files_read(),
        0,
        "graph selection must not fetch bodies"
    );
    assert!(cache.layout_inputs(None, 1).is_err());
}

#[test]
fn cached_layout_does_not_mask_titles_warnings_or_topology_changes() {
    let temp = fixture();
    let root = ProjectRoot::explicit(temp.path()).unwrap();
    let load = || {
        let lock = root.acquire_lock().unwrap();
        let cache = Cache::open(&lock).unwrap();
        let (summaries, graph) = cache.layout_inputs(Some(Status::Open), 20).unwrap();
        let result = load_or_compute(
            &lock,
            &graph,
            Some(Status::Open),
            Direction::PrerequisitesFirst,
            16384,
        )
        .unwrap();
        let warnings = cache.warnings().to_vec();
        let reads = cache.files_read();
        drop(cache);
        lock.finish().unwrap();
        (summaries, result, warnings, reads)
    };
    run_successfully(temp.path(), &["cache", "refresh"]);
    assert_eq!(load().1.reuse, Reuse::Miss);
    run_successfully(
        temp.path(),
        &["statement", "append", "1", "Additional prose."],
    );
    run_successfully(temp.path(), &["title", "set", "1", "Renamed"]);
    let (summaries, cached, _, reads) = load();
    assert_eq!(cached.reuse, Reuse::Hit);
    assert_eq!(summaries[0].title(), "Renamed");
    assert_eq!(reads, 0);
    assert!(!summaries[0].ready());
    run_successfully(temp.path(), &["wait", "add", "1", "3", "Also needed."]);
    let (summaries, cached, _, _) = load();
    assert!(
        !summaries[0].ready(),
        "topology changed without changing readiness"
    );
    assert_eq!(cached.reuse, Reuse::Miss);
    // Remove one mirrored half: the graph stays conservative, its warning stays live.
    fs::write(
        root.issues_dir().join("0002-second.md"),
        record(2, "Second", "", "", ""),
    )
    .unwrap();
    run_successfully(temp.path(), &["cache", "refresh", "2"]);
    let (_, cached, warnings, reads) = load();
    assert_eq!(cached.reuse, Reuse::Hit);
    assert!(warnings.iter().any(|s| s.contains("RELATION_RECIPROCAL")));
    assert_eq!(reads, 0);
    // An unavailable endpoint is omitted without pretending it is satisfied.
    fs::write(root.issues_dir().join("0003-third.md"), "malformed").unwrap();
    run_successfully(temp.path(), &["cache", "refresh", "3"]);
    let (summaries, cached, warnings, _) = load();
    assert_eq!(summaries.len(), 2);
    assert!(!summaries[0].ready());
    assert_eq!(cached.reuse, Reuse::Miss);
    assert!(!warnings.is_empty());
}
