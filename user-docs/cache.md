# Ledger cache

Markdown remains authoritative. The CLI keeps disposable metadata, tags, and
directed dependencies and known warnings in `.issues/.cache/ledger.sqlite`, using bundled SQLite.
Bodies and prose-reference annotations are not stored in SQLite.

## Known warnings

The shared cache retains last-known malformed/unreadable record diagnostics and
relation warnings. An unrelated command does not clear them. A condition is
cleared only when it is rechecked and no longer applies; unreadable or uninspected
neighbors cannot disprove an earlier finding. Clearing a finding rechecks the
affected issue and its direct relation neighbors, including former neighbors,
without recursively walking the graph. This is current known state, not an audit
history. Temporary operational failures such as lock contention are not retained.

Cache rebuilds regenerate findings from Markdown. No known warnings does not mean
the entire ledger has been checked. Filename/identity failures keep their existing
strict inspection behavior; ordinary warning navigation requires a valid issue ID.

## Reading and refresh

`list`, `path`, `wait show`, and `wait tree` use the cache. First use builds it;
warm metadata queries do not reopen all records. Single-ID `show` returns the
exact current UTF-8 file bytes, including malformed Markdown, and reconciles the
target and direct neighbors. [Batch show](README.md#inspecting-several-issues)
shares those reads across requested IDs, with individual failures and attributed
warnings instead of metadata-query omission hints. Wait inspection also
refreshes that neighborhood; deeper
graph traversal uses cached relationships. Missing or unreadable blockers are
not evidence of readiness and are diagnosed rather than fabricated.

Our mutations update affected entries immediately. External changes have
best-effort freshness: a directory timestamp change triggers a filename-set
comparison, not a full content scan. An in-place edit may remain unseen until
access or explicit refresh. Filename counts alone are never the test.

```console
isled cache refresh 60
isled cache refresh
```

The first refresh reads the selected issue and checks direct neighbors; the
second reconciles ALL issues, including additions and deletions. Explicit
refresh reads contents regardless of timestamp hints. Inspected copied relation
titles are corrected from target semantic titles; no other Markdown is changed
automatically. The usual short and hash-prefixed CLI ID spellings apply.

Malformed records are excluded from normal cached metadata results, with
stderr warnings that results are incomplete. Single-ID `show` and `check` retain their
diagnostic roles. Missing targets remain represented by incoming dependency
edges; targeted graph inspection reports that it cannot supply the missing node.
Successful partial metadata queries exit 0 with warnings; callers must inspect
stderr. Targeted missing/unreadable graph requests fail with exit 1.

`search`, the current full frontend `snapshot`, and `check` still inspect source
files. Snapshot reconciles the full cache and copied titles before constructing
its payload; it is not yet a bounded-loading frontend interface.
Reconciliation overlaps file reading with processing records already read.
Snapshot construction reuses that command's directory inventory; external
membership changes after enumeration may be observed by the next command.
Within a command, loaded bytes, parsed records, and read/parse failures are
retained and reused. Corrections update that retained state after publication,
so snapshot construction does not read or parse the same files again. This
memory is reclaimed at process exit by the one-command CLI, which skips walking
the loaded-record cache to free it. Locks, SQLite connections, and publication
cleanup still run normally. Library roots default to ordinary cache cleanup for
callers that remain running. This does not change external-edit freshness.

Refresh compares a 64-bit content fingerprint with the same issue's cached
fingerprint. Matching valid content leaves its metadata, tags, and relations
intact; changed content rebuilds that issue's projection. File timestamp hints
are updated separately when needed. This accepts the negligible accidental
collision risk of a non-cryptographic hash. Required source validation and
relation checks still run; timestamps alone never skip an explicit content read.

Title edits read direct participants; wait addition checks fresh endpoints and
cached graph reachability, subject to the external-edit freshness policy.
Run full refresh after bulk external edits before relying on that graph.

When records are inspected, generated relation warnings report missing mirrors,
stale copied titles, and missing/unreadable related records on stderr. Checks use
only the records read in that operation; warm metadata-only queries do not
reread neighbors just to regenerate warnings. Targeted inspection/refresh clears
fixed diagnostics on the next read. Either authored half of a dependency counts
until explicit completion/removal; a missing mirror never grants readiness. The
[snapshot contract](snapshot.md#generated-relation-warnings) defines codes and
explicit recovery choices. Malformed files appear separately in snapshots.

Copied-title correction holds the existing store lock, publishes once, and
reindexes corrected files directly without recursively opening the cache.
A failed correction warns and leaves pending invalidation when necessary; retry
refresh after fixing the reported cause. Unchanged titles are a no-op, avoiding
an endless write/notification/refresh loop.

## Recovery and concurrency

Missing or incompatible caches rebuild automatically. Detected SQLite corruption
also rebuilds, with a warning. Cache format changes include changes in derived
interpretation, not just SQL layout; no migration history is maintained.

Before publishing Markdown edits, the command records affected filenames in
`.issues/.cache/pending`. Successful synchronization removes this invalidation
marker; an interrupted batch is reconciled on the next cache operation. A damaged
marker triggers full reconciliation. This is cache invalidation, not a Markdown
transaction journal or a power-loss durability guarantee.

If an edit succeeds but cache synchronization fails, output explicitly says
`edit saved; cache update failed`. Do not retry the successful edit. The pending
marker remains so subsequent cache operations retry reconciliation. Failure to
record invalidation before publication prevents the edit instead.

The existing exclusive directory lock mechanism uses
`.issues/.cache/.isled-lock`, avoiding false issue-directory timestamp
changes on each lock acquisition. Cache operations and mutations share it.
Acquisition waits up to 500 ms for contention to clear, checking every 10 ms
(or the remaining timeout). An uncontended acquisition does not sleep.
Only acquisition is retried, never the operation: reads and mutations under the
lock see the state left by its previous holder. Exhausting the wait returns
`issue store is locked`; other filesystem failures return their actual error.
SQLite busy waits are also bounded. The timeout bounds lock waiting, not total
command execution, and operating-system scheduling can delay wakeup.
Do not remove a lock while an operation is running. A crash can leave a stale
lock requiring deliberate removal after confirming no operation owns it.
Do not mix old and new executables against the same ledger concurrently.

SQLite uses transactions with its rollback journal, but `synchronous=OFF` for
this disposable cache avoids fsync latency. OS/power failure may damage or lose
cache updates; reconciliation/rebuilding is the remedy. Markdown publication is
unchanged. Cache rebuilds never recursively delete `.cache` or its lock.

Cached commands need a writable cache directory, even when they do not modify
issues. Cache paths must not be symlinks. No watcher, SQLite executable, database
service, or user-installed SQLite library is required.
