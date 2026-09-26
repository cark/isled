# Accepted decisions

This page records current rationale and consequential tradeoffs. Current behavior
belongs in the [user contracts](../user-docs/README.md) and
[Emacs guide](../frontends/emacs/README.md); implementation and tests establish
compliance. Historical experiments and deployment records are not prerequisites
for understanding or contributing to this project.

## Design discipline

Use [cohesive, simple, invariant-bearing designs](coding-standards.md).
Abstractions must answer a present need; future options can retain a clean seam
without acquiring a framework. Documentation follows responsibility and retrieval
cost rather than a numeric page-size target. The product remains a local,
single-user ledger; no service, network API or backend framework is selected.

## Authority, persistence, and future storage

Markdown is authoritative and directly inspectable. Ordered Markdown sections
make human reading and deterministic parsing compatible; the
[record grammar](../user-docs/record-format.md) is the single supported format.
Require UTF-8 for names and records while preserving opaque parent paths through
lossless wire encodings. Validate only what an operation needs so unrelated
malformed prose cannot block targeted work; retain raw-byte recovery diagnostics.

SQLite supplies a rebuildable derived cache, not another authoritative store.
Shared Rust-side caching improves repeated CLI calls as well as frontend use.
Keep domain operations independent of filesystem details through pure parsing,
mutation plans and narrow I/O boundaries. An authoritative database, dual parser,
repository trait or migration framework needs a concrete future requirement.

Retain bytes, parsed issues and failures for one command so reconciliation and
output share work. Corrections must keep retained state coherent without rereading
their own output. Reuse prepared statements through encapsulated connection APIs;
parameter binding and transaction/lock ordering remain explicit. Stable content
fingerprints avoid rewriting unchanged projections, accepting negligible accidental
collision risk and rebuilding an affected issue's projection rather than tracking
field-level changes. [Cache design](cache-design.md) owns those boundaries.

A bounded reader pipeline moves ownership to one consumer instead of sharing a
SQLite connection or parsed cache between workers. Avoid tiny-workload alternate
paths and recycling schemes without evidence. The one-command CLI can let process
exit reclaim retained memory; library operations keep normal cleanup, including
lock/transaction release in both cases. Measure end-to-end costs before claiming
speedups from allocation or cleanup changes alone.

External-edit freshness is best effort. Own mutations update affected cache rows;
targeted reads reconcile the requested issue and direct neighbors. Directory
mtime is a cheap membership hint, not proof that content is unchanged; compare
identities rather than counts. Explicit targeted/full refresh and the integrity
checker cover gaps. No resident Rust watcher or stale-cache overwrite of Markdown
is selected. See the [cache contract](../user-docs/cache.md).

## Batch issue inspection

Multi-ID `show` supports surveying issues. Readable combined output takes precedence
over byte-exact concatenation; titles supply separation without decorative framing
or a new output format. Bad records should not prevent useful inspection of other
requested records. Single-ID `show` remains the opaque valid-UTF-8 recovery path.
The [user contract](../user-docs/README.md#inspecting-several-issues) owns ordering,
repeats, framing, diagnostics and exit behavior. This does not justify a hidden
whole-ledger scan or an unmeasured performance claim.

## Brief lock contention

CLI mutations and asynchronous refresh can overlap. A 500 ms bounded acquisition
wait preserves the simple exclusive lock while absorbing brief contention.
Retry acquiring the lock only, never an operation that may have changed data.
Shared locks and upgrade coordination are unnecessary for the accepted workload.

## Generated relation warnings

Rust owns structured warnings and Emacs presents actionable findings. Inspection
may repair a copied title because the target's title is authoritative; other
repairs require a deliberate choice. Reuse the held lock and the inspected
neighborhood without recursive repair or hidden graph-wide checking.

Unmatched relations warn on both endpoints and remain conservatively blocking
when both issues are open. Complete or remove the relation explicitly; missing
targets allow removal. Unreadable records expose the actual error and file/trash
actions, without silently deleting relationships. Preserve identity and best-effort
screen position after controls disappear. [Synthetic recovery fixtures](../frontends/emacs/test/fixtures/relation-warnings/README.md)
make these paths reproducible without real ledger mutations.

Retain last-known persistent findings in the disposable cache, including unreadable
records and inconsistent relations; exclude transient lock/operational failures.
Only rechecking a condition clears it, with direct neighbors rechecked when needed.
The Emacs indicator remains visible through filtering. Warning jumps reuse normal
history, coalesce repeated locations and restore the previous view with `M-,`.
Absence of known warnings does not prove a complete integrity audit.

## Mutation and interface boundaries

Pure plans separate meaning from locked publication. Only filesystem code allocates
IDs, supplies path bytes, stages replacements and publishes. Per-file atomic
replacement, deterministic ordering, bounded locking and an explicit integrity
checker fit this low-contention tool. Interrupted multi-file writes remain possible
and diagnosable; there is no transaction journal promising all-or-nothing crash
recovery across records. Preserve validation, freshness and publication ordering.

Mirrored dependencies and copied titles let either endpoint explain direct
relations without a whole-ledger read. The reason belongs to the outgoing edge.
Preserve relations after closure because they carry durable rationale. Closure is
terminal: invalidated or new work receives a new issue rather than reopening old
history. Evidence and Outcome are distinct from authorization to close; consuming
projects define that authority. Allow deliberate corrections to closed prose with
a warning for the explicitly changed record, retaining the lifecycle.

Statement input supports complete stdin authoring and literal replacement without
requiring ad hoc file extraction or a patch language. Creation validates before
allocating an ID; reject reserved section headings before publication. Empty
replacement means deletion, with unique-match selection unless explicitly widened.
This remains Statement-specific rather than a generalized editing framework.

Titles are semantic content; filenames and creation-time slugs remain stable
through renames. Ergonomic CLI ID spellings normalize at the boundary without
weakening canonical stored IDs. Use mature crates for generic grammar and Unicode
semantics; keep product-specific rules local and authored bytes preserved.
Rust library source compatibility is not a public API promise; CLI, storage and
wire compatibility remain governed by the [contract](parity-contract.md).

Metadata-only selection belongs in composable `list`, text matching in `search`,
and frontend data in dedicated versioned wire commands. Prefer clear diagnostics
and help over aliases. `add` is the sole creation command; mistaken `create` forms
point to it before project discovery. Dependency inspection traverses only the
requested direction, with historical leaves retained without expanding irrelevant
branches. Compact prose references navigate but do not create dependency edges.

## Issue conclusion and lifecycle vocabulary

Outcome explains what was decided or done and why, including rejection or no
change. Statement owns the concern and Evidence owns observations. The familiar
word Outcome replaced the former administrative label with a clean interface
boundary; no old-name aliases or permanent dual record grammar remain.

Add / Edit / Close and Open / Closed describe actions and state without implying
that every closed concern was solved. Saving an Outcome never implicitly closes
an issue. Current wire/storage versions and legacy-input rejection are specified
in the [compatibility contract](parity-contract.md), not inferred from historical
migration tools.

## Frontend architecture and presentation

Rust owns ledger interpretation, references, readiness, filtering and graph layout.
Typed versioned payloads keep frontends from duplicating Markdown/dependency
parsing. A complete heading-text index plus bounded body loading keeps native
navigation, search, wrapping and scrolling useful on 5,000 retained issues.
Only nearby expanded bodies need transfer and presentation. Hash complete returned
meaning, including derived diagnostics, and reject obsolete asynchronous replies.

Recompute filtered membership before detail demand; the old list cannot define a
new result. Union demand across every displaying window, deduplicate requested IDs,
reuse shared detail data and retain applied body properties off-screen. Repeated
Markdown work and reflow would harm return to cached content. Hidden views defer
rendering and request no details; visible demand and freshness drive work rather
than an eager whole-ledger fetch or resident server.

Compare compiled frontend costs under representative/default GC settings. Sparse
font specifications retain semantic faces, weight contrast and frame-specific font
selection without captured font objects. Heading improvements do not eliminate
expanded-body allocation. Discarded body-buffer reuse reduced allocations without
a useful latency gain. Keep performance claims specific to the measured path.
Do not globally alter the user's GC policy; large read-only rebuilds may locally
raise the threshold and restore it afterward as documented in the frontend guide.

Semantic faces inherit ordinary Emacs/Markdown defaults. The body face supplies
only an unspecified background fallback so explicit face and theme choices win.
Padding and hidden duplicate titles alter presentation properties, not authored
text or reference coordinates. Retain the hidden boundary newline to avoid moving
the next heading when folding. Keymaps and `use-package` own customization; initialize
defaults once and preserve user changes across reloads. A narrow retirement of old
package defaults is separate from installing current bindings.

Each view owns filtering and folding; ledger data, requests and notification watches
are shared. Window/view pairs own navigation history and semantic positions.
Duplicating a view copies its state/history and then evolves independently; normal
window splitting still shows one shared view. Preserve other windows during async
navigation and release shared resources after the last view/draft subscriber leaves.
Replies cannot recreate dead sessions. Hidden views remain available for quick
return, with accumulated rendering changes coalesced.

Expanded sections get a best-effort fit without hiding point. Delayed body arrival
respects subsequent movement and other windows. Folding can restore a remembered
pre-fit viewport only without intervening movement; refresh, filter change and
resize invalidate that intention. Ordinary search covers headings and materialized
bodies, including folded bodies, without fetching every issue. Standard search-reveal
hooks support completion previews; temporary reveal changes visibility, while final
acceptance performs normal expansion and bounded revalidation. No Consult/Vertico
runtime dependency is required.

## Bounded chunk prefetching

Chunk ordered issue headings independently of body height. Each displaying window
requests the visible screen and two screens on either side, rounded to chunks;
union windows and request only expanded bodies needing detail. Explicit opening
adds immediate demand. Hash/revision checks establish freshness, not mere presence
in a cache. Coalesce around the latest destination and keep Rust asynchronous even
if a user outruns prefetching; no queued movement or synchronous wait guarantees
instant readiness.

Retain content by stable ID/hash while recomputing membership after filtering or
updates. Reject obsolete membership and preserve the destination when possible.
Batch missing detail requests through the shared queue, then present incrementally
with visible work first; do not eagerly format all replies in one callback.
The [frontend guide](../frontends/emacs/CONTRIBUTING.md#bounded-loading) owns current bounds
and behavior. The chosen lookahead is a responsiveness policy, not a hard guarantee
for arbitrary issue body sizes or machines.

## Filter completion and direct selection

Status, kind and tag terms combine with literal text using AND; Rust owns matching.
Use ordinary completion APIs independent of a particular framework, with contextual
suggestions preserving typed values and deliberate no-match selections. A compact
interface need not acquire a search cache or bespoke parser state. TAB uses standard
completion so editing an earlier token preserves trailing terms. Explicit picks and
preview/cancellation preserve view/history semantics.

Direct issue selection covers the whole ledger, including closed and filtered-out
issues, then uses normal reveal and shared history. Filter highlights identify the
matching text without becoming stored issue content. Conventional keymaps and
named commands remain the customization surface.

## Issue-file opening direction

Opening a well-formed local canonical issue file can reveal its issue in the ledger
view, including filtered-out or closed records. Rust validates the filename/identity
and canonical ledger before redirection; do not trust text resemblance alone.
Preserve ordinary file-opening fallback for malformed files, unsupported locations
or failed lookup. Remote/TRAMP and non-regular files retain normal file behavior.

Reuse an existing view when appropriate and preserve browsing context in history.
Map source-line destinations to the canonical body when possible, without inventing
new reference semantics. The explicit Open Markdown source action bypasses routing
so direct record inspection/editing remains available. Install lightweight routing
without eagerly loading the browser or overwriting personal key bindings.

## Project ledger entry commands

Project commands use ordinary Emacs project selection and canonical local roots;
explicit directory opening remains available. Only create a missing ledger through
a deliberate initialization action. Default invocation reuses the most recently
used view; a prefix creates an independent view, and explicit duplication preserves
its source state. Respect ordinary window placement and existing bindings.

## Structured issue creation and editing

Use a separate structured draft with title, kind, tags, Statement, Evidence, Outcome
and explicit dependency directions. Keep labels protected but navigation/copying
unrestricted, with theme-friendly field styling. Standard save/cancel keys and window
placement reduce custom machinery. One draft per existing issue preserves unsaved
work; new drafts have no allocated ID until successful save.

One Rust save operation checks the expected version, fields and graph under the
ledger lock before publishing. Validation/stale-save rejection publishes nothing;
I/O failure during multi-file publication may be partial and must be distinguished
from rejection. Preserve drafts and reconcile actual saved state before retrying.
Use Compare, Reload or explicit confirmed Overwrite rather than automatic merge;
recheck the confirmed version again before replacement. Neighbor updates must not
silently discard unrelated edits.

Idle validation creates no records and discards replies for old draft generations.
Errors remain selectable beside fields without moving point unexpectedly. Completion
uses existing vocabulary while permitting new valid values; prose references never
silently create relationships. Watches can signal Changed on disk without reloading
a draft. Closing is an explicit editor intent that validates edits and closure
together; ordinary saves remain edits even when Outcome is filled in.

## Dependency issue view

Use aligned unique rows and a graph gutter rather than a tree or deep indentation:
shared prerequisites form a DAG. Hierarchy is enabled by default but can be toggled
without changing filters or browsing state. Strict status selection comes first;
additional filters project the graph while retaining circles for connected issues
and dots for independence within the status selection. Avoid hidden-edge prose
notes, ambiguous crossings and excessive rightward drift. Rust computes complete
layout before pagination; Emacs paints bounded visible ranges. The
[graph design](dependency-graph-view.md) owns ordering, junction and caching rationale,
including accepted wide-graph limits and the decision not to persist layouts.

## Nix development inputs

Filter before flake evaluation: filtering a package derivation alone is too late
to prevent the initial source copy. Shell snapshots contain tools and pins only;
package snapshots also contain current Rust inputs. This avoids source edits
creating new shell/cache identities while preserving actual environment refresh.
Use the [documented wrappers](../scripts/README.md#source-boundary); Nix is optional.

## Public contributor boundary

The source tree and engineering requirements are self-contained. A normal Git
checkout supports building and checking the CLI and frontend. Optional jj, Nix,
Linux graphical and local-release tools retain useful maintainer workflows without
requiring every contributor to adopt them. Selected standards belong to the project
while personal global policies remain independently maintained in their own scope.
Raw operational history and private ledgers stay outside tracked source; concrete
boundary checks supplement human review of public documentation and attribution.

## Future directions

Optional ledger tracking remains an investigation. The motivation is a personal
ledger becoming useful to another contributor; distributed concurrent allocation,
conflict resolution and synchronization require a concrete multi-user use case.
The current local ignored-ledger default is unchanged.

Broader public distribution should support Linux, macOS and Windows with native
CLI/frontend checks before claiming support. Versions, architectures and release
channels are not yet a completed support matrix. Nix stays optional. An Emacs-first
installer may explicitly offer a compatible CLI download when needed, respecting
an explicitly configured executable. Manual binaries and source builds remain
alternatives; no automatic installer or silent replacement is implemented.
