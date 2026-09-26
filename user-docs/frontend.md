# Bounded frontend protocol

`isled frontend --stdin` reads one JSON request and writes one complete,
newline-terminated JSON response. Both use `schema_version: 3`. Invalid input
fails before project discovery; operational failures produce stderr, exit 1,
and no partial JSON. Version 3 uses Open/Closed lifecycle values and retains the `outcome` reference
field. Older requests are rejected; deploy the CLI, migrated ledgers and frontend
together. Version 3 `snapshot` output is supported separately.

## Request

```json
{"schema_version":3,"mode":"refresh","filter":{"status":"open"},"view_hash":null,"details":[{"id":"0058","hash":null}]}
```

- `mode` is `refresh`, `view`, `details`, or `choices`.
- `filter` is optional: `status` defaults to `open`, accepts `closed` or `all`;
  optional `kind` and a `tags` array use existing list semantics. Rust filters
  summaries; tags are not sent per summary.
- `choice_filter` optionally supplies independently parsed completion criteria,
  using the same fields and defaults as `filter`. See [completion choices](#filter-selection-and-completion-choices).
- `view_hash` is an optional previous view hash.
- `details` defaults to an empty array. Each entry has a unique canonical
  four-digit nonzero `id` and optional `hash`. Missing or null hashes request
  complete values. Hashes use exactly 16 lowercase hexadecimal digits.

Unknown request fields and duplicate detail IDs are errors. Root discovery and
`--root` retain their normal CLI meaning.

An optional `graph` field requests the [dependency layout](#dependency-layout).
Omitting it preserves the existing flat response and avoids graph extraction.

`refresh` reconciles the full ledger once, then obtains filtered summaries,
ledger-wide unreadable diagnostics, and requested details under the same lock.
`view` selects cached summaries, with ordinary best-effort cache freshness.
`choices` returns only completion choices: it does not select a view or inspect
requested details. Its `view_hash` must be absent/null and `details` absent/empty.
Detail requests reject `choice_filter`.
`details` inspects only requested records and their direct dependency neighbors,
sharing reads and parsed records across the batch. Ordinary cache membership
reconciliation may enumerate filenames and inspect newly discovered or pending
files; it does not reread every existing body. Missing, incompatible, or corrupt
caches can require a full rebuild before completing any mode. Rust owns that
recovery; clients need no recovery handshake or successful-rebuild notice.
Unrecoverable failures remain errors.

## Response

The top-level fields are `schema_version`, losslessly encoded `root`,
`view_hash`, `view`, `changes`, `first_warning`, and `warning_targets`. Byte objects use the
[snapshot encodings](snapshot.md); paths are canonical absolute paths.

`first_warning` is independent of the filter and conditional view hash. It is
null when no retained issue findings exist, otherwise the lowest affected ID as
`{"type":"issue","issue":SUMMARY}` or `{"type":"problem","problem":PROBLEM}`.
Summary/problem shapes are the same as below. This additive schema-3 field may
be absent from older executables; consumers may treat absence as unavailable
warning navigation. It is returned even when `view` and `changes` are unchanged.
`warning_targets` contains every affected issue once, ordered by ID, using the
same summary/problem shapes. It is independent of filtering and conditional
view hashes and reads only cached metadata; destinations load bodies as needed.
Older executables may omit it, in which case consumers can use `first_warning`
for single-target navigation. Empty arrays mean no known findings.

Known state is not proof of a whole-ledger check. Detail warnings include retained
findings that cannot yet be disproved because a related record is unreadable.

For refresh/view requests, `view_hash` identifies the current view; `view` is
null when it matches the supplied hash, otherwise an object with:

- `issues`: ascending-ID summaries containing `id`, `status`, `ready`, `kind`,
  encoded `title`, and encoded `path`.
- `unavailable`: ledger-wide unreadable entries, with `id`, encoded `path`, and
  actual `error`, including files outside the filter.

Detail-only and choices-only replies have null `view_hash` and `view`.
Choices-only replies have an empty `changes` array. `changes` contains only
requested IDs whose current live hash differs, in ascending order. Each has
`id`, `hash`, and `type`:

- `issue`: `detail` contains `issue` in the complete snapshot issue format,
  `targets` with referenced/diagnostic target summaries, and `unavailable` with
  relevant unreadable targets. Targets can be outside the filtered view.
- `deleted`: the requested identity is absent.
- `problem`: `problem` has `id`, `path`, and `error`. A null path means identity
  could not be established safely; offer no file action for it.

Omission confirms unchanged data only after the whole request succeeds and the
client verifies its root, requested IDs, and request generation. Do not apply
partial output. Full views reject unsafe or ambiguous identities as snapshots
do. Targeted lookups report uncertain absence as a problem, not a deletion.

## Freshness and hashes

Hashes are XXH3-64 of the compact JSON representation of the complete view or
of a detail payload including its `type`. Detail identity is the request/map key.
The hash covers content, readiness, reference resolutions, relation warnings,
and returned target summaries/problems. A dependency changing can therefore
invalidate detail data while the selected issue's authored bytes stay equal.
Clients treat hashes as opaque conditional tokens, not authenticated identities.
The accepted negligible accidental collision risk is the same as the disposable
content cache; these hashes are not security checks.

Direct neighbors are inspected before constructing requested detail semantics.
Prose-only target summaries use cached metadata and its existing best-effort
external-edit freshness. A full refresh reconciles all source records. There is
no atomic snapshot against external editors and no recursive graph read for
ordinary scrolling. Copied-title repair, lossless prose, warnings, and readiness
retain their existing contracts.

## Dependency layout

Graph data is an opt-in schema-3 extension. Existing requests and ascending-ID
`view.issues` stay unchanged. Graph clients use `graph.plan.rows` for display
order, keeping complete heading metadata separate from bounded body requests:

```sh
isled frontend --stdin <<'EOF'
{"schema_version":3,"mode":"view","filter":{"status":"open"},"graph":{"direction":"prerequisites"}}
EOF
```

`graph` accepts `direction` (`prerequisites` or `dependents`) and an optional
previous `hash`, with the same 16-lowercase-hex syntax as other conditional tokens.
It is valid only with `view` or `refresh`. All ordinary filter criteria apply:
status first, then tag, kind and text selection. Emacs requests a graph only in
hierarchical mode; flat mode requests summaries without one.

For a filtered Open graph:

```sh
isled frontend --stdin <<'EOF'
{"schema_version":3,"mode":"view","filter":{"status":"open","tags":["rust"],"text":["timeout"]},"graph":{"direction":"prerequisites"}}
EOF
```

A graph request returns `graph` containing `hash`, `direction`, and `plan`.
The plan is null only when the supplied graph token matches. A changed plan has:

- `lanes`: the number of logical columns, zero for an empty selection.
- `rows`: each selected readable issue exactly once, in deterministic topological
  display order. Every row has canonical string `id`, zero-based `lane`, `start`
  and `targets`, plus omitted-connection counts when nonzero.
- `start`: the earliest incoming source row index, or null for a root.
- `targets`: sorted unique absolute row indices for direct outgoing display
  routes. Targets follow their source row. The target row supplies its lane;
  edges sharing a destination share its vertical track.
- `filtered_prerequisites`, `filtered_dependents`: nonnegative counts of direct
  neighbors inside the status selection but excluded by additional filters.
  Each field is omitted when zero, keeping unfiltered plans compact. Their semantic direction
  is independent of the display direction. Neighbors excluded by status or
  unreadability never contribute; either surviving relation half counts once.
- `drawing`: physical lane assignments and sparse routing-only junctions for
  the text gutter, described below. The fields above retain their direct-edge
  meaning independently of the drawing.

Connected components stay contiguous and are placed by their smallest issue ID;
independent issues are singleton components in that same order. Inside each
component, dependency order takes precedence and newly unblocked branches are
followed first, preferring fewer outgoing edges and then issue ID among nodes
unblocked together. Lane zero is reserved for roots (`start: null`); incoming tracks
and their terminal issues occupy higher lanes. Algorithm changes invalidate the
graph token; the junction revision uses algorithm version 3.

`drawing` contains its own `lanes` count and ordered `steps`. Each real step has
`row` (an index into `plan.rows`), `lane`, and `start` (the earliest incoming
**step index**, or null). Real rows occur exactly once and in semantic row order.
Ordinary steps derive outgoing destinations from that row's `targets`, mapped
to step indices; they do not repeat the edge list on the wire.

Sources with identical sets of at least two destinations may instead have
`join`, the index of a later routing-only step. That junction has `row: null`,
its own `lane` and `start`, and `targets` containing the shared **semantic row
indices**. At least two sources must feed it, and its outgoing set must equal
each source's original outgoing set. Junctions never join other junctions.
This permits a merge followed by a separate split without inventing edges or
duplicating issues. Clients validate the drawing against the semantic rows;
no four-way junction is needed. Text geometry may use several horizontal
routing lines between issue headings, interrupting vertical strokes at
non-joining crossings. Routing steps add no selectable issues or loaded bodies.

Prerequisites-first routes run from prerequisites to dependents. Dependents-first
reverses display traversal only; stored wait meaning does not change. Draw an
edge only when both readable endpoints meet the complete filter. Never
bridge an excluded intermediate node. Readiness retains its actual-ledger meaning.
Unreadable records and retained warnings use the existing independent fields.

The graph token covers algorithm version, status, direction, selected identities
and direct edges, plus omitted-connection counts. Title/prose changes do not
change it unless they change text-filter membership; relevant edge changes do even when
headings and readiness remain equal. Thus a response can have null `view` and a
changed graph plan, or changed headings and null `graph.plan`. Validate a retained
or supplied plan against the current heading membership before displaying it.

Rust obtains status-selected edges from metadata, counts connections cut by
additional filters in one indexed pass, and lays out the remaining direct edges.
Warm metadata-only graph selection does not read issue bodies; refresh, explicit detail requests and text matching retain
their existing read scopes. Emacs retains the logical plan; ordinary scrolling
and expansion make no layout request. No persistent Rust layout cache is used.
Transport and retained logical storage grow with nodes plus edges, without a
dense row-by-lane matrix. A provisional 1,000,000-edge budget retains the measured
candidate's allocation bound for status-selected edges before additional filters:
exceeding it rejects the graph request, preserving
the previous view. No edge is silently omitted, and lane width has no fixed cap.
Cycles are errors. Clients keep their last good view on failure.

Graph view requires the updated CLI and frontend. There is no graph fallback for
older CLIs; existing flat clients continue working with the updated executable.
This extension changes neither issue files nor the complete snapshot schema.

## Filter selection and completion choices

The optional `filter.text` array adds case-insensitive literal terms. Every term
must occur somewhere in the candidate's complete Markdown record; terms may match
across different sections, including relation reasons. A term containing spaces
is a phrase. Empty or multiline terms are invalid. `filter.kinds` adds conjunctive
kind constraints alongside the existing optional `kind`; incompatible kinds
produce no matches. Existing request defaults and CLI `search` behavior remain.

Metadata selection runs first. Text selection reads those candidate files through
the existing per-operation reader; no persistent text index is introduced.
Read/encoding failures fail the response without partial results. Metadata keeps
its existing freshness boundary. Text filtering does not refresh unrelated bodies
or validate dependency neighborhoods. A full refresh remains the reconciliation
boundary.

Refresh/view responses also contain `choices`, an array of prefixed strings:
`t:NAME`, `k:NAME`, `s:open`, and `s:closed`. Choices cover the ledger's cached
metadata, independently of the current filter, and are returned even when `view`
is null. `s:closed` is a frontend label for stored status `closed`; request
`filter.status` still uses `closed`. Detail responses omit choices. Clients
may ignore this additive field. The human filter grammar belongs to the Emacs
frontend; this protocol transports its parsed criteria.

Supplying `choice_filter` scopes choices to readable cached issues matching all
of those criteria, including Unicode text terms and literal phrases. Tags and
kinds come only from those matching issues. Status choices ignore the supplied
status constraint, because choosing a status replaces status rather than adding
another constraint. With no matching issue, that category has no choices;
an empty ledger yields an empty array. Statuses appear first (`open`, `closed`),
then unique alphabetically ordered tags and kinds. Cached tag and kind values
are fully validated in that order before contextual choices return, including
when no issue matches. Text read failures still fail the complete response.

Clients send the criteria remaining after removing the exact token occurrence
being edited. For status completion they remove every status token. The full
`filter` still describes the actual typed query for the preview. A cursor move
or partial token can request `choices` alone; valid text edits can obtain both
the preview and contextual choices in one `view` request. Both selections share
the command's retained file reads. There is no persistent completion cache or
text index. Omitting `choice_filter` retains the older ledger-wide choices,
including both status labels, for existing clients.
