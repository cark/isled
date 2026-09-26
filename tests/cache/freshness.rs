use super::fixture::{fixture, id, record, run, run_successfully};
use isled::cache::Cache;
use isled::filesystem::ProjectRoot;
use isled::query::Filters;
use std::fs;

#[test]
fn external_blocker_change_refreshes_old_and_new_neighbors() {
    let temp = fixture();
    run_successfully(temp.path(), &["list"]);
    let dir = temp.path().join(".issues");
    fs::write(
        dir.join("0001-first.md"),
        record(
            1,
            "First",
            "",
            "- **Waiting on:**\n  - #0003 — Third\n    - **Reason:** Replacement.\n",
            "",
        ),
    )
    .unwrap();
    fs::write(dir.join("0002-second.md"), record(2, "Second", "", "", "")).unwrap();
    fs::write(
        dir.join("0003-third.md"),
        record(3, "Third", "", "", "- **Blocking:**\n  - #0001 — First\n"),
    )
    .unwrap();
    // In-place edits need not invalidate broad queries, but targeted refresh must.
    assert!(run_successfully(temp.path(), &["list", "--waiting-on", "2"]).contains("First"));
    let root = ProjectRoot::explicit(temp.path()).unwrap();
    {
        let lock = root.acquire_lock().unwrap();
        let cache = Cache::open_for_refresh(&lock, Some(id(1))).unwrap();
        assert_eq!(cache.files_read(), 3);
        let graph = cache.adjacency().unwrap();
        assert_eq!(graph[&id(1)], [id(3)].into_iter().collect());
    }
    assert!(run_successfully(temp.path(), &["list", "--waiting-on", "2"]).is_empty());
    assert!(run_successfully(temp.path(), &["list", "--waiting-on", "3"]).contains("First"));
    assert!(run_successfully(temp.path(), &["wait", "show", "3"]).contains("Replacement."));
    assert!(run(temp.path(), &["check"]).status.success());
}

#[test]
fn warm_queries_read_no_markdown_and_target_refresh_is_one_hop() {
    let temp = fixture();
    let root = ProjectRoot::explicit(temp.path()).unwrap();
    {
        let lock = root.acquire_lock().unwrap();
        let cache = Cache::open(&lock).unwrap();
        assert_eq!(cache.files_read(), 3);
        assert_eq!(cache.tag_counts().unwrap()[0].1, 1);
        assert_eq!(cache.summaries(&Filters::default()).unwrap().len(), 3);
    }
    let lock = root.acquire_lock().unwrap();
    let mut cache = Cache::open(&lock).unwrap();
    assert_eq!(cache.files_read(), 0);
    cache.refresh(Some(id(1))).unwrap();
    assert_eq!(cache.files_read(), 2);
    assert!(!cache.summaries(&Filters::default()).unwrap()[0].ready());
    assert_eq!(cache.tag_counts().unwrap()[0].0.as_str(), "rust");
}

#[test]
fn repeated_filters_rebind_values_and_observe_refreshed_rows() {
    let temp = fixture();
    // Initial indexing is a preceding command. This command starts with no
    // loaded contents, so its explicit refresh observes the external edit.
    run_successfully(temp.path(), &["list"]);
    let root = ProjectRoot::explicit(temp.path()).unwrap();
    let lock = root.acquire_lock().unwrap();
    let mut cache = Cache::open(&lock).unwrap();
    let mut filters = Filters {
        tags: vec![isled::issue::Tag::try_parse(b"rust").unwrap()],
        ..Filters::default()
    };
    assert_eq!(cache.summaries(&filters).unwrap()[0].id(), id(1));
    filters.tags[0] = isled::issue::Tag::try_parse(b"changed").unwrap();
    assert!(cache.summaries(&filters).unwrap().is_empty());
    fs::write(
        temp.path().join(".issues/0003-third.md"),
        record(3, "Changed", "- **Tags:** changed\n", "", ""),
    )
    .unwrap();
    cache.refresh(Some(id(3))).unwrap();
    assert_eq!(cache.summaries(&filters).unwrap()[0].id(), id(3));
    filters
        .tags
        .push(isled::issue::Tag::try_parse(b"rust").unwrap());
    assert!(cache.summaries(&filters).unwrap().is_empty());
    filters.tags.clear();
    assert_eq!(cache.summaries(&filters).unwrap().len(), 3);
}

#[test]
fn full_refresh_reads_each_file_once_even_after_membership_changes() {
    let temp = fixture();
    let root = ProjectRoot::explicit(temp.path()).unwrap();
    {
        let lock = root.acquire_lock().unwrap();
        let cache = Cache::open_for_refresh(&lock, None).unwrap();
        assert_eq!(cache.files_read(), 3);
    }
    fs::write(
        temp.path().join(".issues/0004-fourth.md"),
        record(4, "Fourth", "", "", ""),
    )
    .unwrap();
    let lock = root.acquire_lock().unwrap();
    let cache = Cache::open_for_refresh(&lock, None).unwrap();
    assert_eq!(cache.files_read(), 4);
}

#[test]
fn in_place_external_edits_are_best_effort_and_explicit_refresh_ignores_hints() {
    let temp = fixture();
    run_successfully(temp.path(), &["list"]);
    let path = temp.path().join(".issues/0003-third.md");
    let original = fs::read_to_string(&path).unwrap();
    let modified = fs::metadata(&path).unwrap().modified().unwrap();
    fs::write(&path, original.replace("Third", "Other")).unwrap();
    fs::File::options()
        .write(true)
        .open(&path)
        .unwrap()
        .set_modified(modified)
        .unwrap();
    assert!(run_successfully(temp.path(), &["list"]).contains("Third"));
    run_successfully(temp.path(), &["cache", "refresh", "#3"]);
    assert!(run_successfully(temp.path(), &["list"]).contains("Other"));
}

#[test]
fn same_count_replacement_and_full_refresh_reconcile_identity_and_tags() {
    let temp = fixture();
    run_successfully(temp.path(), &["list"]);
    fs::remove_file(temp.path().join(".issues/0003-third.md")).unwrap();
    fs::write(
        temp.path().join(".issues/0004-fourth.md"),
        record(4, "Fourth", "- **Tags:** new\n", "", ""),
    )
    .unwrap();
    let output = run_successfully(temp.path(), &["list"]);
    assert!(output.contains("Fourth"));
    assert!(!output.contains("Third"));
    run_successfully(temp.path(), &["cache", "refresh"]);
    assert!(run_successfully(temp.path(), &["list", "--tags", "new"]).contains("Fourth"));
}

#[test]
fn repeated_full_refresh_discards_deleted_inspection_sources() {
    let temp = fixture();
    // Initial indexing is a preceding command. This command starts with no
    // loaded contents, so its explicit refresh observes the external edit.
    run_successfully(temp.path(), &["list"]);
    let root = ProjectRoot::explicit(temp.path()).unwrap();
    let lock = root.acquire_lock().unwrap();
    let mut cache = Cache::open(&lock).unwrap();
    fs::remove_file(temp.path().join(".issues/0001-first.md")).unwrap();
    fs::write(
        temp.path().join(".issues/0002-second.md"),
        record(2, "Renamed", "", "", ""),
    )
    .unwrap();
    cache.refresh(None).unwrap();
    assert!(
        !cache
            .warnings()
            .iter()
            .any(|warning| warning.contains("copied-title repair failed")
                || warning.contains("issue #0001"))
    );
    assert!(!temp.path().join(".issues/0001-first.md").exists());
    drop(cache);
    lock.finish().unwrap();
}
