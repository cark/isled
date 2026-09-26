//! Locked orchestration of the complete-draft editor protocol.
mod request;
mod store;
use crate::{
    filesystem::ProjectRoot,
    mutation::editor::{self, Editable, FieldError, ValidatedDraft},
};
use request::{Mode, Request};
use serde_json::{Value, json};

/// Serve one versioned request. Domain failures are structured responses.
pub fn respond(root: &ProjectRoot, input: &[u8]) -> Value {
    match execute(root, input) {
        Ok(value) => value,
        Err(error) => json!({"schema_version":2,"ok":false,"code":error.code,"errors":[error]}),
    }
}
fn execute(root: &ProjectRoot, input: &[u8]) -> Result<Value, FieldError> {
    let request = Request::parse(input)?;
    let draft = request.draft.map(ValidatedDraft::parse).transpose()?;
    if request.mode != Mode::Load && draft.is_none() {
        return Err(FieldError::new("request", "A complete draft is required"));
    }
    let lock = root.acquire_lock().map_err(store::error)?;
    let mut records = store::load_records(&lock, request.id, draft.as_ref())?;
    let current = request
        .id
        .map(|id| editor::editable(&records, id))
        .transpose()?;
    if request.mode == Mode::Load {
        return current
            .map(|v| success(v, root))
            .ok_or_else(|| FieldError::new("request", "Load requires an issue ID"));
    }
    if let Some(current) = &current {
        if request.expected.as_ref() != Some(&current.version) {
            return Ok(
                json!({"schema_version":2,"ok":false,"code":"conflict","current":current,
                "errors":[{"field":"record","message":"The saved issue or its dependency reasons changed. Compare, reload, or confirm overwrite."}]}),
            );
        }
    } else if request.expected.is_some() {
        return Err(FieldError::new(
            "request",
            "New drafts cannot carry an expected version",
        ));
    }
    let id = request
        .id
        .map(Ok)
        .unwrap_or_else(|| lock.next_available_id().map_err(store::error))?;
    let draft = draft.expect("required above");
    if request.id.is_none() {
        records.insert(id, store::blank_record(id, &draft)?);
    }
    let graph = store::graph(&lock, records.keys().copied())?;
    let plan = editor::plan(&records, id, draft, &graph, request.id.is_none())?;
    let plan = if request.close {
        editor::close_plan(&records, id, plan)?
    } else {
        plan
    };
    if request.mode == Mode::Validate {
        return Ok(json!({"schema_version":2,"ok":true,"validated":true}));
    }
    let was_closed = request.id.is_some() && editor::closed(&records, id);
    // Everything above is preflight. Any failure below may follow publication.
    let result = if request.id.is_none() {
        lock.add_draft(id, &plan)
    } else {
        lock.publish(&plan)
    };
    if let Err(error) = result {
        return Ok(
            json!({"schema_version":2,"ok":false,"code":"publication", "id":id.to_string(),
            "errors":[{"field":"record","message":format!("Save may be partially applied: {error}. Inspect the ledger before retrying.")}]}),
        );
    }
    for replacement in plan.replacements() {
        let issue = replacement.record().issue().map_err(store::error)?;
        records.insert(issue.id(), replacement.record().clone());
    }
    let saved = editor::editable(&records, id)?;
    let mut response = success(saved, root);
    if was_closed && !plan.replacements().is_empty() {
        response["warning"] =
            json!("Updating historical content of a closed issue; status is unchanged.");
    }
    lock.finish().map_err(|error| FieldError {
        code: "publication",
        field: "record".into(),
        message: format!("Saved, but lock cleanup failed: {error}. Inspect before retrying."),
    })?;
    Ok(response)
}
fn success(record: Editable, root: &ProjectRoot) -> Value {
    let path = root.issues_dir().join(&record.filename);
    json!({"schema_version":2,"ok":true,"record":record,"path":path.to_string_lossy()})
}
