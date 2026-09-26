//! Opt-in layout transport and unchanged flat frontend behavior.
#[path = "cache/fixture.rs"]
#[allow(dead_code)]
mod fixture;
use isled::{
    cache::Cache,
    filesystem::ProjectRoot,
    frontend::{self, request::Request},
};
use serde_json::{Value, json};
use std::{fs, path::Path};

fn request(path: &Path, input: Value) -> (Value, usize) {
    let root = ProjectRoot::discover(path).unwrap();
    let lock = root.acquire_lock().unwrap();
    let mut cache = Cache::open(&lock).unwrap();
    let request = Request::parse(input.to_string().as_bytes()).unwrap();
    let bytes = frontend::respond(&mut cache, &request).unwrap();
    let reads = cache.files_read();
    drop(cache);
    lock.finish().unwrap();
    (serde_json::from_slice(&bytes).unwrap(), reads)
}

fn input(direction: &str, status: &str) -> Value {
    json!({"schema_version":3,"mode":"view","filter":{"status":status},
           "graph":{"direction":direction}})
}

#[test]
fn graph_is_opt_in_and_orders_both_directions_without_body_reads() {
    let dir = fixture::fixture();
    fixture::run_successfully(dir.path(), &["cache", "refresh"]);
    let (flat, _) = request(dir.path(), json!({"schema_version":3,"mode":"view"}));
    assert!(flat.get("graph").is_none());
    for (direction, from, to) in [
        ("prerequisites", "0002", "0001"),
        ("dependents", "0001", "0002"),
    ] {
        let (value, reads) = request(dir.path(), input(direction, "open"));
        assert_eq!(reads, 0);
        assert_eq!(value["view"], flat["view"]);
        let rows = value["graph"]["plan"]["rows"].as_array().unwrap();
        let source = rows.iter().position(|r| r["id"] == from).unwrap();
        let target = rows.iter().position(|r| r["id"] == to).unwrap();
        assert!(source < target);
        assert_eq!(rows[source]["targets"], json!([target]));
        assert_eq!(rows[target]["start"], source);
        assert_eq!(rows[source]["lane"], 0);
        assert_ne!(rows[target]["lane"], 0);
        let drawing = &value["graph"]["plan"]["drawing"];
        let steps = drawing["steps"].as_array().unwrap();
        assert_eq!(steps.len(), rows.len());
        assert_eq!(steps[source]["row"], source);
        assert_eq!(steps[target]["row"], target);
        assert_eq!(steps[source]["lane"], 0);
        assert_eq!(steps[target]["start"], source);
        // Ordinary steps reuse semantic edges rather than duplicating them.
        assert!(steps.iter().all(|step| step.get("targets").is_none()));
    }
}

#[test]
fn graph_token_distinguishes_edges_direction_and_status_but_not_prose() {
    let dir = fixture::fixture();
    // Third is already blocked by Second; adding a second relation leaves readiness alone.
    fixture::run_successfully(dir.path(), &["wait", "add", "3", "2", "Needed"]);
    let (first, _) = request(dir.path(), input("prerequisites", "open"));
    let mut known = input("prerequisites", "open");
    known["graph"]["hash"] = first["graph"]["hash"].clone();
    known["view_hash"] = first["view_hash"].clone();
    let (same, reads) = request(dir.path(), known.clone());
    assert_eq!(reads, 0);
    assert!(same["graph"]["plan"].is_null());
    assert!(same["view"].is_null());
    fixture::run_successfully(dir.path(), &["statement", "append", "3", "More prose."]);
    let (prose, _) = request(dir.path(), known.clone());
    assert!(prose["graph"]["plan"].is_null());
    fixture::run_successfully(dir.path(), &["wait", "add", "3", "1", "Also needed"]);
    let (edges, _) = request(dir.path(), known.clone());
    assert!(edges["view"].is_null());
    assert_ne!(edges["graph"]["hash"], first["graph"]["hash"]);
    assert!(!edges["graph"]["plan"].is_null());
    for changed in [input("dependents", "open"), input("prerequisites", "all")] {
        let (value, _) = request(dir.path(), changed);
        assert_ne!(value["graph"]["hash"], edges["graph"]["hash"]);
    }
}

#[test]
fn strict_status_never_bridges_a_closed_intermediate() {
    let dir = fixture::fixture();
    fixture::run_successfully(dir.path(), &["wait", "add", "2", "3", "Needed"]);
    let path = dir.path().join(".issues/0002-second.md");
    fs::write(
        &path,
        fs::read_to_string(&path)
            .unwrap()
            .replace("**Status:** open", "**Status:** closed"),
    )
    .unwrap();
    fixture::run_successfully(dir.path(), &["cache", "refresh"]);
    let (open, _) = request(dir.path(), input("prerequisites", "open"));
    let rows = open["graph"]["plan"]["rows"].as_array().unwrap();
    assert_eq!(rows.len(), 2);
    assert!(
        rows.iter()
            .all(|r| r["id"] != "0002" && r["targets"] == json!([]))
    );
    let (closed, _) = request(dir.path(), input("dependents", "closed"));
    assert_eq!(closed["graph"]["plan"]["rows"][0]["id"], "0002");
    let (all, _) = request(dir.path(), input("prerequisites", "all"));
    assert_eq!(all["graph"]["plan"]["rows"].as_array().unwrap().len(), 3);
}

#[test]
fn graph_input_is_validated_before_any_ledger_work() {
    for (field, value) in [
        ("mode", json!("details")),
        ("mode", json!("choices")),
        ("graph", json!({"direction":"unknown"})),
        ("graph", json!({"direction":"prerequisites","hash":"bad"})),
        ("graph", json!({"direction":"prerequisites","extra":1})),
    ] {
        let mut input = input("prerequisites", "open");
        input[field] = value;
        assert!(Request::parse(input.to_string().as_bytes()).is_err());
    }
}

#[test]
fn filtered_graph_reports_only_status_selected_direct_neighbors() {
    let dir = fixture::fixture();
    fixture::run_successfully(dir.path(), &["wait", "add", "2", "3", "Needed"]);
    fixture::run_successfully(dir.path(), &["tag", "add", "3", "rust"]);
    for direction in ["prerequisites", "dependents"] {
        let mut query = input(direction, "open");
        query["filter"]["tags"] = json!(["rust"]);
        query["filter"]["kinds"] = json!(["feature"]);
        let (value, reads) = request(dir.path(), query.clone());
        assert_eq!(reads, 0);
        let rows = value["graph"]["plan"]["rows"].as_array().unwrap();
        assert_eq!(rows.len(), 2);
        assert!(rows.iter().all(|r| r["targets"] == json!([])));
        assert_eq!(rows[0]["id"], "0001");
        assert_eq!(rows[0]["filtered_prerequisites"], 1);
        assert!(rows[0].get("filtered_dependents").is_none());
        assert_eq!(rows[1]["id"], "0003");
        assert!(rows[1].get("filtered_prerequisites").is_none());
        assert_eq!(rows[1]["filtered_dependents"], 1);
        query["filter"]["text"] = json!(["Body."]);
        let (text, reads) = request(dir.path(), query);
        assert_eq!(reads, 2); // Only metadata-selected candidates are read.
        assert_eq!(text["graph"], value["graph"]);
    }
    let path = dir.path().join(".issues/0002-second.md");
    fs::write(
        &path,
        fs::read_to_string(&path)
            .unwrap()
            .replace("**Status:** open", "**Status:** closed"),
    )
    .unwrap();
    fixture::run_successfully(dir.path(), &["cache", "refresh"]);
    let mut query = input("prerequisites", "open");
    query["filter"]["tags"] = json!(["rust"]);
    let (value, _) = request(dir.path(), query.clone());
    assert!(
        value["graph"]["plan"]["rows"]
            .as_array()
            .unwrap()
            .iter()
            .all(|r| r.get("filtered_prerequisites").is_none()
                && r.get("filtered_dependents").is_none())
    );
    query["filter"]["status"] = json!("all");
    let (all, _) = request(dir.path(), query);
    assert_eq!(all["graph"]["plan"]["rows"][0]["filtered_prerequisites"], 1);
}

#[test]
fn changing_only_filtered_connections_invalidates_the_graph_token() {
    let dir = fixture::fixture();
    let mut query = input("prerequisites", "open");
    query["filter"]["tags"] = json!(["rust"]);
    let (first, _) = request(dir.path(), query.clone());
    query["graph"]["hash"] = first["graph"]["hash"].clone();
    query["view_hash"] = first["view_hash"].clone();
    let (same, _) = request(dir.path(), query.clone());
    assert!(same["graph"]["plan"].is_null());
    fixture::run_successfully(dir.path(), &["wait", "add", "1", "3", "Also needed"]);
    let (changed, _) = request(dir.path(), query);
    assert!(changed["view"].is_null());
    assert_ne!(changed["graph"]["hash"], first["graph"]["hash"]);
    assert_eq!(
        changed["graph"]["plan"]["rows"][0]["filtered_prerequisites"],
        2
    );
}
