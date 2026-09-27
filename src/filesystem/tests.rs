use super::*;
use crate::issue::IssueId;
use std::{fs, path::Path};
use tempfile::tempdir;

fn create_test_ledger(root: &Path) {
    let issues = root.join(".issues");
    fs::create_dir(&issues).unwrap();
    fs::write(issues.join(".next-id"), b"0001\n").unwrap();
}

#[test]
fn discovers_nearest_store_and_loads_utf8_bytes() {
    let temporary = tempdir().unwrap();
    create_test_ledger(temporary.path());
    let nested = temporary.path().join("nested/deeper");
    fs::create_dir_all(&nested).unwrap();
    let record = "# 0001 — Loaded\n\n## Metadata\n\n- **Status:** open\n- **Kind:** feature\n- **Created:** 2026-09-02\n\n## Statement\n\nBody café\n\n## Evidence\n\n- Pending.\n\n## Outcome\n\nPending.\n".as_bytes();
    fs::write(temporary.path().join(".issues/0001-loaded.md"), record).unwrap();

    let root = ProjectRoot::discover(&nested).unwrap();
    assert_eq!(root.as_path(), temporary.path().canonicalize().unwrap());
    let ledger = root.load_ledger().unwrap();
    assert_eq!(ledger.records()[&IssueId::new(1).unwrap()].bytes(), record);
}

#[cfg(unix)]
#[test]
fn rejects_symlinked_store_and_issue_candidates() {
    use std::os::unix::fs::symlink;

    let temporary = tempdir().unwrap();
    let real = temporary.path().join("real");
    fs::create_dir(&real).unwrap();
    fs::write(real.join(".next-id"), b"1\n").unwrap();
    symlink(&real, temporary.path().join(".issues")).unwrap();
    assert!(matches!(
        ProjectRoot::explicit(temporary.path()),
        Err(FilesystemError::SymlinkedStore)
    ));

    fs::remove_file(temporary.path().join(".issues")).unwrap();
    create_test_ledger(temporary.path());
    symlink(".next-id", temporary.path().join(".issues/0001-link.md")).unwrap();
    let root = ProjectRoot::explicit(temporary.path()).unwrap();
    assert!(matches!(
        root.load_ledger(),
        Err(FilesystemError::UnsafeIssuePath)
    ));
}

#[test]
fn explicit_root_must_be_a_directory() {
    let temporary = tempdir().unwrap();
    let file = temporary.path().join("not-a-root");
    fs::write(&file, b"").unwrap();
    assert!(matches!(
        ProjectRoot::explicit(&file),
        Err(FilesystemError::RootDoesNotExist)
    ));
}

#[test]
fn initialization_reconciles_counter_and_releases_lock() {
    let temporary = tempdir().unwrap();
    let issues = temporary.path().join(".issues");
    fs::create_dir(&issues).unwrap();
    fs::write(issues.join(".next-id"), b"1\n").unwrap();
    fs::write(
            issues.join("0007-existing.md"),
            b"# 0007 \xe2\x80\x94 Existing\n\nStatus: open\nKind: feature\nCreated: 2026-09-02\n\nExisting.\n",
        )
        .unwrap();
    fs::write(temporary.path().join(".gitignore"), b"target/\n").unwrap();

    let initialized = super::initialize_ledger(temporary.path()).unwrap();

    assert_eq!(initialized, issues.canonicalize().unwrap());
    assert_eq!(fs::read(issues.join(".next-id")).unwrap(), b"8\n");
    assert_eq!(
        fs::read(temporary.path().join(".gitignore")).unwrap(),
        b"target/\n\n/.issues/\n"
    );
    assert!(!issues.join(".cache/.isled-lock").exists());
}

#[test]
fn store_lock_is_exclusive_and_drop_releases_it() {
    let temporary = tempdir().unwrap();
    create_test_ledger(temporary.path());
    let root = ProjectRoot::explicit(temporary.path()).unwrap();

    let lock = root.acquire_lock().unwrap();
    assert!(matches!(root.acquire_lock(), Err(FilesystemError::Locked)));
    drop(lock);

    root.acquire_lock().unwrap().finish().unwrap();
}

#[cfg(unix)]
#[test]
fn initialization_sets_private_counter_mode() {
    use std::os::unix::fs::PermissionsExt;

    let temporary = tempdir().unwrap();
    super::initialize_ledger(temporary.path()).unwrap();
    let mode = fs::metadata(temporary.path().join(".issues/.next-id"))
        .unwrap()
        .permissions()
        .mode()
        & 0o777;

    assert_eq!(mode, 0o600);
}
