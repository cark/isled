---
name: isled
description: Inspect, maintain, or report on a project-local durable issue ledger for owner or steward concerns that persist across revisions and conversations.
---

# Isled — a personal issue ledger

Use this skill for coarse owner or steward concerns that must remain visible
across revisions, restarts, and conversations.

## Core workflow

The ignored `.issues/` ledger is independent of source revisions. Use nearest
project discovery or explicit `--root`, and use semantic commands rather than
reading or editing ledger internals. The live help is authoritative for syntax,
fields, output, and failures:

```text
isled help [COMMAND [SUBCOMMAND]]
```

For authorized issue creation, use `add`; `create` is not an alias.
Read `isled help add` for options and single-line or multiline examples.

Commands validate only the identities, headers, or complete records their
semantics require. Use `check` for ledger-wide integrity; `search` and
`snapshot` necessarily read every complete record. CLI issue IDs accept one to
four ASCII digits with an optional `#` and normalize to four digits. Quote a
hash-prefixed ID in shells where `#` begins a comment.

Use `list` with composable filters for metadata-only selection such as ready,
waiting, status, kind, or tags. Use `search` only when matching record text.
`snapshot` and `frontend --stdin` are frontend wire interfaces; do not decode them merely to
reproduce a `list` query.

Metadata queries use a disposable cache. After external edits use `cache refresh
ID`, or `cache refresh` for ALL issues. External freshness is best effort;
incomplete-result warnings mean omissions are not confirmed absence. Our own
mutations synchronize automatically; see recovery for cache failures.
Known relation warnings persist until their affected neighborhood is rechecked;
unrelated commands do not clear them.
Inspection can automatically correct copied relation titles from their target;
all other relation repairs require an explicit choice. `check` never repairs.

Use `show ID...` to survey several records in request order, including repeats.
Batch output omits malformed, missing or unreadable records, reports each error
with its requested ID on stderr, continues other records and exits nonzero on
any requested failure. Relation warnings do not hide valid records. Single-ID
`show` retains raw valid-UTF-8 inspection, including malformed content. Batch
output adds only necessary inter-record newlines and is not a byte-exact archive.

For focused dependency context, use `wait tree ID`; add `--dependents` only
when downstream impact is the question. Prefer `--json` for agent consumption:
it omits full issue prose while preserving reasoned `waits_on` orientation.

## Link issue mentions

In ordinary agent chat, the first prose mention of each local issue must be a
Markdown link to its canonical issue file. Resolve exact paths with `path` or a
path-enriched query; never infer a filename from a title or slug or choose among
ambiguous matches. Prefer a descriptive `NNNN — Title` label when available.
Follow the host's local-file link convention.

Before completing a response, scan it for issue IDs. Bare IDs are permitted
only in commands, structured or quoted output, when no exact path is available,
or after that issue was already linked. Do not alter payloads merely to add a
link. Treat this as a completion gate, not presentation polish.

When authoring ledger content, use canonical `#NNNN` for same-ledger references.
The mutation guidance owns links to documentation and cross-ledger material.

## Authority and routing

Creating, changing, relating, or closing an issue is durable bookkeeping and
requires explicit owner or consuming-project authority. A finding alone is not
authority. Follow the consuming project's `AGENTS.md` for issue scope and
vocabulary.

Establish closure authority under the owner or consuming project's rules.
Implementation, validation, acceptance, promotion, evidence and outcome do not
themselves grant closure authority. When it is absent, recommend closure with
the evidence and uncertainty, then wait for authorization.

When a distinct durable concern would otherwise be lost, search for existing
coverage and propose the smallest suitable issue or update. Do not create it
without authority or propose issues for routine execution details.

Load only the guidance required by the operation:

- Before creating, editing, relating, or closing an issue, read
  [issue mutations](references/mutations.md).
- For an integrity finding, failed operation, or manual repair, read
  [recovery](references/recovery.md).
