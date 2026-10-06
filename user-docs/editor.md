# Complete issue drafts

`isled editor --stdin` serves one JSON request and returns one JSON response.
Editor schema 4 accompanies browsing/snapshot schema 5 and optional work tracking
with current-state entry times.
Older versions are rejected. A decoded domain response exits 0: consumers must
inspect `ok`.
CLI/root/stream failures use the existing nonzero stderr boundary. Consumers
must treat missing or undecodable save responses as uncertain, never retry
creation automatically.

Requests have `schema_version: 4`, `mode` (`load`, `validate` or `save`), optional
`id`, optional `expected`, optional `draft`, and optional boolean `close` (false
by default). Load requires an existing ID.
Validate/save require a complete draft; omit ID/expected for creation. Existing
issues require the opaque `version` returned by load as `expected`. It captures
exact source plus incoming dependency reasons. An explicit overwrite submits the
version the user just reviewed/confirmed; there is no unconditional force flag.

Draft fields are `title`, `kind`, `tags` (array), `statement`, `evidence` (array),
`outcome`, `waiting_on` and `blocking`. Both relation arrays contain objects with
`id` and nonempty `reason`. Existing name, text, priority, lifecycle and graph
validation applies. Empty Evidence becomes the canonical Pending entry. Status,
creation date, ID and filename are not editable. Successful new saves derive
a stable filename from the initial title and allocate an ID under the lock.

Success has `ok: true`, `record` and `path`; record contains `id`, `filename`,
`status`, `version`, `source`, `draft` and read-only `work`.
Work contains state, owner-wait details, nullable UTC Since and complete span history; it is separate
from editable draft fields. Existing saves preserve it, and a work action after
load changes the source version, rejecting a stale save. Validation success
instead contains
`validated: true`; validation neither allocates nor publishes. Disposable cache
reconciliation may run, with copied-title repairs disabled during preflight.
An optional `warning` identifies changes to closed history.

Failure has `ok: false`, `code` and `errors` with field locators and messages.
Indexed locators identify Evidence or relation rows. Conflict responses also
include `current` for comparison/confirmation. Operational failures have a record
locator. `publication` means files may have changed; inspect/reconcile before
retrying. When known, a possibly created ID is returned even on publication
failure. A counter reservation can consume an ID after validation succeeds.

The complete proposed graph is checked before writing. Reciprocal updates read
neighbors fresh and preserve unrelated authored text. No-op records retain their
exact bytes. The existing per-file atomic publication limit applies: clean
validation/conflict rejection writes no issue records, but interrupted multi-file
publication is not a transaction and may need `check` and deliberate recovery.

`close: true` is valid only for validation/save of an existing issue. Rust plans
all draft edits and applies the same closure rules as `isled close` before
publication: concrete Evidence and Outcome are required, priority and current
work state are removed, any running span is stopped, and dependency relations
and the complete work log remain as history. Validation and stale-save failures
publish nothing. An ordinary save never changes lifecycle status. Closing stays
subject to the existing uncertain multi-file publication boundary above.
