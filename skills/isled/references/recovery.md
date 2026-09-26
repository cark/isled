# Recovery

Read this reference for an integrity finding, failed operation, or manual
repair. Do not load it for an ordinary successful mutation.

Ledger lock acquisition tolerates brief contention for up to 500 ms before
reporting `issue store is locked`. This retries acquisition only, not the command.
Do not remove a lock while another operation may own it; after a crash, confirm
no operation remains before deliberately removing a stale lock.

Generated `RELATION_*` warnings identify local missing mirrors, stale copied
titles, or missing/unreadable neighbors. Inspect the related issues and use
`check` for full integrity diagnostics. Inspection auto-corrects copied titles
from the target semantic title, preserving other bytes. Other warnings do not
authorize repair: a one-sided edit does not reveal addition/removal intent.
With authority, use `wait repair complete ISSUE BLOCKER [--reason TEXT]` or
`wait repair remove ISSUE BLOCKER`. Complete requires a surviving half and a
reason if Waiting on is missing. Remove handles surviving halves, including
missing targets; it never deletes issue files. Either half conservatively counts
as a dependency until that explicit choice. Read live help before repair.

For stale metadata after external edits, use `cache refresh ID` (target and
direct neighbors) or `cache refresh` (whole ledger). Only copied titles repair
automatically. Malformed records are omitted from metadata results with stderr
warnings; inspect them with `show`/`check`, not as absent issues.
Snapshots expose unreadable files separately with actual errors. Emacs offers
open-file and confirmed recoverable trash; relations are not deleted with them.
For strictly non-mutating diagnosis of Markdown, use `check` rather than refresh.
`edit saved; cache update failed` means the Markdown mutation succeeded: do NOT
repeat it. Pending invalidation causes a later cache operation to retry
reconciliation. Missing/incompatible caches rebuild automatically; detected
corruption warns and rebuilds. Surface unexpected failures under the consuming
project's rules even when recovery succeeds.

Start with `isled check`, which audits without repairing. Preserve the
records and diagnostic. Repair only through an explicitly understood,
recoverable procedure; do not silently initialize a missing store, infer a
replacement record, or mutate a live external ledger while diagnosing it.

Use `show ID` to inspect a uniquely named valid-UTF-8 record even when its
Markdown is malformed. Edits report parsing failures and leave the record
unchanged; `show` still rejects duplicate identities and invalid UTF-8.

`FILENAME_UTF8` and `CONTENT_UTF8` identify entries ordinary commands cannot
safely consume. Preserve a backup, use the escaped `check` locator to rename or
re-encode the entry without lossy decoding, and rerun `check` before resuming
semantic commands.
