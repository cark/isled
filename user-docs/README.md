# Isled user guide

Keep an issue close to the work: describe the concern, follow its dependencies,
record what you checked, and leave a clear outcome.

Use the CLI from your project directory, or browse the same ledger in
[Emacs](../frontends/emacs/README.md). For installation, start with the
[README](../README.md#installation).

## Start a ledger

```console
isled init
isled add 'Resume interrupted downloads' --kind feature 'Keep completed chunks when the connection drops.'
isled list --with-path
isled show 1
```

The new issue is `0001` in a fresh ledger. Commands find the nearest `.issues/`
in the current directory or its parents. Use `--root PATH` to choose a ledger.
`init` adds it to `.gitignore`; your project notes stay local.

## Find the next step

Use `list` when the answer is in an issue's metadata. Use `search` for words
anywhere in its Markdown, including dependency reasons.

```console
isled list --ready
isled list --kind bug --tags offline --with-path
isled search --status open 'interrupted download'
```

Filters combine: an issue must match every one. Search is literal and
case-insensitive, with Unicode case folding. Put search options before the text.

To inspect a dependency and the reason for it:

```console
isled wait show 1
isled wait tree 1
isled wait tree 1 --dependents
```

## Pick up work

Queue an issue, start when you begin, and pause for a break:

```console
isled work queue 1
isled work start 1 --activity Implementation
isled work pause 1
isled work start 1 --activity Testing
isled work await 1 --reason review
isled work show 1
```

Each resumed session gets a span. Review and questions stop the timer while you
wait. For states alone, use Start with `--no-clock`.

Find the earliest queued task or pending review:

```console
isled list --ready --work-state queued --oldest-first --limit 1
isled list --work-reason review --oldest-first
```

Work tracking is optional. See [work state and time](work-tracking.md) for owner
questions, timer corrections and arrival order.

## Keep the issue useful

```console
isled title set 1 'Resume guide downloads after reconnecting'
isled statement append 1 'Keep the previous saved guide usable until the replacement is complete.'
isled evidence add 1 'The interrupted download resumed on the same chunk in the offline trial.'
isled outcome set 1 'Downloads resume without replacing the saved guide with incomplete content.'
```

Title changes keep the ID and filename, so existing links still work. Related
issues receive the updated copied title. Use [Statement editing](statement-editing.md)
for multiline text and precise replacements.

If one issue needs another, use `wait add ISSUE BLOCKER REASON`. Both records
keep the relation. Closing the blocker satisfies it without erasing the reason.
Live help explains tag, priority and dependency edits:

```console
isled help tag
isled help wait
```

## Issue lifecycle and integrity

Close an issue once you have concrete Evidence and an Outcome:

```console
isled close 1
isled check
```

Closure is permanent. For a mistaken closure, an invalidated conclusion or new
scope, create a new issue referring to the old one. Closure stops timing, removes
priority and current work state, and keeps the spans and dependency history.

Editing a closed issue is allowed, with a warning that you are changing history.
No-op edits and automatic copied-title updates in neighboring records do not warn.

`check` inspects the whole ledger and never repairs it. A clean ledger prints
nothing and exits 0. Findings are tab-separated `LOCATOR`, `INVARIANT`, `DETAIL`
rows with exit 1; operational failures use stderr and exit 2. Invalid filename
bytes are escaped so you can identify the file to recover.

## Inspecting several issues

```console
isled show 1 2 3
isled show 1 2 3 | less
```

Records print in request order; repeated IDs repeat the record. A missing,
malformed or unreadable record reports its error on stderr while the others
still print. Any requested failure gives exit 1. Use a single-ID `show` to inspect
malformed content that is still valid UTF-8.

To page diagnostics too, use `isled show 1 2 3 2>&1 | less`. Isled does not start
a pager itself. Batch output is a readable overview; it may add a separating
newline and is not a byte-exact archive. Invalid ID arguments fail before the
batch starts. Relation warnings do not hide valid records or cause failure.

## Dependency tree inspection

`wait tree` follows prerequisites; `--dependents` follows work they unblock.
Each entry shows its ID, status, readiness, title and reason. Add `--with-path`
for file paths. Shared nodes appear where reached but expand once. Closed
prerequisites remain terminal leaves, preserving context.

For agents, `--json` returns schema 2 with `root`, `direction` and an ID-sorted
`issues` array. Each issue contains `id`, `status`, `ready`, `title` and `waits_on`.
Relations keep their dependent-to-prerequisite direction and reason even in a
`--dependents` query. Paths use the [snapshot encoding](snapshot.md).

## Command surface and storage

Issues are ordinary UTF-8 Markdown under `.issues/`. The
[record format](record-format.md) describes their sections and optional work
fields. SQLite stores a disposable query cache, not the issue prose.

Commands validate the records their operation needs. A malformed unrelated issue
does not prevent a local edit. `list` can return partial results with warnings;
inspect stderr before treating an omission as absence. Single-ID `show` reads the
current file; `search`, `snapshot` and `check` inspect complete records.

After external edits, use `isled cache refresh ID`, or omit the ID to refresh the
whole ledger. Isled's own mutations synchronize automatically. See
[cache freshness and recovery](cache.md), especially when an edit was saved but
its cache update failed.

IDs accept one to four ASCII digits, with an optional `#`: `1`, `0001` and
`'#1'` select the same issue. Quote hash-prefixed IDs in the shell. Output uses
four digits; IDs and filenames remain stable. Use `add` to create an issue.

## Frontend snapshot

Integrations can use [bounded frontend requests](frontend.md),
[complete snapshots](snapshot.md) or [complete issue drafts](editor.md).
These are versioned JSON interfaces. Ordinary CLI queries need none of them.

## Emacs frontend

The [Emacs tour](../frontends/emacs/README.md) shows browsing, filtering, editing
and work tracking. Its [user guide](../frontends/emacs/user-guide.md) covers
navigation, completion, appearance and key bindings.

## Help and compatibility

Run `isled help COMMAND [SUBCOMMAND]` for syntax, examples and failure behavior.
Help works without a ledger. `isled --version` reports the executable version;
source builds append `-dev`. Scripts should rely on structured data, stream
routing and exit status, rather than the wording of diagnostics.

Keep the CLI, frontend and agent skill compatible. Older tools cannot read
records with the new work fields. See [installation and updates](installation.md)
for paired bundles, stable paths and rollback.

## Distribution and local development

Release installation and daily use need no contributor tooling. To build or
change Isled, start with [Contributing](../CONTRIBUTING.md). The optional
[dogfooding guide](../agent-docs/dogfooding.md) covers local candidate promotion.
