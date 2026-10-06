# Ledger cache

Your Markdown files are the ledger. Isled uses a disposable SQLite cache to
answer metadata queries quickly: status, kind, tags, work state and dependencies.
Issue prose and its reference annotations stay out of SQLite.

For ordinary use, you need only two refresh commands:

```console
isled cache refresh 60
isled cache refresh
```

The first reads issue 60 and checks its direct neighbors. The second reconciles
the whole ledger, including added and removed files. See
[reading and refresh](#reading-and-refresh) for when to use them.

## Known warnings

Isled remembers malformed records and relation problems until the affected
records are checked again. An unrelated command cannot clear them. An unreadable
neighbor cannot disprove an earlier finding.

These are current known problems, not an audit history. Temporary failures such
as lock contention are not retained. Rebuilding the cache regenerates findings
from Markdown. No known warnings does not mean every record has been checked;
use `isled check` for that.

Rechecking a finding reads the affected issue and direct neighbors, including
former neighbors. It does not walk the whole dependency graph. Ordinary warning
navigation requires a valid issue ID; filename and identity failures keep their
strict inspection behavior.

## Reading and refresh

Isled's own mutations synchronize the cache automatically. External edits have
best-effort freshness: a changed directory timestamp prompts a filename-set
comparison, but an in-place content edit can stay unseen until inspection or
explicit refresh. File counts alone are never the test.

| Command | What it reads |
| --- | --- |
| `list`, `path` | Cached metadata; first use builds the cache. |
| `wait show`, `wait tree` | The selected issue and direct neighbors; deeper traversal uses cached relations. |
| Single-ID `show` | Current UTF-8 file bytes, even with malformed Markdown; reconciles the local neighborhood. |
| `search`, `snapshot`, `check` | Source records; snapshot reconciles the full cache and copied titles. |
| `frontend --stdin` | The [request's read scope](frontend.md), including bounded detail batches. |

After a targeted external edit, refresh its ID. After bulk edits, refresh the
whole ledger before relying on dependency reachability. Explicit refresh reads
content regardless of timestamp hints.

Inspection corrects copied relation titles from the target's current title.
No other Markdown is repaired automatically. Unchanged titles cause no write.
A failed correction warns; fix the reported cause, then refresh again. Within
one command, reads and parsed records are reused, including after a correction.

### Incomplete results

Malformed records are omitted from normal cached metadata results, with stderr
warnings that the results are incomplete. Partial metadata queries can exit 0;
inspect stderr before treating a missing row as confirmed absence.

Single-ID `show` and `check` keep their diagnostic roles.
[Batch show](README.md#inspecting-several-issues) reports individual failures,
continues through the requested IDs, and exits nonzero if any failed. A targeted
missing or unreadable graph request exits 1.

Missing or unreadable prerequisites never establish readiness. Either surviving
half of a dependency still counts until you explicitly complete or remove it.
The [snapshot contract](snapshot.md#generated-relation-warnings) lists warning
codes and recovery actions. Targeted inspection clears a fixed diagnostic on
the next successful recheck.

### Cache details

The cache lives in `.issues/.cache/ledger.sqlite`, using bundled SQLite.
Cached commands need a writable cache directory even when they change no issue.
Cache paths cannot be symlinks. No database service, SQLite executable or
separately installed SQLite library is needed.

Refresh compares a 64-bit content fingerprint before replacing an issue's cached
metadata. Matching content leaves that projection intact; explicit source reads
and relation validation still run. This accepts the negligible accidental
collision risk of a non-cryptographic hash. Timestamps alone never skip an
explicit content read. See the [cache design](../agent-docs/cache-design.md)
for implementation and performance details.

## Recovery and concurrency

Missing or incompatible caches rebuild automatically. Detected SQLite corruption
also rebuilds, with a warning. Cache formats have no migration history; Markdown
remains the recovery source.

### An edit saved but its cache update failed

If output says **`edit saved; cache update failed`**, the Markdown mutation
succeeded. Inspect the saved record; do not repeat the edit. The next cache
operation retries reconciliation.

Before publishing, Isled records affected filenames in `.issues/.cache/pending`.
Synchronization removes this marker. An interrupted batch is reconciled later;
a damaged marker triggers full reconciliation. Failure to record it prevents
the edit. The marker tracks cache invalidation; it is not a Markdown transaction
journal or a power-loss guarantee.

### A locked ledger

Cache operations and mutations share `.issues/.cache/.isled-lock`. Lock
acquisition waits up to 500 ms, checking every 10 ms or the remaining timeout.
An uncontended acquisition does not sleep. Only acquisition is retried, never
the operation itself. An exhausted wait reports `issue store is locked`;
other filesystem errors retain their actual cause.

Do not remove a lock while an operation owns it. After a crash, confirm no
operation is running before deliberately removing a stale lock. Avoid mixing
old and new executables against one ledger concurrently.

SQLite busy waits are bounded too. These bounds cover waiting, not total command
execution; operating-system scheduling can delay wakeup. SQLite uses transactions
with `synchronous=OFF` for this disposable cache. Power loss can damage cache
updates; reconciliation or rebuilding recovers them. Rebuilds never recursively
delete `.cache` or its lock. Markdown publication keeps its separate guarantees.
