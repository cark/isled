# Rust compatibility contract

This page owns preservation guarantees and change policy, not a second command,
storage, or frontend specification. Current CLI behavior is documented in the
[user guide](../user-docs/README.md), exact syntax in installed help, storage in
the [record contract](../user-docs/record-format.md), wire data in the
[snapshot contract](../user-docs/snapshot.md), and Emacs behavior in the
[frontend guide](../frontends/emacs/README.md). Accepted rationale lives in
[decisions](decisions.md); implementation evidence and tests establish compliance.

## Supported identity and versions

The executable and package are `isled`. Current records use Outcome and Open /
Closed; old product names, action commands and legacy record headings have no
compatibility aliases. The current [record grammar](../user-docs/record-format.md)
and [wire contracts](../user-docs/README.md#frontend-snapshot) define supported input.
Historical one-time migrations are not part of the public CLI. A new format change
requires explicit maintainer agreement and a preservation/recovery plan.

## Comparison levels

Protect established CLI callers and valid ledger data across command discovery,
stdout/stderr routing, deterministic output, exit meaning, root selection,
identity and no-reuse allocation, semantic validation, and filesystem effects.
Require byte-exact preservation of valid UTF-8 stored prose outside the fields
an operation intentionally changes and of existing data-bearing output.

Rust library source compatibility is not a requirement for this single-consumer
project. Remove obsolete interfaces when improving the trusted construction
boundary; this does not authorize CLI or stored-data changes.

Help and diagnostic prose may be Rust-native, but must remain deterministic,
colorless, terminal-width-independent, actionable, and complete. Explicit help
never discovers or mutates a project. Missing commands and bare namespaces
print the relevant inventory to stdout and exit 1; explicit help exits 0;
ordinary invocation/operational failures use stderr and exit 1. The `check`
command distinguishes operational failures with stderr and exit 2; integrity
findings use stdout and exit 1, as documented in the user guide.

`--version` and `-V` print `isled VERSION` to stdout and exit 0 without ledger
discovery or mutation. The version derives from Cargo metadata. Ordinary source
builds append `-dev`; the explicit `release-binary` feature selects the shared
release version. Version text identifies a build, not its publication provenance.

Command-specific validation order remains observable: reject invalid input
before discovery where established, while `show` retains root-before-ID order.
An intentional change needs an maintainer-visible decision, an update to the owning
contract, and focused evidence. A durable issue is warranted only for a concern
that must remain visible, not for every routine edit.

## Storage and operation boundaries

The [record grammar](../user-docs/record-format.md) is the only supported
Markdown format. Mirrored relations and stable filenames are part of the
contract; closure satisfies dependencies without deleting their history.
The completed converter is inert research, not a supported migration command.

Validation is operation-scoped: filename identity, headers, or complete records
are read only when needed. Single-ID `show` preserves malformed but valid-UTF-8 Markdown;
selected mutations parse and report the target's actual error. Duplicate
identities include malformed matching records. Whole-record operations
(`search`) still fail coherently on invalid required records. Snapshot instead
reports unreadable files separately, without inventing issue metadata.
`check` retains raw-byte diagnostic access and continues across independent
defects. The [user guide](../user-docs/README.md#command-surface-and-storage)
owns command-specific scope and UTF-8 behavior.

The accepted [cache contract](../user-docs/cache.md) qualifies metadata
freshness: external edits are best effort, malformed cached records are excluded
with incomplete-result warnings, and queries may write disposable cache data.
Single-ID `show` retains exact raw inspection after automatic copied-title reconciliation.
Malformed valid-UTF-8 records remain unchanged and inspectable.
Graph queries and cycle checks use cached relationships after targeted refresh;
`check` remains the authoritative full integrity audit. The lock moved inside
`.issues/.cache/`; do not run pre-cache and current executables concurrently.
Brief contention now waits up to 500 ms at acquisition rather than failing
immediately, as specified in the cache contract; operations themselves are not
retried and the exclusive locking boundary is unchanged.

Generated local relation warnings preserve CLI stdout and appear on stderr.
Snapshots now retain parseable issues with inconsistent relations and attach
typed warnings instead of failing for those relations. Unreadable files carry
their actual error separately; unsafe paths and duplicate identities still fail
without partial JSON. The
[warning contract](../user-docs/snapshot.md#generated-relation-warnings) owns
codes, scope, and frontend semantics. Copied titles alone auto-repair, preserving
all unrelated bytes under the existing lock without recursive synchronization.
Missing mirrors warn on both endpoints and either surviving half conservatively
counts as a dependency. Explicit `wait repair` completes/removes chosen relations.
`check` remains non-repairing; snapshot reconciliation still scans the full ledger.

The design accepts 64-bit content fingerprints for avoiding unchanged SQLite
projection writes, including their negligible accidental collision risk. The
[cache design](cache-design.md#unchanged-content) owns the interpretation and
invalidation boundary. Required validation, error visibility, and authored bytes
remain governed by the contracts above.

Mutations validate required inputs before publication, hold the directory lock,
reconcile allocation state, stage deterministic replacements, and replace each
file atomically. Multi-file interruption remains detectable by `check`;
there is no transaction journal. Title edits preserve canonical paths and
refresh copied titles in direct neighbors. Closure is terminal; intentional
historical corrections warn only when the selected closed record changes.

The [batch inspection contract](../user-docs/README.md#inspecting-several-issues)
preserves single-ID inspection. Multiple ID arguments select readable ordered
output, including repeats, with only necessary inter-record newlines. Individual
failures omit that record, retain ID-attributed stderr errors, allow other records
to print and give exit status 1. Relation warnings alone remain nonfatal. Command
input and shared operational failures remain command errors. Batch output is not
promised byte-exact as a combined stream.

## Structured record format

The maintained [record contract](../user-docs/record-format.md) owns the grammar.
Ordinary commands never silently migrate legacy records.

## Statement editing

The [Statement editing contract](../user-docs/statement-editing.md) adds stdin
creation, whole-Statement set, append, and literal replacement without changing
valid argument-based input or the record grammar. Creation rejects reserved level-two headings before
allocation, including headings supplied as a statement argument.
Invalid or ambiguous edits publish nothing; bytes outside
Statement remain exact. No generic patch or other-section stdin interface is
implied.
Every Statement mutation, including argument-based set/append, uses the same
final validation and byte-preserving replacement boundary. Previously accepted
reserved-heading arguments are rejected rather than publishing invalid records.

## Closed-record mutation warning


The [lifecycle contract](../user-docs/README.md#issue-lifecycle-and-integrity)
owns warning behavior. Exact historical command spelling remains discoverable
in live help and the implementation evidence linked by its issue.

## Targeted dependency trees

Targeted dependency trees and their versioned adjacency JSON preserve edge
orientation and reasons in either traversal direction. The
[tree contract](../user-docs/README.md#dependency-tree-inspection) owns fields,
historical leaves, repetition, and optional paths.

## Additive frontend snapshot

The additive [snapshot interface](../user-docs/snapshot.md) leaves existing
human output formats unchanged. Rust owns parsing, readiness, same-ledger
reference resolution, and complete-record coordinates. Construction uses typed
inputs without I/O; encoding is at the outer boundary. Invalid identities
produce no partial JSON; unreadable file contents are explicit recovery entries.
Missing prose targets are annotations, not integrity
failures.

The version 1 snapshot also exposes the existing stored `kind` as an additive
field. Earlier fields and their meaning are unchanged; the current Emacs
frontend requires this field for heading labels. Storage, kind filters, and
human CLI output retain their existing contracts.

The additive [bounded interface](../user-docs/frontend.md) supplies filtered
views and changed detail batches while preserving complete `snapshot` output.
Full refresh retains strict ledger identities and unreadable-file diagnostics;
targeted batches return explicit deletion or problem data and use the established
cache freshness boundary. Live hashes include derived semantics, not just source
bytes. Existing CLI output and authored data remain unchanged.

The bounded request filter additionally accepts conjunctive text and kind arrays,
with completion choices returned alongside views. Existing requests retain their
defaults; CLI `search`, complete snapshots, stored fields and detail-only loading
remain unchanged. The [bounded protocol](../user-docs/frontend.md#filter-selection-and-completion-choices)
owns the additive fields and candidate-read boundary. An optional independently
parsed `choice_filter` and `choices` mode add contextual completion without
changing old requests that omit it, full snapshots, CLI search, or stored data.

## Dependency graph extension

The contract includes an additive schema-3 extension for the
[dependency view](dependency-graph-view.md#accepted-frontend-compatibility-boundary).
Existing flat-view requests retain their behavior, and graph layout data is
opt-in. Graph view requires the updated CLI and Emacs frontend, with no graph
fallback for older CLIs. This preserves existing flat clients during rollout;
it requires no issue-file migration. The [bounded protocol](../user-docs/frontend.md#dependency-layout)
owns graph fields and independent topology hashes. Strict status selection never
adds hidden nodes or replacement edges; readiness remains ledger-wide.
The junction revision adds sparse `drawing` metadata while preserving the
existing semantic row fields. Updated graph clients require that metadata;
the same updated-CLI boundary applies. Shared routes preserve exact direct edges.
The Emacs browser accepts ordinary filtering in both hierarchical and flat modes;
only hierarchical mode requests a graph.
Graph rows add nonzero direct-connection counts for neighbors excluded by
additional filters after strict status selection. The updated-CLI boundary also
applies to filtered graph requests; existing requests without a graph retain their behavior.

## Emacs presentation

The [Emacs contract](../frontends/emacs/README.md) owns interaction,
presentation, window layout, view/history state, and notification fallback.
Issue 0085 changes interactive entry to explicit project/directory contexts,
with user-chosen parent use or initialization. It retains the CLI initialization
contract and canonical ledger sessions; browsing view reuse follows selected
locations rather than sharing state merely because their ledgers match.
Frontend changes do not implicitly alter Rust wire data or storage. The abandoned
side-by-side prototype is historical evidence, not a compatibility requirement.

## Invariant-bearing parsing boundaries

The [type standard](coding-standards.md#types-and-boundaries) governs parsing
weak input into values that retain proof. Existing repairs preserve observable
CLI/storage behavior. Parsed issues expose immutable accessors; mutation outputs
cannot be fabricated through public fields. The
[module boundary](code-organization.md#public-rust-construction-boundary) owns
the trusted construction and publication contract.

## Distribution and validation

The optional [dogfooding procedure](dogfooding.md) owns exact-tree
gates, installed-command verification and rollback for that maintainer workflow. Editing source never
changes the selected executable; frontend source-loading is a separate boundary.

Tests use fresh temporary projects or disposable copies, never incomplete
mutation code against live ledgers. Select focused gates using
[coding standards](coding-standards.md#validation-scope); retain reusable
regressions in the suite and report concise verification in the contribution.
The public suite is self-contained; private Bash history is not a routine gate.

## Complete-draft editor

The additive [draft protocol](../user-docs/editor.md) supports complete creation,
editing and nonpublishing validation, with expected-version conflict rejection.
Existing human commands, browsing schemas and record grammar are unchanged.
Preflight cannot repair authored records; successful saves retain existing
per-file publication/recovery semantics and lifecycle constraints.


## Add and Close cutover

Issue actions use Add / Edit / Close and lifecycle values Open / Closed. The CLI
uses `add` and `close`; old action commands and old `resolved` status input are
rejected. Snapshot/frontend schema 3, editor schema 2 and dependency-tree schema 2
carry the status change. Cache schema 4 rebuilds the disposable projection.
The explicit editor close intent preflights draft edits and existing closure rules
under one lock; ordinary saves do not close. The existing per-file publication,
terminal lifecycle, evidence/outcome, ID and relation guarantees remain unchanged.
Historical status migration requires explicit backups and quiesced old consumers;
it is not an automatic side effect of normal commands.
