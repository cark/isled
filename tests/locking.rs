use isled::filesystem::{FilesystemError, ProjectRoot, initialize_ledger};
use std::{
    fs, thread,
    time::{Duration, Instant},
};

#[test]
fn contention_waits_for_release_and_observes_previous_holders_changes() {
    let directory = tempfile::tempdir().unwrap();
    let issues = initialize_ledger(directory.path()).unwrap();
    let root = ProjectRoot::explicit(directory.path()).unwrap();
    let lock = root.acquire_lock().unwrap();
    thread::scope(|scope| {
        let waiter = scope.spawn(|| {
            let _lock = root.acquire_lock().unwrap();
            assert_eq!(fs::read(issues.join(".next-id")).unwrap(), b"7\n");
        });
        thread::sleep(Duration::from_millis(50));
        fs::write(issues.join(".next-id"), b"7\n").unwrap();
        drop(lock);
        waiter.join().unwrap();
    });
    assert!(root.acquire_lock().is_ok());
}

#[test]
fn timeout_preserves_the_owners_lock_and_allows_later_acquisition() {
    let directory = tempfile::tempdir().unwrap();
    initialize_ledger(directory.path()).unwrap();
    let root = ProjectRoot::explicit(directory.path()).unwrap();
    let lock = root.acquire_lock().unwrap();
    let started = Instant::now();
    assert!(matches!(root.acquire_lock(), Err(FilesystemError::Locked)));
    assert!(started.elapsed() >= Duration::from_millis(500));
    assert!(started.elapsed() < Duration::from_secs(5));
    assert!(directory.path().join(".issues/.cache/.isled-lock").is_dir());
    drop(lock);
    assert!(root.acquire_lock().is_ok());
}
