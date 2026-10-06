use isled::{
    editor,
    filesystem::{ProjectRoot, initialize_ledger},
};
use serde_json::{Value, json};
use std::{fs, path::Path};
fn call(
    root: &Path,
    mode: &str,
    id: Option<&str>,
    expected: Option<&str>,
    draft: Option<Value>,
) -> Value {
    editor::respond(
        &ProjectRoot::explicit(root).unwrap(),
        &serde_json::to_vec(
            &json!({"schema_version":4,"mode":mode,"id":id,"expected":expected,"draft":draft}),
        )
        .unwrap(),
    )
}
fn draft(title: &str) -> Value {
    json!({"title":title,"kind":"feature","tags":[],"statement":"Body café\n\nSecond paragraph.","evidence":[],"outcome":"Pending.","waiting_on":[],"blocking":[]})
}
fn add(root: &Path, title: &str) -> Value {
    let result = call(root, "save", None, None, Some(draft(title)));
    assert_eq!(result["ok"], true, "{result}");
    result
}
fn load(root: &Path, id: &str) -> Value {
    let v = call(root, "load", Some(id), None, None);
    assert_eq!(v["ok"], true, "{v}");
    v
}
fn save(root: &Path, old: &Value, draft: Value) -> Value {
    call(
        root,
        "save",
        old["record"]["id"].as_str(),
        old["record"]["version"].as_str(),
        Some(draft),
    )
}
fn setup() -> tempfile::TempDir {
    let t = tempfile::tempdir().unwrap();
    initialize_ledger(t.path()).unwrap();
    t
}
#[test]
fn validation_is_read_only_and_add_edit_preserves_identity() {
    let t = setup();
    let r = t.path();
    let original = fs::read(r.join(".issues/.next-id")).unwrap();
    assert_eq!(
        call(r, "validate", None, None, Some(draft("New issue")))["ok"],
        true
    );
    assert_eq!(fs::read(r.join(".issues/.next-id")).unwrap(), original);
    assert_eq!(
        fs::read_dir(r.join(".issues"))
            .unwrap()
            .filter(|e| e
                .as_ref()
                .unwrap()
                .path()
                .extension()
                .is_some_and(|x| x == "md"))
            .count(),
        0
    );
    let a = add(r, "New issue");
    let path = a["path"].as_str().unwrap();
    let before = fs::read(path).unwrap();
    assert_eq!(save(r, &a, a["record"]["draft"].clone())["ok"], true);
    assert_eq!(fs::read(path).unwrap(), before);
    let mut d = a["record"]["draft"].clone();
    d["title"] = json!("Changed");
    d["kind"] = json!("custom-kind");
    d["evidence"] = json!(["First proof", "Second proof"]);
    d["outcome"] = json!("Conclusion\ncontinued");
    let b = save(r, &a, d);
    assert_eq!(b["ok"], true, "{b}");
    assert_eq!(b["path"], a["path"]);
    assert_eq!(b["record"]["status"], "open");
    assert_eq!(
        b["record"]["draft"]["statement"],
        a["record"]["draft"]["statement"]
    );
}
#[test]
fn field_errors_and_stale_save_do_not_write() {
    let t = setup();
    let r = t.path();
    let a = add(r, "A");
    let mut d = a["record"]["draft"].clone();
    d["kind"] = json!("INVALID");
    let bad = save(r, &a, d);
    assert_eq!(bad["errors"][0]["field"], "kind");
    assert_eq!(load(r, "0001")["record"]["version"], a["record"]["version"]);
    let mut d = a["record"]["draft"].clone();
    d["title"] = json!("External edit");
    let b = save(r, &a, d.clone());
    assert_eq!(b["ok"], true);
    let stale = save(r, &a, a["record"]["draft"].clone());
    assert_eq!(stale["code"], "conflict");
    let overwrite = save(r, &b, a["record"]["draft"].clone());
    assert_eq!(overwrite["ok"], true);
    assert_eq!(save(r, &b, d)["code"], "conflict");
}
#[test]
fn relations_update_both_directions_preserve_neighbor_and_reject_cycles() {
    let t = setup();
    let r = t.path();
    let a = add(r, "A");
    let b = add(r, "B");
    let c = add(r, "C");
    let mut d = a["record"]["draft"].clone();
    d["waiting_on"] = json!([{"id":"0002","reason":"Needs B"}]);
    d["blocking"] = json!([{"id":"0003","reason":"C needs A"}]);
    let a = save(r, &a, d);
    assert_eq!(a["ok"], true, "{a}");
    let b2 = load(r, "0002");
    assert_eq!(b2["record"]["draft"]["blocking"][0]["id"], "0001");
    assert_eq!(
        b2["record"]["draft"]["statement"],
        b["record"]["draft"]["statement"]
    );
    let c2 = load(r, "0003");
    assert_eq!(c2["record"]["draft"]["waiting_on"][0]["id"], "0001");
    assert_eq!(
        c2["record"]["draft"]["statement"],
        c["record"]["draft"]["statement"]
    );
    let mut d = b2["record"]["draft"].clone();
    d["waiting_on"] = json!([{"id":"0003","reason":"Would cycle"}]);
    assert_eq!(save(r, &b2, d)["errors"][0]["field"], "waiting_on.0");
    assert_eq!(
        load(r, "0002")["record"]["version"],
        b2["record"]["version"]
    );
    let mut d = a["record"]["draft"].clone();
    d["waiting_on"] = json!([]);
    d["blocking"] = json!([]);
    assert_eq!(save(r, &a, d)["ok"], true);
    assert_eq!(load(r, "0002")["record"]["draft"]["blocking"], json!([]));
}
#[test]
fn incoming_reason_conflicts_but_unrelated_neighbor_edits_survive() {
    let t = setup();
    let r = t.path();
    let a = add(r, "A");
    let b = add(r, "B");
    let mut d = a["record"]["draft"].clone();
    d["blocking"] = json!([{"id":"0002","reason":"Before"}]);
    let a = save(r, &a, d);
    assert_eq!(a["ok"], true);
    let b2 = load(r, "0002");
    let mut d = b2["record"]["draft"].clone();
    d["statement"] = json!("External neighbor text");
    assert_eq!(save(r, &b2, d)["ok"], true);
    let mut d = a["record"]["draft"].clone();
    d["title"] = json!("A renamed");
    let a = save(r, &a, d);
    assert_eq!(a["ok"], true, "{a}");
    assert_eq!(
        load(r, "0002")["record"]["draft"]["statement"],
        "External neighbor text"
    );
    let b2 = load(r, "0002");
    let mut d = b2["record"]["draft"].clone();
    d["waiting_on"][0]["reason"] = json!("After");
    assert_eq!(save(r, &b2, d)["ok"], true);
    assert_eq!(
        save(r, &a, a["record"]["draft"].clone())["code"],
        "conflict"
    );
    assert_eq!(b["record"]["id"], "0002");
}
#[test]
fn add_with_relations_and_final_graph_reversal() {
    let t = setup();
    let r = t.path();
    add(r, "A");
    let mut d = draft("B");
    d["waiting_on"] = json!([{"id":"0001","reason":"Needs A"}]);
    let b = call(r, "save", None, None, Some(d));
    assert_eq!(b["ok"], true, "{b}");
    let a = load(r, "0001");
    let mut d = a["record"]["draft"].clone();
    d["blocking"] = json!([]);
    d["waiting_on"] = json!([{"id":"0002","reason":"Reversed"}]);
    assert_eq!(save(r, &a, d)["ok"], true);
}
#[test]
fn validation_does_not_repair_copied_titles() {
    let t = setup();
    let r = t.path();
    let a = add(r, "A");
    add(r, "B");
    let mut d = a["record"]["draft"].clone();
    d["waiting_on"] = json!([{"id":"0002","reason":"Needs B"}]);
    let a = save(r, &a, d);
    assert_eq!(a["ok"], true);
    let b = load(r, "0002");
    let path = b["path"].as_str().unwrap();
    let contents = fs::read_to_string(path)
        .unwrap()
        .replace("#0001 — A", "#0001 — Old title");
    fs::write(path, &contents).unwrap();
    let a = load(r, "0001");
    let v = call(
        r,
        "validate",
        Some("0001"),
        a["record"]["version"].as_str(),
        Some(a["record"]["draft"].clone()),
    );
    assert_eq!(v["ok"], true, "{v}");
    assert_eq!(fs::read_to_string(path).unwrap(), contents);
}

#[test]
fn publication_failure_is_not_reported_as_clean_rejection() {
    let t = setup();
    let r = t.path();
    let a = add(r, "A");
    add(r, "B");
    let mut d = a["record"]["draft"].clone();
    d["waiting_on"] = json!([{"id":"0002","reason":"Needs B"}]);
    fs::create_dir(r.join(format!(".issues/.isled-close-{}", std::process::id()))).unwrap();
    let result = save(r, &a, d);
    assert_eq!(result["code"], "publication");
    assert_eq!(result["id"], "0001");
}
#[test]
fn invalid_new_draft_does_not_consume_id_and_pending_evidence_is_consistent() {
    let t = setup();
    let r = t.path();
    let before = fs::read(r.join(".issues/.next-id")).unwrap();
    for (field, value) in [
        ("title", json!("")),
        ("evidence", json!(["Pending.", "Real proof"])),
        ("statement", json!("Text\n\n## Bad heading")),
        ("outcome", json!("Two\n\nparagraphs")),
    ] {
        let mut d = draft("A");
        d[field] = value;
        assert_eq!(call(r, "save", None, None, Some(d))["ok"], false);
        assert_eq!(fs::read(r.join(".issues/.next-id")).unwrap(), before);
    }
}

fn closing(root: &Path, mode: &str, old: &Value, draft: Value) -> Value {
    editor::respond(
        &ProjectRoot::explicit(root).unwrap(),
        &serde_json::to_vec(
            &json!({"schema_version":4,"mode":mode,"id":old["record"]["id"],
                "expected":old["record"]["version"],"draft":draft,"close":true}),
        )
        .unwrap(),
    )
}

#[test]
fn close_preflights_draft_and_closure_together() {
    let t = setup();
    let old = add(t.path(), "Close me");
    let original = fs::read(old["path"].as_str().unwrap()).unwrap();
    let mut draft = old["record"]["draft"].clone();
    draft["title"] = json!("Edited while closing");
    draft["tags"] = json!(["priority-high", "ui"]);
    let failed = closing(t.path(), "save", &old, draft.clone());
    assert_eq!(failed["errors"][0]["field"], "evidence");
    assert_eq!(fs::read(old["path"].as_str().unwrap()).unwrap(), original);
    draft["evidence"] = json!(["Verified."]);
    assert_eq!(
        closing(t.path(), "validate", &old, draft.clone())["errors"][0]["field"],
        "outcome"
    );
    draft["outcome"] = json!("Completed.");
    assert_eq!(
        closing(t.path(), "validate", &old, draft.clone())["ok"],
        true
    );
    assert_eq!(fs::read(old["path"].as_str().unwrap()).unwrap(), original);
    let saved = closing(t.path(), "save", &old, draft.clone());
    assert_eq!(saved["ok"], true, "{saved}");
    assert_eq!(saved["record"]["status"], "closed");
    assert_eq!(saved["record"]["draft"]["tags"], json!(["ui"]));
    assert_eq!(saved["record"]["draft"]["title"], draft["title"]);
    assert_eq!(saved["path"], old["path"]);
    assert_eq!(
        closing(t.path(), "save", &saved, draft.clone())["ok"],
        false
    );
    assert_eq!(closing(t.path(), "save", &old, draft)["code"], "conflict");
}

#[test]
fn close_keeps_relations_and_copied_titles() {
    let t = setup();
    let blocker = add(t.path(), "Blocker");
    let dependent = add(t.path(), "Dependent");
    let mut draft = dependent["record"]["draft"].clone();
    draft["waiting_on"] = json!([{"id":"0001","reason":"Needed."}]);
    assert_eq!(save(t.path(), &dependent, draft)["ok"], true);
    let blocker = load(t.path(), blocker["record"]["id"].as_str().unwrap());
    let mut draft = blocker["record"]["draft"].clone();
    draft["evidence"] = json!(["Verified."]);
    draft["outcome"] = json!("Completed.");
    draft["title"] = json!("Finished blocker");
    let closed = closing(t.path(), "save", &blocker, draft);
    assert_eq!(closed["ok"], true, "{closed}");
    assert_eq!(closed["record"]["draft"]["blocking"][0]["id"], "0002");
    let dependent = load(t.path(), "0002");
    assert_eq!(dependent["record"]["draft"]["waiting_on"][0]["id"], "0001");
    assert!(
        dependent["record"]["source"]
            .as_str()
            .unwrap()
            .contains("Finished blocker")
    );
}
