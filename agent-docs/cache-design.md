# Rust cache design

The [living cache contract](../user-docs/cache.md) owns CLI behavior and recovery;
[the SQL schema](../src/cache/schema.sql) owns exact storage fields. This page
records architecture and limits. See [decisions](decisions.md#authority-persistence-and-future-storage)
for freshness tradeoffs and cheap change signals.

## Store and tables

Markdown remains authoritative. SQLite at `.issues/.cache/ledger.sqlite` is
disposable derived data; incompatible cache formats are rebuilt, not migrated.
Ledger discovery must exclude the cache directory.

Use `rusqlite` with bundled SQLite: synchronous SQL fits the CLI without an ORM
or async execution model, and bundling avoids a user-installed SQLite library.
Keep SQL and row decoding at the I/O boundary; no pool or repository framework.
Bundling adds build-time C compilation and responsibility for SQLite updates.

| Table | Fields and identity |
| --- | --- |
| `cache_state` | One row: optional last reconciled directory timestamp hint and filename diagnostics; format version uses SQLite `user_version` |
| `issues` | ID primary key; unique filename; semantic title, status, kind, created date; file size, optional modification and metadata-change timestamp hints; optional XXH3-64 content fingerprint |
| `issue_tags` | Unique `(issue_id, tag)` pair; index by tag |
| `relation_warnings` | Last-known structured findings keyed by affected issue, directed relation and code; message and reason requirement retained for display/actions |
| `dependencies` | Authored claims keyed by `(owner_issue_id, waiting_issue_id, blocking_issue_id)`; outgoing reason; indexes for both directions |

The state row tracks directory reconciliation, not a foreign-key relationship.
File metadata provides change hints, not proof of content equality; explicit
refresh reads the requested files even if those hints match.

Schema version 5 adds retained relation findings. They have no cascading foreign
key because source projection replaces issue rows during ordinary edits; warning
lifetime follows checked conditions instead. Scoped inspection replaces findings
only for checked endpoint pairs, retaining unverifiable findings and updating both
mirrored displays. Unchanged findings do not rewrite SQLite. Pending edits and
membership changes inspect one layer of old/new direct neighbors; newly found
neighbors do not recursively extend that layer. The [known-warning contract](../user-docs/cache.md#known-warnings)
owns user-visible freshness and scope.

## Prepared-statement execution boundary

All runtime data queries and writes use rusqlite's cached prepared statements
through `cache::database::Database`. This includes reads, inserts,
updates, deletes, and dynamically composed parameterized queries. Statement reuse
does not cache query results or change freshness and reconciliation semantics.

Keep one connection owned by the cache's held-lock operation, behind a small
type that exposes familiar preparation, execution, and row-query operations with
caching as their normal behavior. Ordinary callers must not receive the raw
connection or an uncached escape through accessors or `Deref`. Support borrowing
and result iteration without forcing intermediate collections. Use rusqlite's
bounded statement cache; changes to capacity need workload evidence, not an
unbounded cache or connection pool. No connection survives across CLI processes.

Schema creation/validation, connection PRAGMAs, and transaction control are the
explicit uncached exceptions. Keep them inside the connection lifecycle boundary
with purpose-specific operations, not an arbitrary uncached-SQL method available
to data-access callers. Preserve SQL parameter binding, transaction and error
ordering, and lock lifetime. Prepared-statement reuse avoids repeated SQL preparation while keeping the
execution interface explicit. `Database::prepare`, `execute`, and `query_row` now cover
all data access, including dynamic filters and recovery writes. `prepare` returns
a borrowed `CachedStatement` for direct result iteration. Only `Database` owns
the raw connection; transaction callers use `begin_immediate`, `commit`, and
`rollback`. Schema bootstrap (including its initial state row) stays internal.

## Shared command state

The command lock owns loaded issues for its held-lock lifetime. Each loaded
entry retains its source bytes and
parsed issue, or its missing/read/parse failure. Header and complete-document
validation remain separately lazy, sharing parsed components without widening
an operation's validation scope. Entries are keyed by filename so duplicate
issue IDs cannot overwrite each other. Read and parse each required
record once; reuse that state across reconciliation, correction, relation checks,
SQLite projection, and snapshot construction. Remember failures too, so repeated
references do not retry the same failing read or parse.

SQLite remains the derived metadata index. Metadata-only queries may stop there;
its rows are not complete parsed records. Reuse already obtained metadata where
needed, without promising that distinct SQL queries require only one statement
execution. Retaining bodies in command memory does not add them to SQLite.

File content reads reuse metadata from the regular-file safety check to size
their buffer. The length is an allocation hint, not a read limit: retain normal
short-read, Interrupted, and EOF handling when files grow or shrink.

Reconciliation pipelines its ordered pending file sequence through one scoped
reader worker into the consuming thread, which owns retained records, parsing,
and cached SQL. Transfer owned bytes, metadata, and failures in SmallVec batches
of up to 64 files, with a 256 KiB byte target and two queued batches. Whole files
can exceed the byte target. No bytes or parsed records are cloned across threads;
there is no shared cache mutex, separate SQL worker, container recycling, or
size-based alternate path. Targeted dependency discovery retains its existing
ordering and the shared underlying file reader.

On a consumer failure, cancel later batches but drain and retain in-flight reads
before joining the worker. This prevents deadlock and rereads during corruption
recovery. Preserve SQL/error ordering and join before releasing the ledger lock.
Reading ahead changes observation timing within the existing best-effort
external-edit contract; it does not provide an atomic filesystem snapshot.

Retain the directory inventory across reconciliation and snapshot identity
preparation. Identity, filename encoding, and file-type checks still run when
snapshot inputs are constructed. Successful creation invalidates the inventory
immediately after rename; allocation rechecking uses a fresh listing. Directory
handles drop normally, independently of the loaded-byte cleanup policy. A later
command observes external membership changes made after the retained listing.

Corrections must produce consistent source bytes and parsed state together at a
trusted mutation boundary. After successful publication, update the retained
entry and project SQLite rows from it, without rereading or reparsing our output.
Do not weaken validation to achieve this: construction must preserve the record
invariants and byte/parsed-state agreement. Failed publication must not present
an uncommitted correction as current; existing recovery guarantees still apply.

Parsing success is separate from relational validity. Reevaluate affected
relationships against the retained objects when related state changes, without
parsing Markdown again. Preserve duplicate detection, error ordering, validation
scope, and existing freshness semantics. This is shared command state, not a
cross-command cache: no eviction policy, TTL, background synchronization, or
connection pool is needed. A later command observes external repairs through the
normal freshness rules; a command never retries a retained failed content read
or parse. Verification covers bounded read/parse counts,
correction consistency, failure behavior, and representative memory/latency costs.

<a id="accepted-follow-up-cleanup-policy"></a>

### Cleanup policy

The explicit `CacheCleanup` enum has `Drop` and `LeaveToProcessExit` variants.
Ordinary `ProjectRoot` construction defaults to `Drop`. The one-command CLI
selects `LeaveToProcessExit` centrally when constructing its root, and the root
supplies that policy to each `StoreLock`. No trait or generic cleanup framework
is needed.

`StoreLock` always retains its existing filesystem-lock release behavior,
including error cleanup. Only the loaded-record memory follows the policy:
drop normally, or explicitly forget it so the OS reclaims it at process exit.
Retaining those bytes through JSON encoding is an accepted tradeoff. Persistent
callers, including a possible future Emacs streaming process, keep normal cleanup;
this decision does not authorize implementing that interface. Forgetting must
not bypass SQLite transaction cleanup, file publication, or lock removal.

Measure the actual benefit before claiming a speedup. Lock release and
retained-record cleanup are separate costs; a combined timing does not establish
the benefit of memory cleanup alone. Ownership tests verify both policies, normal/error lock release, and
default reclamation across repeated requests.

<a id="accepted-follow-up-unchanged-content"></a>

## Unchanged content

Use a fast, non-cryptographic 64-bit content hash to detect unchanged content. `xxhash-rust` supplies XXH3-64 over raw source bytes; the immutable
record retains its lazily computed fingerprint. The cache stores its full
bit pattern in `issues.content_hash`. Compare only with the same issue's previous
fingerprint and filename, after complete validation.
A matching fingerprint on a valid cached row skips rewriting
its semantic metadata, tags, and relations; a missing or different fingerprint
uses validated current state to rebuild that issue's projection. Accept rebuilding
associations after a body-only edit rather than adding field-by-field differences.

The design accepts accidental collision risk for this disposable cache. With
uniform hashes, one changed issue matching its previous contents has probability
2^-64; 5,000 such comparisons have approximately 2.71e-16 probability of any
false match. Cross-issue collisions do not affect this identity-keyed comparison.
This is an accepted probabilistic shortcut, not proof of byte equality or a
security mechanism. Use a specified stable algorithm; changing its interpretation
requires cache invalidation. Preserve all 64 bits in SQLite's signed integer.

The fingerprint skips derived-data writes, not required source reads, parsing,
or relation validation. Retain the shared command state and existing failure and
recovery semantics. File metadata hints may require updating even with identical
content. Store the fingerprint and matching projection atomically; corrections
use the bytes successfully published. Missing, unreadable, and invalid records
must not preserve stale valid projections through the shortcut.
Unreadable records have no reusable fingerprint; their error projection is rebuilt
when inspected. Cache-state diagnostics and timestamp updates also avoid writing
equal values. Data statements still use the prepared-statement boundary.

## Portability boundary

Keep the model sensible for Windows without implementing a port. Filenames are
exact relative components, not absolute paths; issue IDs remain logical keys.
Timestamp hints have explicit meanings and a defined epoch/unit, with absence
allowed when unavailable or not cheaply obtainable. Never substitute creation
time for Unix ctime. Represent present timestamps as signed seconds since the
Unix epoch plus fractional nanoseconds, normalizing at the I/O boundary without
inventing precision. Use `modified_at`, optional `metadata_changed_at`, and
`directory_modified_at` as semantic names; Windows ChangeTime and Unix ctime
are similar-purpose hints, not identical guarantees. Directory hints are platform-specific, not a universal
invalidation guarantee. Rebuild copied caches across platforms; no portability
framework or cache migration is required. Native platform execution must verify
filesystem and locking behavior before a support claim; API reasoning alone
does not establish runtime correctness.

## Derived relationships

Each authored half is stored under its owning file. Queries deduplicate their
union into logical dependencies so a one-sided edit cannot silently grant
readiness. Only Waiting on supplies a reason; an orphan Blocking half has an
explicit unavailable-reason label until the owner supplies one for completion.
Reverse lookup supplies incoming dependencies;
titles come from issue rows rather than copied cache fields. Endpoint
associations are logical: missing blockers remain representable and diagnosable,
not rejected by a strict target foreign key.

Derive readiness from cached dependencies and statuses. Derive the tag catalogue
and counts from associations; neither needs independently maintained state.

Refresh an issue's metadata, tags, and authored dependency claims together, preserving
edges owned by other issues. Use shared reconciliation with deduplicated file
sets; direct-neighbor checks do not recursively expand during a full scan.

## First-version scope and recovery

Do not persist bodies or prose-reference annotations in SQLite in this version. Read bodies
on demand; keep Rust responsible for parsing and reference interpretation.
No resident Rust watcher. Own mutations update affected cache entries; external
changes use best-effort signals, targeted reconciliation, and explicit full
refresh as described in the decisions.

The accepted command is `cache refresh [ISSUE]`: an issue ID refreshes that
record and checks its direct dependency neighbors; omitting the ID reconciles
the full ledger, including additions and deletions. Help must make the omitted-ID
scope explicit. Explicit refresh reads contents regardless of timestamp hints;
full reconciliation deduplicates reads rather than repeating neighbor checks.

When reconciliation discovers a malformed issue, flag it as unreadable and
exclude its stale metadata from normal results. Keep unrelated issues usable,
but warn that affected query results are incomplete; omission must not look
like confirmed absence. Preserve the Markdown unchanged. The representation
of unreadable records remains an implementation detail, not permission to
invent valid domain values or silently discard diagnostics.

Missing, incompatible, or corrupt caches rebuild automatically. If rebuilding
is impossible, explain the failure without changing Markdown to repair the
cache. If a Markdown mutation succeeds but cache synchronization fails, report
"edit saved; cache update failed", invalidate the cache for rebuilding on the
next command, and do not suggest retrying the successful mutation. Never claim
invalidation succeeded if that operation also fails; surface the remaining
uncertainty and recovery action.

## Performance validation

<a id="accepted-loading-experiment"></a>

### Loading evidence

Metadata reuse, the bounded reader pipeline and inventory reuse reduce repeated
filesystem/parsing work without introducing a resident process. Their ownership and bounds are
documented under [shared command state](#shared-command-state). Keep batch
recycling, extra SQL workers, and size-based alternate paths out unless new
workload evidence justifies their complexity.

### Measurement scope

Reuse the ledger lock mechanism to serialize cache-changing work, with SQLite
transactions exposing complete states. Keep waits bounded and report contention;
release locks and write transactions before printing results. Emacs refreshes
and agent mutations may overlap even for a single owner.

Provide optional release-mode performance tests, ignored by the default suite,
reusing the machine-generated 5,000-issue fixture from the
[large-ledger tests](../tests/large_ledger.rs). Use disposable ledgers only.
Measure warm metadata/list/tag/dependency queries, targeted reads with direct
neighbors, a mutation plus cache synchronization, targeted refresh, directory
membership changes, and full refresh/rebuild. Separate cache creation from warm
operation and filesystem enumeration from metadata checks and content parsing.

Include end-to-end CLI timings (startup and output capture), not just SQL or
in-process timings. Report repeated-sample medians and a tail summary, sample
count, fixture shape, machine, cache conditions, and output size; do not dump
ledger contents. Large-result output costs must remain distinguishable from
cache overhead. No Emacs timings are implied by these Rust tests.

Use the measurements to judge ordinary responsiveness and regressions, not
flaky machine-independent millisecond assertions in normal CI. Keep deterministic
correctness checks for returned results and intended bounded filesystem work
separate from timing claims. Select practical latency targets after measuring
the implementation; no numeric budget has been accepted yet.

Use SQLite `synchronous=OFF` only for disposable derived cache data: measured
fsync costs dominated targeted refreshes with default durability. Transactions
still isolate ordinary operations; an OS/power failure can lose or corrupt
cache updates, which must be rebuilt. This does not change Markdown publication.
See [SQLite's durability settings](https://sqlite.org/pragma.html#pragma_synchronous).
No WAL service, migration layer, or persistent connection pool is needed.
