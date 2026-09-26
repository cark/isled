# User documentation

See [complete issue drafts](editor.md) for the versioned load/validate/save interface.

## Command surface and storage

The `isled` command manages a local Markdown issue ledger. Start with
[installation and a quick example](../README.md#installation). Its help is the
operational command contract.

The [cache contract](cache.md) owns metadata-query freshness, explicit
`cache refresh [ISSUE]`, incomplete-result warnings, and recovery. Source files
remain authoritative; inspection may maintain disposable cache data and correct
copied relation titles, preserving other bytes.

The repository-built Rust command supports inspection through `list`, `search`,
`show`, `path`, `snapshot`, `frontend --stdin`, `wait show`, and `wait tree` commands, plus `init`,
`add`, title, tag and priority changes, wait addition/removal/repair, statement
set/append/replace, evidence addition, outcome setting, and `close`. Add, list,
search, and wait inspection accept `--with-path`. These mutation commands use
the established `.issues/`
records, directory lock, no-reuse ID allocation, and atomic per-file
replacement contract. Canonical issue filenames and complete Markdown records
must be valid UTF-8. Commands read only the records or headers their semantics
need: allocation uses filename identities; `path`, `list`, `wait show`, and
`wait tree` use cached metadata; `show`, closure, and local edits use their target; wait changes and
title edits add cached relations and participating records. Malformed prose in an unrelated
issue therefore does not block those operations. `search` and `snapshot` still
read every complete record; snapshot reports unreadable files separately,
while `check` remains the raw-byte recovery
interface. Every command fails before mutation if one of its required inputs is
invalid. Single-ID `show` selects by canonical filename identity and emits valid-UTF-8
bytes as currently stored after copied-title reconciliation, even when the heading, metadata, or
sections are malformed. Duplicate filename identities fail even if one matching
record is malformed. Edits parse the selected record and report its actual
parsing error before writing; malformed content is not treated as a missing
issue. `search` is literal and
case-insensitive with full Unicode folding and does not require Perl.

For metadata-only selection, use `isled list` and compose its status,
readiness, kind, tag, and wait filters; `isled list --ready
--with-path` is the direct ready-work query. `search` requires record text.
`frontend --stdin` supplies [bounded frontend data](frontend.md); `snapshot`
remains the complete wire interface and is not needed for routine filter
queries. Top-level, list, search, and snapshot help all route users accordingly,
and the common mistaken `isled ready` spelling points directly to
`isled list --ready` rather than suggesting an unrelated command.

For issue creation, use `isled add`; `isled help add` includes single-line
and multiline Statement examples. `create` is not an alias: `isled create`,
`isled help create`, and `isled create --help` fail with a hint naming `add`
and its help. These rejected invocations use stderr and exit 1 before project
discovery or any ledger change.

Each record uses the ordered level-two sections `Metadata`, `Statement`,
`Evidence`, and `Outcome`. Metadata is a Markdown list containing status,
kind, creation date, optional comma-separated tags, and optional nested
relations. Statement is non-empty Markdown, evidence is a non-empty list, and
outcome is one non-empty paragraph which may contain ordinary line wraps.
Semantic outcome mutations still accept one line. The exact grammar is documented in
[the format contract](record-format.md).

Every CLI issue-ID argument accepts one through four ASCII digits, optionally
prefixed by `#`: `1`, `0001`, `#1`, and `#0001` identify the same issue. Zero,
longer values, signs, and non-ASCII digits are rejected. Storage and output
always use the canonical four-digit form. Quote or escape a hash-prefixed ID in
a shell because an unquoted `#` may begin a comment.

`isled title set ISSUE TITLE` changes the semantic heading title on an
open or closed issue and refreshes its copied title in directly related
records. It accepts the same non-empty, single-line, tab-free title as creation.
Stable IDs, filenames, slugs, relation meaning, and prose remain unchanged, so
existing path links stay valid. Repeating the current title is a no-op;
frontends receive the new semantic title on their next snapshot refresh.

For complete multiline Statements at creation, whole-Statement updates, additions,
and targeted edits, see [Statement editing](statement-editing.md): stdin add,
set, append, and literal replace,
including deletion with an empty replacement and explicit repeated-match selection.

## Inspecting several issues

`isled show 46 57 67` prints valid records in requested order. Repeated
IDs repeat output, with shared setup, reads and parsing. Record titles provide
the boundaries: there are no decorative separators. A newline is inserted only
between emitted records when the previous record lacks one; the combined stream
is a readable overview, not a byte-exact archive.

With multiple ID arguments, malformed, missing and unreadable records are omitted
from stdout. Their actual errors go to stderr with the requested canonical ID;
remaining records still print, and any requested failure gives exit status 1.
Repeated arguments select this batch behavior even if they name the same issue.
Use a single-ID `show` to inspect malformed valid-UTF-8 content unchanged.
Relation warnings retain their codes and participant roles, use the requested ID
prefix, and neither hide valid records nor cause failure. Invalid ID arguments
are rejected before processing the batch; unavailable stores and cache failures
remain command-level errors.

Both streams appear in a terminal. Prior stdout is flushed before issue
diagnostics; independently captured streams have no combined ordering guarantee.
`isled show 46 57 | less` pages records while diagnostics go directly to
the terminal. Use `isled show 46 57 2>&1 | less` to page both. There is
no automatic pager. Inspection retains the existing cache freshness and
[copied-title reconciliation](cache.md) boundary. The
[accepted rationale](../agent-docs/decisions.md#batch-issue-inspection) explains
the distinction between raw single inspection and readable batch output.

## Dependency tree inspection


`isled wait tree ID` shows the transitive dependencies of one issue;
`--dependents` instead shows issues that transitively depend on it. The human
tree contains canonical IDs, status/readiness, semantic titles, and a separate
reason line. `--with-path` adds a separate canonical path line. Shared nodes are
shown wherever reached but expanded once. Preserved relations that no longer
block remain visible as terminal historical leaves, so old context does not
pull an irrelevant subtree into the result.

`--json` emits deterministic schema-version-2 adjacency data for agents. Its
top level contains `root`, `direction`, and an ascending-ID `issues` array.
Each issue contains `id`, `status`, `ready`, `title`, and the `waits_on`
relations included in the returned directional subgraph; each relation keeps
the true dependent-to-dependency target ID and reason even for a dependents
query. With `--with-path`, paths use the same lossless `encoding` and `value`
representation as snapshots. Tree output deliberately excludes issue prose,
kind, tags, evidence, and outcome.

## Frontend snapshot

The [snapshot wire contract](snapshot.md) owns schema version 3, byte encodings,
readiness, and inline-reference recognition and coordinates. This is a frontend
interface, not a replacement for focused CLI queries.

## Emacs frontend

The [Emacs getting-started guide](../frontends/emacs/README.md#getting-started)
explains the default `C-x p i` shortcut and expandable issue views. See
[issue filtering](../frontends/emacs/README.md#issue-filtering) for query syntax,
examples, and completion choices, [appearance customization](../frontends/emacs/README.md#theme-and-identity-styling)
for colors and fonts, or [key binding configuration](../frontends/emacs/README.md#key-binding)
to change the shortcut. The frontend guide also owns navigation, refresh,
installation, and package validation.

## Issue lifecycle and integrity

Evidence records concrete support for an issue's outcome; outcome records
the resulting decision or handling. Closure requires both at least one
concrete evidence entry and a outcome. The pending-evidence marker does
not count as evidence, and `check` reports `EVIDENCE_PENDING` if a closed
record still contains it.
Evidence additions reject mixing the reserved `Pending.` placeholder with
other entries, leaving the record unchanged.

Closure is terminal. The command has no `reopen` operation. A mistaken
closure, invalidated conclusion, or new scope receives a new issue that
references its closed predecessor. Closure removes priority but preserves
both directions of every dependency relation. A relation blocks only while its
target is open; closing the target satisfies the dependency without erasing
its durable context.

A title, statement, evidence, or outcome command that actually changes its
explicitly selected closed issue warns on stderr that it is updating the
historical record, while preserving normal success output and exit status.
Open-issue changes, byte-identical no-ops, and rejected operations do not warn.
Automatic copied-title updates in related closed records add no warnings.

The Rust `check` command is available and read-only. Clean ledgers produce no
output and exit successfully. Integrity findings are deterministic
tab-separated `LOCATOR`, `INVARIANT`, and `DETAIL` rows on stdout with exit 1;
operational failures use stderr and exit 2. It never repairs findings.
Invalid issue names and contents produce `FILENAME_UTF8` and `CONTENT_UTF8`
findings. Invalid filename bytes are escaped, so the report itself remains
readable UTF-8 and identifies the entry that must be recovered.

## Help and compatibility

Every command and nested operation has detailed repository-built help via
`isled help COMMAND [SUBCOMMAND]` or direct `-h`/`--help`. Help is
stable and colorless, works without a project, and documents arguments,
behavior, output, failures, and important recovery constraints. Its layout and
diagnostic prose are Rust-native; scripts must rely on command data, stream
routing, and exit meaning rather than prose formatting.

The repository-built Rust command has passed its historical version 0.1
differential acceptance. Rust behavior, live help, this user contract, and the
Rust tests are now authoritative; Bash comparison is optional historical
diagnosis rather than routine acceptance.

## Distribution and local development

Home Manager selects a stable wrapper to an explicitly promoted Rust binary;
source edits alone do not change that command. The
[dogfooding procedure](../agent-docs/dogfooding.md) owns exact-candidate promotion,
installed-command verification, rollback, and the separate source-loaded Emacs
workflow. Ordinary promotions do not require a NixOS rebuild. Immutable Nix
packaging remains available for stable releases; the archived Bash repository
is historical evidence, not an operational fallback.
