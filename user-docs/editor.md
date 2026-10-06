# Complete issue drafts

Use this interface to load, validate or save a whole issue draft. The Emacs
editor uses it; ordinary CLI edits can use the [Statement commands](statement-editing.md)
instead.

`isled editor --stdin` reads one JSON request and returns one JSON response.
It uses **schema 4**, alongside browsing/snapshot schema 5. Older requests are
rejected. Keep the CLI and frontend compatible.

## Load a record

```json
{"schema_version":4,"mode":"load","id":"0042"}
```

A successful load returns the record, its editable draft and an opaque `version`.
Use that version as `expected` when validating or saving changes. It captures
the exact source and incoming dependency reasons.

## Request fields

| Field | Meaning |
| --- | --- |
| `schema_version` | Required: `4`. |
| `mode` | `load`, `validate` or `save`. |
| `id` | Existing issue ID; omit for creation. Load requires it. |
| `expected` | Version returned by load; required for an existing draft. Omit for creation. |
| `draft` | Complete editable fields; required for validate/save. |
| `close` | Optional boolean, false by default; close an existing issue during validate/save. |

To overwrite a conflict, submit the version the user just reviewed and confirmed.
There is no unconditional force flag.

### Editable draft

Draft fields are `title`, `kind`, `tags` (array), `statement`, `evidence` (array),
`outcome`, `waiting_on` and `blocking`. Each relation array contains objects with
`id` and a non-empty `reason`. Existing name, text, priority and graph validation
still applies. Empty Evidence becomes the canonical Pending entry.

Status, creation date, ID and filename are read-only. Creation derives the stable
filename from the first title and allocates an ID under the lock.

### Work data

The returned record includes read-only `work`: state, owner-wait details,
nullable UTC Since and complete span history. Use [work actions](work-tracking.md)
to change it. Ordinary saves preserve it.

A work action after load changes the source version, so a stale draft save is
rejected. Reload or compare before saving again.

## Responses

A decoded response exits 0, including domain failures. **Always inspect `ok`.**
CLI, root and stream failures use the existing nonzero stderr boundary.

| Response | Fields |
| --- | --- |
| Load/save success | `ok: true`, `record`, `path`. Record has `id`, `filename`, `status`, `version`, `source`, `draft`, `work`. |
| Validation success | `ok: true`, `validated: true`; no ID is allocated and no issue is published. |
| Failure | `ok: false`, `code`, `errors` with field locators and messages. |
| Conflict | Failure fields plus `current` for comparison and confirmation. |

Indexed locators identify Evidence or relation rows; operational errors use a
record locator. An optional `warning` reports a change to closed history.
Validation may reconcile disposable cache data, but copied-title repairs are
disabled during preflight.

## Publication and recovery

The complete proposed graph is checked before writing. Reciprocal updates read
neighbors fresh and preserve unrelated authored text. No-op records retain their
exact bytes. Validation and conflict rejection publish no issue records.

Publication is atomic per file, not across an interrupted multi-file save.
A `publication` failure means files may have changed. Inspect the saved state
before retrying; use `check` and deliberate recovery if needed. A possibly created
ID is returned when known, and a reserved ID can be consumed after validation.

Missing or undecodable save responses are uncertain too. Never retry creation
automatically: the first request may already have created its issue.

## Closing through a draft

`close: true` is valid only for validate/save of an existing issue. Concrete
Evidence and Outcome are required, as with `isled close`. Closure removes
priority and current work state, stops any running span, and keeps dependencies
and the complete work log as history.

Ordinary saves leave lifecycle status unchanged. Closure has the same per-file
publication boundary; stale-save and validation failures publish nothing.
