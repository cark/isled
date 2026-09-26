use super::*;
use crate::{filesystem::ProjectRoot, issue::IssueId};

fn fixture() -> (tempfile::TempDir, ProjectRoot) {
    let temp = tempfile::tempdir().unwrap();
    fs::create_dir(temp.path().join(".issues")).unwrap();
    let root = ProjectRoot::explicit(temp.path()).unwrap();
    (temp, root)
}

fn graph(extra: bool) -> Graph {
    let id = |i| IssueId::new(i).unwrap();
    let mut edges = vec![(id(2), id(1)), (id(3), id(1))];
    if extra {
        edges.push((id(3), id(2)));
    }
    Graph::new([id(1), id(2), id(3)], edges, 10).unwrap()
}

#[test]
fn persists_across_locks_and_invalidates_graph_direction_status_and_ledger() {
    let (_temp, root) = fixture();
    let load = |root: &ProjectRoot, graph: &Graph, status, direction| {
        let lock = root.acquire_lock().unwrap();
        let result = load_or_compute(&lock, graph, status, direction, 4096).unwrap();
        lock.finish().unwrap();
        result
    };
    let direction = Direction::PrerequisitesFirst;
    assert_eq!(
        load(&root, &graph(false), None, direction).reuse,
        Reuse::Miss
    );
    assert_eq!(
        load(&root, &graph(false), None, direction).reuse,
        Reuse::Hit
    );
    assert_eq!(
        load(&root, &graph(true), None, direction).reuse,
        Reuse::Miss
    );
    assert_eq!(
        load(&root, &graph(true), Some(Status::Open), direction).reuse,
        Reuse::Miss
    );
    assert_eq!(
        load(&root, &graph(true), None, Direction::DependentsFirst).reuse,
        Reuse::Miss
    );
    let (_other, other_root) = fixture();
    let other_cache = other_root
        .issues_dir()
        .join(".cache/graph-layout-candidate");
    fs::create_dir_all(&other_cache).unwrap();
    fs::copy(
        root.issues_dir()
            .join(".cache/graph-layout-candidate/all-prerequisites.plan"),
        other_cache.join("all-prerequisites.plan"),
    )
    .unwrap();
    assert_eq!(
        load(&other_root, &graph(true), None, direction).reuse,
        Reuse::Miss
    );
}

#[test]
fn corruption_oversize_and_interrupted_staging_are_disposable() {
    let (_temp, root) = fixture();
    let lock = root.acquire_lock().unwrap();
    let graph = graph(false);
    let load = |budget| {
        load_or_compute(&lock, &graph, None, Direction::PrerequisitesFirst, budget).unwrap()
    };
    let first = load(4096);
    let directory = root.issues_dir().join(".cache/graph-layout-candidate");
    let path = directory.join("all-prerequisites.plan");
    let mut bytes = fs::read(&path).unwrap();
    *bytes.last_mut().unwrap() ^= 1;
    fs::write(&path, &bytes).unwrap();
    fs::write(directory.join("pending.plan"), b"interrupted").unwrap();
    let rebuilt = load(4096);
    assert_eq!(rebuilt.reuse, Reuse::RebuiltInvalid);
    assert_eq!(rebuilt.plan, first.plan);
    assert!(!directory.join("pending.plan").exists());
    assert_eq!(load(32).reuse, Reuse::Oversized);
    assert!(!path.exists());
    for status in [None, Some(Status::Open), Some(Status::Closed)] {
        for direction in [Direction::PrerequisitesFirst, Direction::DependentsFirst] {
            load_or_compute(&lock, &graph, status, direction, 4096).unwrap();
        }
    }
    let entries: Vec<_> = fs::read_dir(&directory)
        .unwrap()
        .map(Result::unwrap)
        .collect();
    assert_eq!(entries.len(), 6);
    assert!(entries.iter().all(|e| e.metadata().unwrap().len() <= 4096));
    assert_eq!(load(32).reuse, Reuse::Oversized);
    assert_eq!(fs::read_dir(&directory).unwrap().count(), 0);
}

#[test]
fn forged_checksum_does_not_bypass_plan_validation() {
    let graph = graph(false);
    let mut data = graph.layout(Direction::PrerequisitesFirst).unwrap().data;
    data.rows[0].lane = usize::MAX;
    let mut bytes = MAGIC.to_vec();
    bytes.extend_from_slice(&0_u64.to_le_bytes());
    bytes.extend_from_slice(&0_u64.to_le_bytes());
    serde_json::to_writer(&mut bytes, &data).unwrap();
    let checksum = xxh3_64(&bytes[24..]);
    bytes[16..24].copy_from_slice(&checksum.to_le_bytes());
    assert!(decode(&bytes, &[], &graph, Direction::PrerequisitesFirst).is_err());
}

#[cfg(unix)]
#[test]
fn symlinked_slots_are_rejected_without_touching_targets() {
    let (temp, root) = fixture();
    let lock = root.acquire_lock().unwrap();
    let path = root.issues_dir().join(".cache/graph-layout-candidate");
    fs::create_dir(&path).unwrap();
    let target = temp.path().join("keep");
    fs::write(&target, b"keep").unwrap();
    std::os::unix::fs::symlink(&target, path.join("all-prerequisites.plan")).unwrap();
    assert!(
        load_or_compute(
            &lock,
            &graph(false),
            None,
            Direction::PrerequisitesFirst,
            4096
        )
        .is_err()
    );
    assert_eq!(fs::read(&target).unwrap(), b"keep");
}
