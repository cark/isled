# Frontend snapshot contract

For compact filtered views and conditional detail batches, use the
[bounded frontend interface](frontend.md). This complete snapshot remains supported.

`isled snapshot` emits one deterministic JSON object for local
frontends. The top-level `schema_version` is `4`; `root` identifies
the canonical ledger root and `issues` is ordered by ascending issue ID. Every
issue contains `id`, `status`, `ready`, `kind`, `title`, `path`, and complete stored
`content`, plus complete structured `work` data. Work contains `state`, nullable
`reason` and `question`, completed `recorded_seconds`, nullable `running_since`,
and `spans` (each with `started`, nullable `stopped` and `activity`). Missing
tracking in a record projects as Not queued, zero seconds and an empty history.
Work state never changes readiness. `ready` is true exactly when the issue is open and has no relation
whose blocker is open, missing, or unreadable, matching `list --ready`. Either
surviving relation half counts, so removing a mirror does not grant readiness.
`kind` is the stored classification as a plain string: non-empty lowercase ASCII
letters, digits, and hyphens, with no leading or trailing hyphen. Custom kinds
are preserved. This field is required by the current frontend. Snapshot version 4 keeps
`outcome` reference fields and adds work data. Update the executable and frontend
together. Existing records need no conversion for work tracking. Earlier versions are not accepted
by the current frontend.
Each issue also contains a `references` array produced by Rust. Canonical
targets in Waiting on and Blocking metadata use `waiting_on` or `blocking`
fields. Statement, evidence, and outcome prose use their corresponding
fields; canonical prose uses `#NNNN`, while recognition accepts `#` followed by
one through four digits and normalizes the nonzero target. Escaped hashes,
longer or embedded forms, URLs, code spans, fenced code blocks, work metadata and activities, other structural
fields, and text inside Markdown links are not references. A same-ledger target
is `resolved`; an absent prose target remains a typed `missing` reference rather
than invalidating the snapshot.

Each reference records its `field` and zero-based `entry`: relation entries
count canonical relations, while prose entries count non-empty lines. It also
records exact `authored` spelling, canonical `target_id`, `resolution`, and
zero-based `byte_start`, `byte_length`, `character_start`, and
`character_length` relative to the complete stored record. Byte coordinates
count UTF-8 bytes; character coordinates count Unicode code points. Repeated
canonical or permissive spellings remain separate occurrence entries.

All byte-bearing fields retain `encoding` and `value` objects. Issue titles and
content are always `"utf-8"`; canonical root and path values use readable UTF-8
when possible and lossless `"base64"` otherwise. Unsafe paths, invalid filename
identities, and duplicate IDs fail without partial JSON. Malformed or unreadable
files instead appear in the ascending-ID top-level `unavailable` array, with
`id`, encoded `path`, and the actual UTF-8 `error`. They are not issue rows and
carry no fabricated title, status, or readiness. The snapshot still scans the
whole ledger; bounded frontend loading is separate work.

## Generated relation warnings

Each issue includes a `warnings` array (empty when none were found). Entries
contain a stable `code`, plain UTF-8 `message`, and `related_ids` array of
canonical four-digit IDs. `source_id` always identifies the dependent and
`target_id` its blocker, regardless of which endpoint displays the warning.
Boolean `needs_reason` says completion needs an explicitly supplied reason.
Codes are `RELATION_RECIPROCAL` (missing mirror),
`RELATION_TITLE` (stale copied title), `RELATION_MISSING`, and
`RELATION_UNREADABLE`. Missing-mirror warnings appear on both parseable endpoints.
Missing prose references remain ordinary reference annotations, not warnings.

Inspection automatically corrects copied relation titles from the related
issue's semantic title, preserving other bytes. Content and reference offsets
describe the resulting stored record. A failed correction remains visible as a
warning, with the failure reported on stderr. No relation half is added or
removed automatically. `wait repair complete ISSUE BLOCKER [--reason TEXT]`
and `wait repair remove ISSUE BLOCKER` express that choice; live help owns exact
failure behavior. Unreadable files can be opened for correction or explicitly
moved to trash by the Emacs client; removing their relations is a separate choice.

Local CLI inspection checks freshly read direct neighbors, not an unbounded
graph. An empty warning array is not a certificate of whole-ledger integrity.
Cycle detection remains in the non-repairing `check` command.
