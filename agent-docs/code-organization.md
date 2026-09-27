# Code organization

This page owns the implemented responsibility map and boundary constraints.
Follow the [refactoring procedure](refactoring.md) when changing those boundaries.

The executable implements the read-only, safe-mutation, checking, and complete
interface-audit slices. Remaining entries are a provisional concept map, not
permission to create every module before it earns content:

```text
src/
├── main.rs          # startup, streams, exits, and top-level dispatch
├── commands.rs      # binary-private module declarations
├── commands/        # focused handlers and shared seams; see Command handlers below
├── cli.rs           # parsing and invocation-error adaptation
├── cli/             # args.rs grammar; help.rs stable help and inventory
├── issue.rs         # parsed Issue aggregate and public value-type exports
├── issue/           # identity, name, status, created_date, tag, and relation values
├── record.rs        # strict structured Markdown codec and canonical renderer
├── record/state.rs  # retained source, fingerprint, and lazy header/document parse results
├── ledger.rs        # implemented aggregate identity and allocation rules
├── filesystem.rs    # public filesystem exports
├── filesystem/
│   ├── root.rs      # root discovery, validated paths, and loaded-cache cleanup policy
│   ├── read.rs      # scoped source reads and raw audit snapshots
│   ├── records.rs   # purpose-specific stored inputs and construction checks
│   ├── lock.rs      # lock lifetime, allocation recheck, and publication
│   ├── loaded.rs    # command-lifetime issue reads and remembered failures
│   ├── contents.rs  # checked raw file contents using an existing size hint
│   ├── prefetch.rs  # bounded reader batches consumed by the cache thread
│   ├── inventory.rs # retained directory entries, invalidated after creation
│   ├── initialize.rs # initialize_ledger and its ignore entry
│   ├── counter.rs   # high-water persistence
│   ├── paths.rs     # platform filename encoding and regular-file checks
│   ├── write.rs     # exclusive temporary-file writes and permissions
│   ├── error.rs     # filesystem failures and lossless diagnostic names
│   └── tests.rs     # filesystem adapter integration tests
├── cache.rs         # lock-scoped SQLite connection lifecycle
├── cache/
│   ├── database.rs  # cached SQL interface and private connection/schema lifecycle
│   ├── invalidation.rs # pending filenames and post-publication synchronization
│   ├── storage.rs   # full and targeted reconciliation
│   ├── source.rs    # one Markdown source projected into cache rows and timestamps
│   ├── frontend.rs  # issue identity, readability and diagnostic metadata
│   ├── filter_choices.rs # validated contextual filter completion choices
│   ├── filtering.rs # frontend summary and candidate-text selection
│   ├── inspection.rs # shared deduplicated record neighborhoods
│   ├── show.rs      # validated batch inspection and selected relation warnings
│   ├── query.rs     # validated metadata selection and summaries
│   ├── dependency.rs # graph traversal and mutation neighborhoods
│   ├── layout.rs     # experimental complete status-selected graph from cached metadata
│   ├── repair.rs    # copied-title publication under the existing lock
│   ├── warnings.rs  # incomplete-query and retained-relation reporting
│   ├── retained_warnings.rs # checked-condition persistence and known warning targets
│   ├── error.rs     # cache failures and corruption classification
│   └── schema.sql   # one current disposable schema, no migrations
├── query.rs         # public query entry points via declarations and re-exports
├── query/
│   ├── dependency.rs # typed targeted graph plus human and JSON tree rendering
│   ├── search.rs    # snippets, Unicode matching, excerpts, and search tests
│   ├── list.rs      # metadata listing and shared summary rows
│   ├── filters.rs   # query criteria and matching, including active waits
│   ├── lookup.rs    # raw issue and path lookup, unique identities, OutputPaths
│   ├── records.rs   # borrowed record/header views and their selection
│   ├── wait.rs      # direct wait inspection and relation consistency
│   └── error.rs     # QueryError and its formatting/conversions
├── reference.rs     # pure compact-reference recognition and typed coordinates
├── diagnostic.rs    # pure local relation warnings shared by cache and snapshot
├── frontend.rs      # conditional filtered views and semantic detail payloads
├── frontend/        # request.rs validated input; wire.rs encoding and live hashes
│   └── graph.rs     # opt-in topology token and compact whole-selected-graph plan
├── snapshot.rs      # pure typed application snapshot for local frontends
├── snapshot/
│   └── json.rs      # versioned, lossless JSON serialization boundary
├── mutation.rs      # pure mutation exports and opaque publication plans
├── mutation/
│   ├── plan.rs      # opaque replacements and deterministic plan assembly
│   ├── add.rs       # creation and slug derivation
│   ├── tags.rs      # tag and priority changes
│   ├── wait.rs      # mirrored wait edits and graph validation
│   ├── close.rs     # terminal lifecycle transition
│   ├── title.rs     # title input and direct-neighbor updates
│   ├── completion.rs # validated completion text and shared section framing
│   ├── evidence.rs  # evidence entries and pending-state check
│   ├── outcome.rs # current conclusion and pending-state check
│   ├── selection.rs # required record/header selection and parsing
│   ├── error.rs     # mutation failures and their stable messages
│   ├── repair.rs    # explicit relation completion or removal
│   ├── copied_titles.rs # automatic, byte-exact copied-title correction
│   └── statement.rs # typed stdin framing, literal selection, byte-preserving edits
├── check.rs         # implemented pure whole-ledger integrity audit and findings
├── wait_graph.rs    # implemented reusable iterative reachability and components
├── graph_layout.rs  # canonical selected graph and shared layout entry point
├── graph_layout/    # frontend layout engine and retained diagnostic experiment
│   ├── ordering.rs  # ID-placed components, following narrower newly ready branches
│   ├── plan.rs      # sparse destination lanes, stored-plan validation and indexing
│   ├── drawing.rs   # exact shared destination groups and physical drawing tracks
│   ├── range.rs     # bounded rows with entering/leaving continuation state
│   ├── text.rs      # width-bounded diagnostic glyph rendering
│   ├── store.rs     # experimental preview cache; not used by frontend requests
│   ├── preview.rs   # separate graph-layout Cargo example and phase metrics
│   └── fixtures.rs  # deterministic preview/measurement graph shapes
└── wire.rs          # shared lossless JSON encoding for filesystem byte strings

tests/
├── cache.rs                 # cache integration test target and module declarations
├── cache/                   # freshness, relations, recovery, and shared disposable fixture
├── compatibility.rs         # historical differential cases and harness tests
├── structured_records.rs # mirrored relation, title, closure, and check behavior
├── query_contract.rs # direct pure-query output, selection, and failure contracts
├── support/graph_benchmark.rs # process measurements using large_ledger.rs's fixture
└── fixtures/                # exact-revision acceptance adaptations

scripts/
├── dogfood-release.sh # validate, promote, inspect, and roll back local releases
├── test-dogfood-release.sh # isolated release-pointer and rollback checks
├── emacs-preview.py # isolated interactive candidate preview lifecycle
├── test-emacs-preview.py # focused preview manager unit checks
├── private-graphical-emacs.py # owned Xvfb runner for graphical checks
├── test-private-graphical-emacs.py # graphical runner lifecycle checks
├── test-emacs-preview-graphical.el # end-to-end managed preview check

frontends/emacs/
├── isled.el          # lightweight setup, autoloads, and one-time default keymaps
├── isled-browser.el  # major mode, interactive controller, help, and view state
├── isled-snapshot.el # shared typed data and complete-snapshot codec
├── isled-frontend.el # bounded wire response validation
├── isled-process.el  # asynchronous subprocess lifetime and capture
├── isled-data.el     # retained body hashes and target metadata
├── isled-sequence.el # indexed ordered projection lists
├── isled-navigation.el # window/view memories and asynchronous origins
├── isled-buffers.el  # independent view creation, duplication and reuse
├── isled-session.el  # shared ledger cache, view lifetime, watch and process queue
├── isled-loading.el  # request sequencing, fences, and per-buffer coalescing
├── isled-windows.el  # displaying-window observation and nearby range unions
├── isled-viewport.el # bounded activation of retained body presentation
├── isled-view.el     # pure filtering and selection
├── isled-rows.el     # row identity indexes and integer text boundaries
├── isled-fold.el     # logical folding and temporary search reveal
├── isled-presentation.el # semantic text and diagnostic presentation
├── isled-sections.el # rendering and visible navigation targets
├── isled-header.el   # pure directory labels and responsive header
├── isled-auto-refresh.el # notification watches, timers, polling fallback
├── Makefile         # check and package entry points (metadata comes from isled.el)
├── README.md                  # illustrated introduction, installation, everyday use
├── user-guide.md              # full interaction and customization reference
├── CONTRIBUTING.md            # validation, package building, code map, recording
├── demo/record.el             # isolated fictional-ledger recording
├── images/                    # README demonstration GIFs
└── test/                      # focused ERT tests, wire fixture, resettable recovery demo

skills/
└── isled/
    ├── SKILL.md # concise canonical contract and conditional router
    └── references/
        ├── mutations.md # issue authoring, lifecycle, and relation guidance
        └── recovery.md # failure and manual-repair guidance
```

Keep command parsing separate from domain operations so tests can exercise
typed behavior without launching a process. Filesystem code supplies
purpose-specific stored identities, headers, or full records to pure codecs and
domain operations; it does not own parsing or ledger rules. Commands request
the narrowest input their semantics require, while whole-record scans remain
explicit. Keep filesystem mutation behind that same narrow outer boundary.
Transport structs may remain weak input, but query and mutation functions take
types carrying the invariants they rely on rather than validated primitives.
Mutation semantics return replacement plans and never open paths themselves.
Replacements retain their updated parsed document alongside rendered or selectively
rewritten bytes; only trusted mutation constructors create that pair.
Every Statement mutation converges on the validated, byte-preserving writer in
`mutation/statement.rs`; input syntax must not create a separate publication path.
Set and append share CLI input arguments and action planning; stdin uses the
same framing and grammar as creation. Their validated input types retain the
argument-versus-stdin boundary without duplicating record validation.
A title replacement changes the semantic heading and copied titles in direct
neighbors; creation-time filenames remain stable.
A possible future SQLite backend informs this separation but does not justify a
backend abstraction before it is selected. Split or combine this map only when
implemented concepts and dependencies justify the change; update this page in
the same logical change.

The selected SQLite cache is an I/O adapter, not an authoritative backend.
Mutation plans remain pure. StoreLock records pending cache invalidation before
publication and synchronizes afterward under the same lock. Its loaded-state
owner retains records and failures across cache connections; the root's explicit
cleanup policy controls their reclamation without changing lock cleanup. The CLI
selects process-exit reclamation centrally; ordinary library roots drop normally.
Successful renames
install the corresponding parsed replacement before synchronization. Cache queries use
bound parameters and parse row values into existing domain types; dependency
rendering remains in the pure query module. Full body operations remain source
reads. See the [cache contract](../user-docs/cache.md) and
[design rationale](cache-design.md).
Read-time copied-title correction uses pure plans, publishes under that already
held lock without synchronization callbacks, then updates the same cache
connection. Snapshot read failures are transport data, not fabricated records. SnapshotSource
borrows retained StoredRecords or an identity plus read failure; construction
reuses parsed fields and does not reload contents. Raw show shares the lock
owner through reconciliation and final inspection.

Historical compatibility cases own process execution and temporary fixtures.
The optional harness owns sandbox reset, exact Bash materialization,
observation, and comparison; neither belongs in the product dependency graph
or routine acceptance path.

## Public Rust construction boundary

`IssueRecord::parse` supplies parsed `Issue` values with read-only public
accessors. Construction and modification of their fields stay inside the
trusted library crate. `Replacement` and `MutationPlan` fields are private to
the mutation module; callers inspect borrowed slices and obtain outputs from
typed mutation functions. An empty default plan is a valid no-op. Raw audit and
snapshot transport inputs remain intentionally weak and are parsed by their
consumers; standalone relation values cannot be inserted into a parsed issue
through the public API.

The binary composes these pure operations directly with `StoreLock`, without a
new application facade. This does not require one file: focused command-handler
modules should own their workflows, leaving startup/streams/exits and dispatch
small. The [command handlers](#command-handlers) separate these responsibilities
according to the [per-file cohesion standard](coding-standards.md#conceptual-cohesion).
Creation accepts a typed replacement, checks its ID
against current allocation under the lock, and derives the next high-water
value itself. Callers cannot supply counter bytes or a replacement path/body.
Allocation is rechecked at publication rather than treating an earlier ID
lookup as a reservation. This is a construction boundary, not a transaction
or proof that a plan describes the latest ledger: callers still read, plan, and
publish within the same lock scope.

External integration tests cover typed creation and high-water preservation;
compile-fail doctests guard against fabricated issues, filenames, bytes, and
plans. An empty evidence batch is a no-op; mixing the pending placeholder with
other entries is rejected before producing a replacement.
Older weak creation/wait/closure/search entry points are removed;
primitive `Option` parsing helpers remain because they still establish the same
invariants as structured-error parsing.

<a id="planned-command-handler-extraction"></a>

## Complete-draft editing

`editor.rs` owns locked draft orchestration, `editor/request.rs` decodes transport,
and `editor/store.rs` selects records/cache inputs. `mutation/editor.rs` and its
`draft`/`relations` modules own validated fields, freshness representation and pure
replacement planning and closure of the planned draft through the shared close
operation, borrowing retained `StoredRecord` documents and cloning
only editable copies. `commands/editor.rs` owns CLI streams. Preflight opens the
cache with copied-title publication disabled; ordinary cache callers retain it.

The Emacs editor separates saved/draft state and decoding (`isled-editor-model`),
which returns decoded records once at the response boundary,
form rendering and diagnostics (`isled-editor-form`), metadata completion and
bounded local preview text (`isled-editor-completion`), non-disruptive header and
saved-version feedback (`isled-editor-feedback`), and asynchronous draft lifecycle
(`isled-editor`). Shared sessions retain the directory watch for view and draft
subscribers through one session-construction path; editor callbacks compare
through Rust without reloading draft fields. Browser entry points delegate rather
than mutate.

## Command handlers

The command workflows extracted from `main.rs` live in the implemented tree
above. Keep handlers private to the binary crate under
`src/commands/`, with `run` entry points qualified by command module;
`commands.rs` declares modules, and `main.rs` retains startup,
top-level dispatch, ordinary output and exit selection. Batch show owns its
interleaved record/diagnostic stream writes after releasing the ledger lock. Existing library
modules continue to own parsing, pure operations, persistence, and rendering.
Do not introduce a command trait, application facade, or backend abstraction.

| File under `src/commands/` | Workflow and supporting code |
| --- | --- |
| `init.rs`, `cache_refresh.rs` | Their respective top-level command arms |
| `add.rs` | Creation and creation-specific tag validation |
| `list.rs`, `search.rs` | Their respective arms; search also owns `output_paths` |
| `show.rs`, `show/batch.rs` | Raw single inspection and ordered batch records with attributed diagnostics |
| `path.rs` | Canonical-path lookup |
| `frontend.rs` | One stdin request, refresh scope, shared cache recovery, and lock release |
| `snapshot.rs`, `check.rs` | Snapshot assembly and ledger integrity checking respectively |
| `wait.rs`, `wait/` | Namespace dispatch; show/tree/add/remove/repair each owns its complete workflow |
| `title.rs` | Title replacement and participant loading coordination |
| `statement.rs` | Set/append/replace workflows and their argument adaptation |
| `evidence.rs`, `outcome.rs` | Their respective content-edit workflows |
| `tag.rs`, `priority.rs`, `close.rs` | Their respective workflows; tag owns `parse_mutation_tags` |
| `filters.rs` | `parse_filters` and its supporting `StatusDefault` |
| `cached_read.rs` | `with_cached_query`: lock-scoped query execution, one corruption rebuild, warnings, finish |
| `selected_records.rs` | `read_selected_records`: deduplicated loading for title and wait mutations |
| `content_publication.rs` | `publish_content`: publication, finish, then closed-record warning |
| `statement_input.rs` | `read_statement_stdin`: shared creation/Statement terminal prompt and input |
| `issue_id.rs`, `tag_input.rs` | Existing CLI-specific ID and single-tag error adaptation |
| `error.rs` | `AppError`, display, and conversions; exit selection stays in `main.rs` |

Preserve lazy root discovery by passing the existing closure to handlers.
Do not resolve the project centrally before dispatch: `show` deliberately
discovers before ID validation, while many mutations validate input first.
Keep each workflow's reads, lock lifetime, cache refresh/drop, plan creation,
publication, warnings, and finish in their existing order. In particular, do
not put all writes through `publish_content`: its historical-record warning
belongs only to the content-edit callers that currently use it. Preserve the
different duplicate/conflicting-tag rules for creation and tag mutation.

Keep single-workflow helpers with their handler and expose shared helpers only
within the binary. These are concrete shared seams, not a reason for a generic
utility module. Recheck references after moving code.

Keep the dispatcher small and preserve handler ordering, stream, exit, and lock
behavior. Follow the [refactoring procedure](refactoring.md) for cohesion review,
focused coverage, validation, and promotion. Changing these boundaries does not
itself authorize bounded frontend loading, cache-semantic changes, or unrelated
library reorganization.

## Pure query boundaries

`query.rs` exposes the existing public names through re-exports. Its private
implementation modules group complete responsibilities: search retains its
snippet type, Unicode algorithms, excerpt selection, and tests; lookup retains
raw `show`, path projection, identity checks, and the supporting path map.
Metadata listing owns the summary row reused by search and direct wait output.
Filters own selection criteria and use the wait module's relation checks.
Borrowed record/header adapters stay together in `records.rs`. `RecordView`
borrows retained header metadata for stored records; raw codec inputs own their
parsed metadata. Its getters do not reparse or perform fallible access. Queries build a borrowed
identity index after eager
parsing; duplicates remain errors only when selected, preserving validation scope.
Internal sharing
is limited to the query module with `pub(super)`.

Keep these pure record queries distinct from SQLite queries in `cache/query.rs`.
The CLI uses the cache for metadata list/wait operations, so CLI tests alone
do not exercise every pure-query entry point. `tests/query_contract.rs` directly
covers record/header output, identity errors, raw-byte inspection, Unicode
search, and inconsistent relations. Preserve existing parsing and failure order:
raw lookup does not require structured Markdown, while filtering and wait
inspection validate their required views and relations. This separation does
not change cache freshness or repair behavior. Targeted dependency-tree
construction/rendering remains in `dependency.rs`. Each rendering indexes borrowed
edges once, preserving sorted sibling order and outgoing JSON orientation; cache
traversal loads each selected node summary once.

## Library responsibility boundaries

The value-type modules own parsing and immutable access for their respective
issue values. `Issue` remains the parsed aggregate. CLI grammar stays together
in `cli/args.rs`; stable help and missing-command inventory belong in
`cli/help.rs`. Neither owns command execution.

Closure uses `close_issue` on the selected records; it no longer exposes
unused header-scoping wrappers or a fictitious incoming-issue count.

Mutation modules own complete pure operations, including their typed input and
single-operation helpers. Shared selection and opaque plan assembly remain
inside `mutation`. Evidence and outcome retain distinct operations; their
small shared completion-text boundary owns input proof and section framing.
Title neighborhoods and wait-add graph discovery are owned by the cache; the
unused mutation header scans and full-ledger wait-add alternatives are removed.
Automatic copied-title planning validates and indexes titles eagerly, then rewrites
relations in input order through borrowed record traversal; the cache caller
does not clone the inspected records. `repair_copied_titles` allocates rewritten
record bytes only after finding a changed title, preserving untouched spans.
Plans preserve unrelated bytes; explicit
relation repair owns the choice to complete or remove a relation. Neither
publishes files.

`filesystem/root.rs` discovers and names a project; `read.rs` implements scoped
reads on that root. `lock.rs` owns acquisition, release, allocation rechecking,
and publication together. Cache reconciliation, source-to-row projection,
dependency queries, diagnostics, and copied-title synchronization have separate
homes under `cache/`. Preserve their ordering and the existing held-lock repair
path; these modules add no transaction, facade, or backend abstraction.

The record codec, reference recognizer, snapshot builder, integrity auditor,
ledger allocation rules, and iterative wait-graph algorithms remain cohesive
units with their supporting representations and tests. Locked consumers share
`StoredRecord` handles and their lazy parsed state; the
cache keeps only handles for its inspected warning/repair scope. Standalone raw
audit and codec inputs retain their single-pass parsing paths. Their size alone
is not
a reason to split their algorithms. Existing command and pure-query boundaries
remain in place. Public exports name the current operations; trusted construction scopes remain intact.

The frontend summary filtering operation in `cache/filtering.rs` narrows cached summaries
before reading candidate content through the existing held-lock reader. It adds
no persistent index. `cache/filter_choices.rs` assembles completion choices, retaining the legacy
ledger-wide request behavior and supporting independently scoped criteria.
Eager cached tag-before-kind validation precedes contextual summary/text selection;
status suggestions remove the status restriction and tags/kinds retain it.
Choice-only requests skip view construction and detail inspection.
`cache/frontend.rs` owns issue identity, readability and diagnostic metadata. The bounded
request parser validates text and kind criteria before project discovery.

## Frontend boundary

Rust's `frontend/graph.rs` filters the status-selected graph from cached
metadata, counts direct connections omitted by additional criteria, hashes topology
and counts independently of headings, and returns compact row/lane
routes only on explicit request. It shares the measured layout engine with the
diagnostic preview but does not use the experimental persistent layout store.
Emacs's graph model validates and indexes that immutable plan. The glyph module
turns one row into directional node, connector and continuation lines; the gutter
module owns bounded painting and fold-safe heading/body decoration. The indexed
row model reserves real connector lines between headings and foldable bodies;
painting only changes their display properties, preserving scroll positions. The graph
interaction module owns hierarchical/flat toggling and direction reversal; the
ordinary filter prompt and loading queue own selection in both presentations,
with no separate Find or saved alternate query/state.

The filter prompt uses the existing view filter slot for a full query string;
symbolic Open/Closed/All defaults remain supported. Query parsing/status rewriting,
shared completion context and live prompt lifetime have separate focused modules.
Three small adapters own inline suggestions, a recursive token picker, and
whole-query minibuffer suggestions; the prompt captures the selected interface
once per invocation. See the [frontend code map](../frontends/emacs/CONTRIBUTING.md#code-map). Rust receives parsed criteria retained through prompt acceptance and request queuing;
noninteractive loading parses its destination filter at the queue boundary. Normal loading
owns coalescing and generations; history and duplicated views retain the complete
query through the existing opaque view state.


The Emacs package follows the same direction as Rust: process and weak wire
values enter through the asynchronous process and bounded-response modules.
The complete-snapshot codec remains supported and supplies shared issue/reference
validation and types. Retained bodies, hashes, and target summaries belong to
`isled-data.el`. It retains a mutable combined projection until the next
full view, replacing/removing touched identities for detail replies. Indexed list
spines and their predecessor invariants belong to `isled-sequence.el`;
consumers read the ordered lists without mutating their cells. Saved navigation
states retain identities and offsets, not immutable snapshot versions. `isled-loading.el` owns one running request,
coalesced per-view pending work and generation fences. The ledger session owns
shared details, serialized transport, one incremental-formatting timer and a private notification
owner; view buffers retain independent indexed projections. `isled-windows.el` owns
display-change observation, conservative heading bounds, and the union of
two-screen loading margins rounded outward to chunks across windows. Chunk ranges are recalculated from the current row
vector; they neither own cached content nor evict it.
One shared pre-redisplay observer compares window signatures; it is removed when
the last participating buffer unregisters, preserving other redisplay functions.
The controller owns interaction, canonical buffer identity, and successful
view/history restoration; pure view functions and sections own list presentation. Indexed row positions
and the expanded-row index belong to `isled-rows.el`; sections keeps
index membership synchronized with logical folds. Retained heading values let row updates avoid rebuilding unchanged text. Standard search-reveal folding belongs to
`isled-fold.el`, with temporary visibility distinct from expansion.
`isled-viewport.el` activates newly needed cached body presentation over
actual text-screen ranges before redisplay, without data requests. Applied
properties remain cached, avoiding eviction-driven reflow. It also prepares one
extra nearby body per visible view at the session deadline, with window-local
travel direction used only for presentation priority. Visible preparation reaches
a layout fixed point before redisplay; background preparation stays incremental.
`isled-presentation.el` owns semantic faces, Markdown text properties
and typed diagnostics independently of section positions and folding.
`isled-auto-refresh.el` still owns notification watches and fallback,
now scheduling asynchronous refresh. The
[frontend guide](../frontends/emacs/CONTRIBUTING.md#bounded-loading) owns sequencing and
[automatic refresh](../frontends/emacs/CONTRIBUTING.md#automatic-refresh) owns watch
behavior. Markdown View supplies properties in an isolated temporary buffer;
Rust's typed coordinates supply compact references without semantic reparsing.
Each canonical ledger root owns a shared session and independently named view
buffers. Filters and folds belong to the view; navigation memories belong to
each window/view pair and delayed navigation retains its originating window.
Selected-location identity and lookup belong to the context module; explicit
project/directory selection and missing-ledger choices belong to entry. The
initialize module owns asynchronous user-authorized CLI initialization.
Creation/reuse belongs to the buffers module and navigation lifetime to the
navigation module. `isled-source.el` owns explicit raw Markdown visits,
existing file-buffer preservation and the dynamic file-routing bypass. The expansion module owns best-effort window fitting after
explicit opening and a bounded pending intent per invoking window. It reuses
normal delivery and the display observer; it creates no timer or data request.
Frontends display the typed semantic title from the
snapshot and never derive presentation text from the canonical filename or its
creation-time slug.

## Portable contributor tools

`repository_files.py` owns Git tracked-file/revision selection.
`check-coding-standards.py` reports size review signals; its shell wrapper only
adapts optional jj selection. `check-repository.py` checks the public/private
content and local-documentation boundary. `test-contributor-checks.py` exercises
those behaviors in ordinary disposable Git repositories.

`frontends/emacs/test/run-check.el` supplies isolated package/load paths and
invokes the existing static/ERT runner. `package-emacs.py` builds the source
archive with the root license. Neither requires jj or Nix. The optional
release/preview helpers retain their separate maintainer responsibilities.

`stage-release.py` orchestrates native build/test, complete-set assembly,
verification and explicit draft upload. `release_metadata.py` owns shared
identity, asset names and checksum records; `release_archive.py` owns CLI
archive writing and verified extraction; `release_platform.py` owns native
build flags and linkage/distribution inspection. `test-release-staging.py`
protects artifact integrity and exact candidate identity. The standalone
`frontends/emacs/test/package-install.el` checks the constructed package in a
temporary installation. [Release staging](../scripts/releasing.md) owns usage.
