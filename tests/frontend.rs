//! Bounded protocol behavior and physical-read limits on disposable ledgers.
#[path = "cache/fixture.rs"]
#[allow(dead_code)]
mod fixture;
use isled::{
    cache::Cache,
    filesystem::ProjectRoot,
    frontend::{self, request::Request},
};
use serde_json::{Value, json};
use std::{
    fs,
    io::Write,
    path::Path,
    process::{Command, Stdio},
};

fn execute(root: &Path, input: &[u8]) -> std::process::Output {
    let mut child = Command::new(env!("CARGO_BIN_EXE_isled"))
        .arg("--root")
        .arg(root)
        .args(["frontend", "--stdin"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(input).unwrap();
    child.wait_with_output().unwrap()
}

fn request(root: &Path, input: Value) -> Value {
    let output = execute(root, input.to_string().as_bytes());
    assert!(output.status.success(), "{output:?}");
    serde_json::from_slice(&output.stdout).unwrap()
}

fn input(mode: &str, details: Value) -> Value {
    json!({"schema_version":4,"mode":mode,"details":details})
}
#[test]
fn compact_view_and_details_match_full_snapshot_and_unchanged_reply_is_empty() {
    let dir = fixture::fixture();
    let first = request(
        dir.path(),
        input("refresh", json!([{"id":"0001"},{"id":"0002"}])),
    );
    let full: Value =
        serde_json::from_str(&fixture::run_successfully(dir.path(), &["snapshot"])).unwrap();
    assert_eq!(first["view"]["issues"].as_array().unwrap().len(), 3);
    assert!(first["view"]["issues"][0].get("content").is_none());
    assert_eq!(first["changes"][0]["detail"]["issue"], full["issues"][0]);
    assert_eq!(first["changes"][1]["detail"]["issue"], full["issues"][1]);
    let second = request(
        dir.path(),
        json!({"schema_version":4,"mode":"refresh","view_hash":first["view_hash"],
      "details":[{"id":"0001","hash":first["changes"][0]["hash"]},{"id":"0002","hash":first["changes"][1]["hash"]}]}),
    );
    assert_eq!(second["view"], Value::Null);
    assert_eq!(second["changes"], json!([]));
}
#[test]
fn targeted_batch_deduplicates_neighbors_and_leaves_unrelated_edits_unread() {
    let dir = fixture::fixture();
    request(dir.path(), input("refresh", json!([])));
    fs::write(
        dir.path().join(".issues/0003-third.md"),
        "broken external edit",
    )
    .unwrap();
    let root = ProjectRoot::discover(dir.path()).unwrap();
    let lock = root.acquire_lock().unwrap();
    let mut cache = Cache::open(&lock).unwrap();
    let data = frontend::respond(
        &mut cache,
        &Request::parse(
            input("details", json!([{"id":"0001"},{"id":"0002"}]))
                .to_string()
                .as_bytes(),
        )
        .unwrap(),
    )
    .unwrap();
    assert_eq!(cache.files_read(), 2);
    assert_eq!(
        serde_json::from_slice::<Value>(&data).unwrap()["changes"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    drop(cache);
    lock.finish().unwrap();
    let refreshed = request(dir.path(), input("refresh", json!([])));
    assert_eq!(refreshed["view"]["unavailable"][0]["id"], "0003");
}
#[test]
fn neighbor_status_changes_live_hash_without_changing_selected_bytes() {
    let dir = fixture::fixture();
    let first = request(dir.path(), input("refresh", json!([{"id":"0001"}])));
    let path = dir.path().join(".issues/0002-second.md");
    fs::write(
        &path,
        fs::read_to_string(&path)
            .unwrap()
            .replace("**Status:** open", "**Status:** closed"),
    )
    .unwrap();
    let next = request(
        dir.path(),
        input(
            "details",
            json!([{"id":"0001","hash":first["changes"][0]["hash"]}]),
        ),
    );
    assert_eq!(next["changes"][0]["detail"]["issue"]["ready"], true);
    assert_ne!(next["changes"][0]["hash"], first["changes"][0]["hash"]);
    assert_eq!(
        next["changes"][0]["detail"]["issue"]["content"],
        first["changes"][0]["detail"]["issue"]["content"]
    );
}
#[test]
fn deletion_and_parse_failure_are_explicit_and_cache_recovery_completes_request() {
    let dir = fixture::fixture();
    request(dir.path(), input("refresh", json!([])));
    fs::remove_file(dir.path().join(".issues/0003-third.md")).unwrap();
    fs::write(dir.path().join(".issues/0002-second.md"), "broken").unwrap();
    fs::write(dir.path().join(".issues/.cache/ledger.sqlite"), "corrupt").unwrap();
    let next = request(
        dir.path(),
        input("details", json!([{"id":"0002"},{"id":"0003"}])),
    );
    assert_eq!(next["changes"][0]["type"], "problem");
    assert_eq!(next["changes"][1]["type"], "deleted");
}
#[test]
fn filters_are_applied_by_rust_and_invalid_requests_fail_before_discovery() {
    let dir = fixture::fixture();
    let value = request(
        dir.path(),
        json!({"schema_version":4,"mode":"refresh","filter":{"tags":["rust"]}}),
    );
    assert_eq!(value["view"]["issues"].as_array().unwrap().len(), 1);
    for value in [
        json!({"schema_version":1,"mode":"details"}),
        input("details", json!([{"id":"1"}])),
        input("details", json!([{"id":"0001"},{"id":"0001"}])),
        input("details", json!([{"id":"0001","hash":"INVALID"}])),
    ] {
        assert!(Request::parse(value.to_string().as_bytes()).is_err());
    }
}

#[test]
fn invalid_wire_input_is_rejected_before_root_discovery() {
    let temp = tempfile::tempdir().unwrap();
    let output = execute(
        &temp.path().join("nonexistent"),
        br#"{"schema_version":1,"mode":"details"}"#,
    );
    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    assert!(
        String::from_utf8(output.stderr)
            .unwrap()
            .contains("unsupported frontend request version")
    );
}

#[test]
fn text_filters_match_across_sections_with_unicode_and_literal_phrases() {
    let dir = fixture::fixture();
    let path = dir.path().join(".issues/0001-first.md");
    fs::write(
        &path,
        fs::read_to_string(&path)
            .unwrap()
            .replace("Body.", "Straße timeout here. Literal t:rust."),
    )
    .unwrap();
    let response = request(
        dir.path(),
        json!({"schema_version":4,"mode":"refresh",
        "filter":{"status":"all","tags":["rust"],"kinds":["feature"],
        "text":["FIRST","needed","STRASSE","timeout here","t:rust"]}}),
    );
    assert_eq!(response["view"]["issues"].as_array().unwrap().len(), 1);
    assert_eq!(response["view"]["issues"][0]["id"], "0001");
    assert!(
        response["choices"]
            .as_array()
            .unwrap()
            .contains(&json!("t:rust"))
    );
    assert!(
        response["choices"]
            .as_array()
            .unwrap()
            .contains(&json!("k:feature"))
    );
    let response = request(
        dir.path(),
        json!({"schema_version":4,"mode":"view",
        "filter":{"status":"all","kinds":["feature","bug"]}}),
    );
    assert_eq!(response["view"]["issues"], json!([]));
}

#[test]
fn text_selection_reads_only_metadata_candidates_and_reuses_current_run_reads() {
    let dir = fixture::fixture();
    request(dir.path(), input("refresh", json!([])));
    let root = ProjectRoot::discover(dir.path()).unwrap();
    let lock = root.acquire_lock().unwrap();
    let mut cache = Cache::open(&lock).unwrap();
    let query = Request::parse(
        br#"{"schema_version":4,"mode":"view","filter":{"tags":["rust"],"text":["Body"]}}"#,
    )
    .unwrap();
    frontend::respond(&mut cache, &query).unwrap();
    assert_eq!(cache.files_read(), 1);
    frontend::respond(&mut cache, &query).unwrap();
    assert_eq!(cache.files_read(), 1);
}

#[test]
fn malformed_filter_fields_fail_before_discovery() {
    for filter in [
        json!({"text":[""]}),
        json!({"text":["two\nlines"]}),
        json!({"kinds":["Bad"]}),
    ] {
        let output = execute(
            Path::new("/missing-project-for-filter-test"),
            json!({"schema_version":4,"mode":"view","filter":filter})
                .to_string()
                .as_bytes(),
        );
        assert!(!output.status.success());
        assert!(output.stdout.is_empty());
        assert!(!String::from_utf8_lossy(&output.stderr).contains("No such file"));
    }
}

#[test]
fn completion_choices_are_sorted_unique_ledger_wide_and_refresh_with_metadata() {
    let dir = fixture::fixture();
    let second = dir.path().join(".issues/0002-second.md");
    fs::write(
        &second,
        fixture::record(
            2,
            "Second",
            "- **Tags:** zebra, rust, priority-high\n",
            "",
            "",
        )
        .replace("**Kind:** feature", "**Kind:** bug")
        .replace("**Status:** open", "**Status:** closed"),
    )
    .unwrap();
    let expected = json!([
        "s:open",
        "s:closed",
        "w:not-queued",
        "w:queued",
        "w:in-progress",
        "w:awaiting-owner",
        "t:priority-high",
        "t:rust",
        "t:zebra",
        "k:bug",
        "k:feature"
    ]);
    let first = request(
        dir.path(),
        json!({"schema_version":4,"mode":"refresh","filter":{"tags":["absent"]}}),
    );
    assert_eq!(first["view"]["issues"], json!([]));
    assert_eq!(first["choices"], expected);
    let unchanged = request(
        dir.path(),
        json!({"schema_version":4,"mode":"view","filter":{"tags":["absent"]},
            "view_hash":first["view_hash"]}),
    );
    assert_eq!(unchanged["view"], Value::Null);
    assert_eq!(unchanged["choices"], expected);
    assert!(
        request(dir.path(), input("details", json!([])))
            .get("choices")
            .is_none()
    );

    fs::write(&second, "broken external edit").unwrap();
    let refreshed = request(dir.path(), input("refresh", json!([])));
    assert_eq!(
        refreshed["choices"],
        json!([
            "s:open",
            "s:closed",
            "w:not-queued",
            "w:queued",
            "w:in-progress",
            "w:awaiting-owner",
            "t:rust",
            "k:feature"
        ])
    );
    assert_eq!(refreshed["view"]["unavailable"][0]["id"], "0002");
}

#[test]
fn contextual_choices_combine_other_constraints_and_replace_status() {
    let dir = fixture::fixture();
    let second = dir.path().join(".issues/0002-second.md");
    fs::write(
        &second,
        fixture::record(2, "Second", "- **Tags:** rust, zebra\n", "", "")
            .replace("**Kind:** feature", "**Kind:** bug")
            .replace("**Status:** open", "**Status:** closed")
            .replace("Body.", "Straße timeout here."),
    )
    .unwrap();
    request(dir.path(), input("refresh", json!([])));
    for (criteria, expected) in [
        (
            json!({"status":"all","tags":["rust"]}),
            json!([
                "s:open",
                "s:closed",
                "w:not-queued",
                "t:rust",
                "t:zebra",
                "k:bug",
                "k:feature"
            ]),
        ),
        (
            json!({"status":"open","tags":["rust"]}),
            json!(["s:open", "s:closed", "w:not-queued", "t:rust", "k:feature"]),
        ),
        (
            json!({"status":"all","tags":["rust","rust"],"kinds":["bug"],"text":["STRASSE","timeout here"]}),
            json!(["s:closed", "w:not-queued", "t:rust", "t:zebra", "k:bug"]),
        ),
        (json!({"status":"all","tags":["missing"]}), json!([])),
        (json!({"status":"all","kinds":["feature","bug"]}), json!([])),
        (json!({"status":"all","text":["absent phrase"]}), json!([])),
    ] {
        let value = request(
            dir.path(),
            json!({"schema_version":4,"mode":"choices","choice_filter":criteria}),
        );
        assert_eq!(value["choices"], expected, "{criteria}");
        assert_eq!(value["view"], Value::Null);
        assert_eq!(value["view_hash"], Value::Null);
        assert_eq!(value["changes"], json!([]));
    }
    fs::write(second, "unreadable record").unwrap();
    let value = request(
        dir.path(),
        json!({"schema_version":4,"mode":"refresh", "choice_filter":{"status":"all","tags":["rust"]}}),
    );
    assert_eq!(
        value["choices"],
        json!(["s:open", "w:not-queued", "t:rust", "k:feature"])
    );
}

#[test]
fn contextual_choice_mode_validates_before_discovery_and_empty_ledger_has_no_choices() {
    for value in [
        json!({"schema_version":4,"mode":"choices","choice_filter":{"text":[""]}}),
        json!({"schema_version":4,"mode":"choices","details":[{"id":"0001"}]}),
        json!({"schema_version":4,"mode":"choices","view_hash":"0123456789abcdef"}),
        json!({"schema_version":4,"mode":"details","choice_filter":{}}),
    ] {
        let output = execute(
            Path::new("/missing-choice-test-project"),
            value.to_string().as_bytes(),
        );
        assert!(!output.status.success());
        assert!(output.stdout.is_empty());
        assert!(!String::from_utf8_lossy(&output.stderr).contains("No such file"));
    }
    let dir = tempfile::tempdir().unwrap();
    isled::filesystem::initialize_ledger(dir.path()).unwrap();
    let value = request(
        dir.path(),
        json!({"schema_version":4,"mode":"choices","choice_filter":{"status":"all"}}),
    );
    assert_eq!(value["choices"], json!([]));
}

#[test]
fn contextual_choices_do_not_read_details_and_share_text_reads_with_view() {
    let dir = fixture::fixture();
    request(dir.path(), input("refresh", json!([])));
    // A warm metadata-only request must not reconcile this unrelated edit.
    fs::write(
        dir.path().join(".issues/0003-third.md"),
        "broken external edit",
    )
    .unwrap();
    let root = ProjectRoot::discover(dir.path()).unwrap();
    let lock = root.acquire_lock().unwrap();
    let mut cache = Cache::open(&lock).unwrap();
    let call = |cache: &mut Cache<'_>, mode, criteria| {
        frontend::respond(
            cache,
            &Request::parse(
                json!({"schema_version":4,"mode":mode,
            "filter":{"tags":["rust"],"text":["Body"]},"choice_filter":criteria})
                .to_string()
                .as_bytes(),
            )
            .unwrap(),
        )
        .unwrap()
    };
    call(&mut cache, "choices", json!({"tags":["rust"]}));
    assert_eq!(cache.files_read(), 0);
    call(&mut cache, "view", json!({"tags":["rust"],"text":["Body"]}));
    assert_eq!(cache.files_read(), 1);
}

#[test]
fn contextual_text_read_failure_produces_no_partial_response() {
    let dir = fixture::fixture();
    request(dir.path(), input("refresh", json!([])));
    fs::write(dir.path().join(".issues/0001-first.md"), [0xff]).unwrap();
    let output = execute(dir.path(), br#"{"schema_version":4,"mode":"choices","choice_filter":{"tags":["rust"],"text":["Body"]}}"#);
    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    assert!(!output.stderr.is_empty());
}

#[test]
fn known_warning_survives_filters_and_unchanged_views_then_clears_after_repair() {
    let temp = fixture::fixture();
    let second = temp.path().join(".issues/0002-second.md");
    fs::write(&second, fixture::record(2, "Second", "", "", "")).unwrap();
    let mut filtered = input("view", json!([]));
    filtered["filter"] = json!({"status":"closed"});
    let first = request(temp.path(), filtered.clone());
    assert_eq!(first["first_warning"]["issue"]["id"], "0001");
    assert_eq!(
        first["warning_targets"]
            .as_array()
            .unwrap()
            .iter()
            .map(|target| target["issue"]["id"].as_str().unwrap())
            .collect::<Vec<_>>(),
        vec!["0001", "0002"]
    );
    assert_eq!(first["view"]["issues"], json!([]));
    filtered["view_hash"] = first["view_hash"].clone();
    let unchanged = request(temp.path(), filtered.clone());
    assert!(unchanged["view"].is_null());
    assert_eq!(unchanged["first_warning"], first["first_warning"]);
    fixture::run_successfully(temp.path(), &["wait", "repair", "remove", "1", "2"]);
    let cleared = request(temp.path(), filtered);
    assert!(cleared["first_warning"].is_null());
    assert_eq!(cleared["warning_targets"], json!([]));
    fs::write(&second, "malformed").unwrap();
    let malformed = request(temp.path(), input("refresh", json!([])));
    assert_eq!(malformed["first_warning"]["type"], "problem");
    assert_eq!(malformed["first_warning"]["problem"]["id"], "0002");
    assert_eq!(malformed["warning_targets"][0], malformed["first_warning"]);
}

#[test]
fn retained_reciprocal_warning_remains_displayable_when_other_endpoint_is_unreadable() {
    let temp = fixture::fixture();
    let second = temp.path().join(".issues/0002-second.md");
    fs::write(&second, fixture::record(2, "Second", "", "", "")).unwrap();
    request(temp.path(), input("refresh", json!([])));
    fs::write(temp.path().join(".issues/0001-first.md"), "malformed").unwrap();
    let response = request(
        temp.path(),
        input("details", json!([{"id":"0002","hash":null}])),
    );
    let warnings = response["changes"][0]["detail"]["issue"]["warnings"]
        .as_array()
        .unwrap();
    assert!(
        warnings
            .iter()
            .any(|w| w["code"] == "RELATION_RECIPROCAL" && w["needs_reason"] == false)
    );
}
