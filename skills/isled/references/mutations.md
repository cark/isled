# Issue mutations

Read this reference before creating, editing, relating, or closing an issue.

## Safe mutation

Use structured `isled` mutations so validation, stable IDs, and
relation updates remain centralized. Prefer idempotent desired-state operations
over hand-editing Markdown. Confirm the exact project root and target IDs, then
inspect the resulting record or query when the outcome matters.

## Issue content and links

Write each issue as a self-directing brief with enough outcome, scope,
constraints, and dependency context for a future agent. Keep larger rationale,
designs, and evidence in their canonical project documents rather than copying
them into the ledger.

When a maintained artifact supplies durable context, link it descriptively from
the statement or evidence. Within project-authored Markdown, prefer a
repository-local relative target resolved from the containing file; never
embed checkout-specific absolute paths. An issue under `.issues/` therefore
usually links to a root document with `../path`. Confirm the target exists and
preserve useful links during rewrites. Do not manufacture links for incidental
commands, temporary files, or every mentioned code path.

Use canonical `#NNNN` for same-ledger references. Readers accept shorter
spellings, but they are not the authoring convention. Use an ordinary Markdown
link for cross-ledger references, and prefer a relative target when both
artifacts are in the same project. Do not put a competing compact reference in
link text; escape it as `\#NNNN` when an ID-shaped value must remain inert.

## Semantic edits

`statement set` replaces the main prose; `statement append` adds a paragraph.
They may clarify closed history, but new scope requires a new issue.
All Statement edits validate the complete resulting section before publication,
including argument-based set/append; reserved level-two headings are rejected.

For creation with a single-line Statement use `add TITLE STATEMENT --kind KIND`.
For a multiline Statement use `add TITLE --kind KIND --stdin`
instead of a statement argument. Reserved level-two headings are rejected before
allocation; use level-three or deeper subsections.
For complete multiline Statement replacement use `statement set ISSUE --stdin`,
supplying only the new Statement, without a separator. Set and append accept
either TEXT or `--stdin`, never both. One final LF is input framing; the Statement
must remain non-empty and satisfy the existing grammar.
For multiline Statement additions use `statement append ISSUE --stdin`; for
targeted edits use `statement replace ISSUE --stdin`. Supply literal old text,
the separator line, and replacement text; empty replacement deletes. Use a
quoted heredoc to avoid shell interpolation. Read `help statement replace` for
framing and deletion examples. Ambiguous matches fail unless explicitly selected
with `--occurrence N` or `--all`; inspect rather than guessing on failure.
These operations are Statement-only and avoid external Markdown extraction or
direct ledger edits. Evidence and Outcome keep their existing commands.

`title set` changes the semantic heading and copied titles in direct neighbors
while preserving the stable ID, filename, slug, relations, and prose. Repeating
the current title is a no-op. Present semantic titles to users; filenames are
path identity, not title data.

Successful title, statement, evidence, or outcome changes to the explicitly
selected closed issue warn on stderr while retaining normal success output
and exit status. This is informational, not a failed operation or a reason to
retry. Open issues, byte-identical no-ops, and copied-title maintenance in
related closed records do not trigger the warning.

Before completing a content mutation, scan statement and evidence for named
supporting artifacts, link durable context, and remove links that no longer
support the issue.

## Evidence, outcome, and closure

Before closure, add concrete evidence; the pending placeholder does not
count. Evidence records facts such as exact revisions, validation, or
reproductions. It neither states the conclusion nor authorizes closure.

Use `outcome set` for the single current conclusion. It changes neither
status nor evidence. `close --outcome` is convenient only after closure
is authorized under the owner or consuming project's rules and the outcome
remains pending.

Outcome states the conclusion in one short sentence. Put supporting details in
Evidence or linked documentation.
Before an authorized closure, replace stale approval-request wording with
the final conclusion through `outcome set`, then close and verify status.

Closure is terminal. A mistaken closure, invalidated conclusion, or new
scope receives a new issue referencing the closed predecessor. When evidence
supports closure but authority is absent, recommend it and wait for approval.

## Complete drafts

`editor --stdin` provides schema-2 load, validate and complete-draft save requests;
the consuming project's user documentation owns the exact wire contract. Inspect
`ok`/`code` in its JSON response even on exit 0. Retain the load version for stale
save rejection. Validation publishes nothing and consumes no ID. Replacing a
conflicting version requires an explicit owner decision, not an automatic retry.
A publication failure or lost save reply may follow writes: inspect saved state
before retrying, especially for creation. The explicit `close` intent applies the same closure rules; it grants no lifecycle,
external-write or issue-closure authority beyond the consuming project's rules.

## Wait relations

`ISSUE` waiting on `BLOCKER` is directed and owns a concise reason. Both records
mirror IDs and copied titles; only `Waiting on` stores the reason. The CLI
checks fresh endpoints and cached reachability; external edits outside the
refreshed neighborhood have best-effort freshness. Refresh the full cache after
bulk external edits before graph mutations, and use `check` for complete graph
integrity. Closure preserves relations as context, but only an
open target blocks. Use live `wait` help for exact operations.
