# Frontend snapshot contract

`isled snapshot` returns the complete ledger as one deterministic JSON object.
For compact filtered views and conditional body requests, use the
[bounded frontend interface](frontend.md).

The current **schema version is 5**. Update the executable and frontend together;
the current frontend rejects earlier versions. Work tracking needs no conversion
of existing records.

## Top-level fields

| Field | Meaning |
| --- | --- |
| `schema_version` | `5`. |
| `root` | Losslessly encoded canonical ledger root. |
| `issues` | Readable issues, sorted by ascending ID. |
| `unavailable` | Malformed or unreadable records, sorted by ID. |

Unsafe paths, invalid filename identities and duplicate IDs fail without partial
JSON. Unavailable entries have `id`, encoded `path` and the actual UTF-8 `error`.
They have no fabricated title, status or readiness.

## Issue fields

Each issue contains `id`, `status`, `ready`, `kind`, `title`, `path`, complete
stored `content`, structured `work`, `references` and `warnings`.

`ready` is true when the issue is open and has no open, missing or unreadable
prerequisite, matching `list --ready`. Either surviving relation half counts.
Work state does not affect readiness.

`kind` is the stored classification, including custom kinds. Its grammar is
non-empty lowercase ASCII letters, digits and hyphens, with no leading or
trailing hyphen. The field is required by the current frontend.

### Work

`work` contains `state`, nullable `reason`, `question` and UTC `since`, completed
`recorded_seconds`, nullable `running_since`, and `spans`. Each span contains
`started`, nullable `stopped` and `activity`.

Missing tracking becomes Not queued, zero seconds and an empty history. Since
marks current-state entry; running elapsed time is calculated separately. See
[work data](work-tracking.md#files-and-agent-data).

### Encodings

Byte-bearing values use objects with `encoding` and `value`. Titles and content
are always `"utf-8"`. Root and paths use readable UTF-8 when possible, otherwise
lossless `"base64"`.

## Issue references

Rust supplies the `references` array; clients need not search Markdown.
Waiting on and Blocking targets use `waiting_on` and `blocking` fields. Statement,
Evidence and Outcome references use their corresponding fields.

Canonical prose uses `#NNNN`. Recognition accepts one to four digits after `#`
and normalizes the nonzero ID. An existing same-ledger target is `resolved`;
an absent prose target is `missing` and does not invalidate the snapshot.

Escaped hashes, longer or embedded forms, URLs, code spans, fences, Markdown link
text, work metadata, activities and other structural fields are not references.

Each occurrence has:

| Field | Meaning |
| --- | --- |
| `field`, `entry` | Field and zero-based entry; relations count canonical relations, prose counts non-empty lines. |
| `authored`, `target_id`, `resolution` | Exact spelling, canonical target and resolution. |
| `byte_start`, `byte_length` | UTF-8 byte coordinates in the complete stored record. |
| `character_start`, `character_length` | Unicode code-point coordinates in that record. |

Repeated spellings remain separate occurrences. Offsets describe the stored
content returned after any copied-title correction.

## Generated relation warnings

Each issue has a `warnings` array, empty when none were found. Every warning has
`code`, plain UTF-8 `message`, canonical `related_ids`, `source_id`, `target_id`
and boolean `needs_reason`.

Source always means the dependent, target its prerequisite, regardless of which
endpoint displays the warning. `needs_reason` marks a completion that needs an
explicit reason.

| Code | Finding |
| --- | --- |
| `RELATION_RECIPROCAL` | A mirror is missing; appears on both parseable endpoints. |
| `RELATION_TITLE` | A copied title is stale. |
| `RELATION_MISSING` | The related record is absent. |
| `RELATION_UNREADABLE` | The related record cannot be read. |

Missing prose references are ordinary reference annotations, not warnings.

Inspection corrects copied titles automatically, preserving other bytes. A
failed correction remains a warning and is reported on stderr. No relation is
added or removed automatically. Choose deliberately with
`wait repair complete ISSUE BLOCKER [--reason TEXT]` or
`wait repair remove ISSUE BLOCKER`; live help owns exact failure behavior.

Emacs can open unreadable files for repair or move them to trash. Removing their
relations is a separate action. Inspection checks direct neighbors; an empty
warning array does not certify whole-ledger integrity. Use the non-repairing
`check` command, which also detects cycles.
