//! Retained findings survive processes and clear only after bounded reinspection.
use super::fixture::*;
use isled::{cache::Cache, filesystem::ProjectRoot};
use std::fs;

fn first_warning(root: &std::path::Path) -> Option<isled::issue::IssueId> {
    let root = ProjectRoot::explicit(root).unwrap();
    let lock = root.acquire_lock().unwrap();
    Cache::open(&lock).unwrap().first_warning_id().unwrap()
}

#[test]
fn relation_findings_survive_unrelated_commands_and_clear_on_neighbor_recheck() {
    let temp = fixture();
    let second = temp.path().join(".issues/0002-second.md");
    fs::write(&second, record(2, "Second", "", "", "")).unwrap();
    run_successfully(temp.path(), &["cache", "refresh"]);
    assert_eq!(first_warning(temp.path()), Some(id(1)));
    let database = temp.path().join(".issues/.cache/ledger.sqlite");
    let before = fs::read(&database).unwrap();
    run_successfully(temp.path(), &["cache", "refresh", "3"]);
    assert_eq!(first_warning(temp.path()), Some(id(1)));
    assert_eq!(fs::read(&database).unwrap(), before);
    fs::write(
        &second,
        record(2, "Second", "", "", "- **Blocking:**\n  - #0001 — First\n"),
    )
    .unwrap();
    // A warm metadata query has not checked the externally edited condition.
    assert_eq!(first_warning(temp.path()), Some(id(1)));
    run_successfully(temp.path(), &["cache", "refresh", "2"]);
    assert_eq!(first_warning(temp.path()), None);
}

#[test]
fn published_repair_and_deleted_relation_half_clear_both_endpoints() {
    let temp = fixture();
    let second = temp.path().join(".issues/0002-second.md");
    fs::write(&second, record(2, "Second", "", "", "")).unwrap();
    run_successfully(temp.path(), &["cache", "refresh"]);
    run_successfully(temp.path(), &["wait", "repair", "remove", "1", "2"]);
    assert_eq!(first_warning(temp.path()), None);
    fs::write(
        temp.path().join(".issues/0001-first.md"),
        record(
            1,
            "First",
            "",
            "- **Waiting on:**\n  - #0002 — Second\n    - **Reason:** Needed.\n",
            "",
        ),
    )
    .unwrap();
    run_successfully(temp.path(), &["cache", "refresh", "1"]);
    fs::remove_file(temp.path().join(".issues/0001-first.md")).unwrap();
    assert_eq!(first_warning(temp.path()), None);
}

#[test]
fn malformed_findings_survive_until_rechecked_and_cache_rebuild_recovers_them() {
    let temp = fixture();
    let third = temp.path().join(".issues/0003-third.md");
    fs::write(&third, "malformed").unwrap();
    run_successfully(temp.path(), &["cache", "refresh"]);
    assert_eq!(first_warning(temp.path()), Some(id(3)));
    fs::write(&third, record(3, "Third", "", "", "")).unwrap();
    assert_eq!(first_warning(temp.path()), Some(id(3)));
    run_successfully(temp.path(), &["cache", "refresh", "3"]);
    assert_eq!(first_warning(temp.path()), None);
    fs::write(&third, "malformed").unwrap();
    fs::remove_dir_all(temp.path().join(".issues/.cache")).unwrap();
    assert_eq!(first_warning(temp.path()), Some(id(3)));
}
