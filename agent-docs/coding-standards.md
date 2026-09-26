# Coding standards

These are project requirements for source changes, refactoring and technical
design. Apply the general and relevant language sections within the agreed scope.
Project contracts and commands below supply concrete boundaries.

## Conceptual cohesion

Each source file owns one concrete concept or one principal behavior-bearing
type. Small supporting enums, structs, functions, and focused tests may stay
alongside it when they serve that responsibility rather than introduce another
independent concern. This applies across source languages, including Rust, Emacs Lisp,
TypeScript/React, executable entry points, route handlers and tests. One large struct or hook is not an exception: unrelated responsibilities
do not become cohesive by sharing a type. Do not introduce a struct merely to
organize code that is naturally expressed with functions.

Sharing a caller, technical layer, or broad label such as "commands", "I/O", or
"utilities" is not enough. Independently meaningful concepts belong in separate
files, not merely nested inline modules in the same file. Dispatchers route;
command-specific workflows belong in their handlers. Use ordinary functions
and modules without introducing a command framework just to split files.

Before adding substantive code, inspect related implementations, including across
package boundaries, and identify opportunities for reuse and the appropriate owner
of each responsibility.
During the acceptance pass, review each touched source file for cohesion regardless of
size: can its responsibility be named precisely, and do its supporting parts
belong to it? Inspect the whole file, not just the added lines. Update the code
map when ownership changes. Record a brief cohesion conclusion in the handoff,
not a standalone report or a mechanical per-file checklist. Surface material
opportunities to simplify the design or avoid duplication, explaining their benefit
and tradeoff. Agree scope before broader refactoring; do not silently expand work
or claim conformance with unresolved findings.
Carry this review forward while the file and its relevant callers are unchanged;
a new reviewer or handoff does not require restarting it.

File length is a warning signal, not a decomposition target. Keep modules well
below 1,000 nonblank lines. Any touched source file at or above that
threshold requires explicit module-organization review and blocks completion
until its cohesion is accepted or it is split. Small files still require
truthful boundaries; do not extract trivial fragments merely to satisfy a count.

Use the project's established size check when available. Its count measures size
only; a below-threshold result never establishes cohesion. An organization-review
requirement cannot be waived through a success flag. Keep hierarchies shallow until
real sub-concepts emerge; prefer feature-local sharing and small export surfaces.

## Function composition

For new and changed code, including refactors, prefer one cohesive traversal per
function. Separate traversal mechanics from orchestration through meaningfully
named helpers, keeping each function at a consistent level of detail. Keep
trivial loops or tightly related algorithmic steps together when extraction
would obscure the flow or require passing partially constructed state between
helpers. Loop count is a review signal, not a mechanical limit.

Design interfaces around the operation's required capabilities and invariants.
In Rust, prefer borrowed, generic traversal inputs such as `IntoIterator` when
iteration is sufficient, with only the bounds the algorithm needs. Use concrete
types when they express meaningful guarantees. Avoid requiring collection
conversions solely for interface convenience.

For Rust sequence traversal, prefer returning `impl Iterator` when ownership and
validation semantics allow it; let callers compose sequences and collect where
storage, sorting, or repeated access is needed. Preserve validation coverage
and error ordering: lazy, fallible iteration may leave input unchecked when a
caller stops early. Retain eager validation where required. Iterator composition
does not by itself eliminate repeated scans or parsing; apply the
[responsiveness standard](#responsiveness) to the complete operation.

## Simplicity

Choose the simplest design that fully satisfies the accepted requirements.
Every additional abstraction, layer, state transition, configuration option,
dependency, compatibility mechanism, or recovery mechanism must answer a
concrete present need. A possible future requirement may justify preserving a
clean seam, but not implementing a framework before that requirement exists.

Before accepting a design, ask what can be removed while retaining correctness,
clarity, and the required user experience. Prefer small explicit mechanisms and
reversible local changes over generalized machinery. KISS does not mean
cutting essential validation, invariant-bearing types, useful diagnostics,
tests, or proportionate recovery; omitting those merely moves complexity and
risk onto users and future maintainers.

## Obsolete code

When adding or changing code, remove implementations, helpers, and re-exports
made obsolete by the change. When replacing an execution path, check whether
the previous path still serves a supported use. Public visibility and passing
compiler checks do not establish that code is needed.

Before removal, inspect callers, re-exports, tests, indirect entry points, and
the supported external API contract. Retain code with an established use or
compatibility obligation; do not keep an unused alternative for hypothetical
future needs. Keep this review within the affected scope. A full-project sweep
must check throughout that scope; findings outside an ordinary change's scope
should be surfaced rather than silently included. Report unresolved usage or
compatibility questions before claiming the cleanup complete.

## Compatibility decisions

Adding, preserving or removing backward or forward compatibility is always a
maintainer decision. Ask explicitly before choosing compatibility behavior for an API,
data or schema format, command, workflow, deployment state or stored artifact,
unless the maintainer already made that exact choice for the current boundary. Do not
infer the choice from existing code, implementation convenience, migration cost,
stored artifacts or passing tests. Record the accepted boundary and rationale in
its canonical project documentation, then apply it without asking again; ask anew
when later work exposes a materially different compatibility boundary.

## Responsiveness

Responsiveness is a design and completion requirement for new code, changes to
existing code, and refactors. Choose algorithms and data containers suited to
the expected workload. Before implementation and during review, examine how
work grows with input size and dependency count, including repeated collection
scans, parsing, filesystem access, and process calls. Avoid doing the same work
repeatedly when a simple index, retained parsed value, or bounded read can remove
it. Preserve duplicate detection, validation scope, and error ordering when
changing representations.

Simple linear scans are appropriate for small, bounded inputs; do not introduce
indexes or caches without a concrete benefit. Inspect actual callers and input
bounds rather than judging a helper in isolation. Review affected execution
paths, not just individual functions, and surface unresolved scaling concerns
instead of claiming completion from correctness tests alone.

Treat allocation and copying as design costs. Prefer borrowing, iterator
composition, and buffer reuse when they keep the code clear. Avoid intermediate
collections and repeated allocations without a concrete purpose, especially
inside loops; consider both allocation frequency and data volume. Accept
allocations that support correctness, useful indexing, ownership, or simpler
implementation. Judge total work and retained memory, not allocation count alone;
do not introduce disproportionate complexity to eliminate allocations. Remove
straightforward waste without demanding benchmarks; measure when choosing
between competing costs.

Use representative workloads to support performance claims. Separate startup,
I/O, parsing, lookup, and output costs where relevant; use deterministic checks
for bounded work when practical. Follow the project's existing representative-workload guidance when relevant. Record a brief responsiveness conclusion and any
measurement gaps in the handoff; no standalone report or benchmark is required
for every small change.

## Symbol naming

Choose self-explanatory names, taking into account the context visible where
the symbol is used. Include the action and subject when needed; omit words only
when the receiver, module qualification, or visible call-site context supplies
their meaning.
Context inside the implementation does not help a reader at the call site.

For example, prefer `frobnicate_files(...)` for a standalone operation, while
`files.frobnicate()` or `files::frobnicate(...)` can make the subject clear without
repeating it. If callers normally import a function without its module qualifier,
judge its name in that unqualified form too.

A broad technical module name may not explain the operation's subject:
`filesystem::initialize()` leaves what is initialized unclear. Prefer
`filesystem::initialize_ledger(...)` for an operation that prepares the issue
ledger. A nested module also named `initialize` adds no missing meaning.
Names should express purpose without requiring the reader to open the body;
they need not enumerate every implementation step.

Give nearby functions distinct names for their roles instead of progressively
longer versions of the enclosing operation's name. Avoid stacking input,
subject, and result details already clear at the call site. For example,
`repair_copied_titles` can compose `rewrite_relation_titles(record, titles)`:
the helper names its contribution without repeating the whole workflow.
Proximity supplies context only when each function's purpose remains clear.

Apply this rule to new and changed symbols within the authorized scope. Adopting
the standard does not authorize a project-wide rename sweep. Internal API
renames follow the [refactoring scope rules](#refactoring);
preserve supported external contracts.

## Types and boundaries

Parse weak input into a domain type that carries established invariants. Do not
validate a string and continue passing the original primitive. Keep filesystem
and process boundaries narrow, preserve bytes where the accepted contract requires it, and
make normal invalid input and operational failures return structured errors rather
than panic.

Parsing may perform validation; its advantage is retaining proof of success in
an invariant-bearing type instead of returning a boolean and forgetting it.
Keep fields private, audit every constructor and deserialization path, and use
structured parse errors. Create a distinct type only when its invariant remains
meaningful after the boundary; otherwise parse into an existing domain type and
avoid decorative newtypes. Validation-only traversal remains appropriate for integrity checks on an already
parsed aggregate when no downstream value needs a narrower type. Otherwise retain
the checked property in the returned type. Name types after their domain meaning,
not the fact that validation happened: a selector parser can return a
`JjChangeSelector` distinguishing `@` from an ID prefix, rather than a
`ValidatedString`. Audit stored-row decoding and conversions as construction paths
too. Weak transport/audit input may stay weak until its deliberate parse boundary.
For Rust, prefer a private constructor, `FromStr`, `TryFrom` or a focused parser
returning the invariant-carrying type. Normalization must be explicit.
Background: [Parse, Don't Validate](https://www.rustfinity.com/blog/parse-dont-validate).

Use a crate when it provides a mature implementation of subtle generic
behavior. Implement small project-specific rules locally. Dependencies must
reduce risk or complexity enough to justify their maintenance and build cost.

## Emacs Lisp conventions

Treat Emacs Lisp as first-class product source. Use conventional package
metadata, lexical binding, namespaced symbols, standard customization and face
definitions, derived major modes when providing a major mode, buffer-local view
state, and familiar keys.
Keep process execution and weak JSON decoding outside rendering and interaction
logic. Convert validated wire objects into named structures before the view
uses them.

Use idiomatic sequence operations and ordinary collections; introduce generators
only when lazy consumption provides a concrete benefit.

Mirror conceptual source boundaries in focused ERT tests. Package source must pass
its applicable parenthesis, byte-compilation, Checkdoc, Package-lint and ERT checks
in isolation under the [Emacs execution boundary](emacs.md). Keep a short code map
beside the frontend so humans and agents can locate its public entry point, process
boundary, view logic and tests without broad search.

## Formatting and tests

Use idiomatic language conventions and repository-configured formatting/lint tools;
do not introduce ad hoc tooling in unrelated work. Rust uses four-space indentation,
`snake_case` functions/modules, `PascalCase` types and `SCREAMING_SNAKE_CASE` constants.

Tests protect observable contracts and meaningful invariants, not copies of the
implementation. Keep implementation and focused tests with their concept. Broad
end-to-end compatibility belongs in dedicated integration tests; different boundary
coverage can overlap legitimately. Add meaningful regression coverage when needed,
following [validation scope](workflow.md#validation-scope).

## Refactoring

Name the responsibility being changed, its intended destination and the behavior to
preserve. Inspect the affected implementation and callers before choosing boundaries.
Discuss unresolved architecture/compatibility choices; a refactor does not authorize
a feature, schema redesign, naming sweep or deployment. Preserve unrelated work and
supported external contracts.

Use small, independently reviewable named increments; keep inseparable moves together.
Review and repair each candidate before dependent work begins. A separate reviewer,
workspace or complete acceptance pass is not implied by each increment. Use Git or the checkout's chosen version-control workflow; optional jj tools are described in
[dogfooding](dogfooding.md).

Move supporting types, helpers and focused tests with their responsibility. Review
whole touched files for cohesion, obsolete paths/callers and operation-wide costs
under the standards above. Preserve the required validation, authorization, read,
lock, transaction, publication, warning and cleanup order. Consult the local contract
and boundary map for the operation's constraints; do not infer compatibility from
passing tests alone.

Use semantic references when they answer a concrete impact question. Treat generated
edits as proposals requiring source review. Recheck affected callers after moves;
source comparisons support preservation review but do not replace applicable
compilation or behavioral tests. Add focused coverage for meaningful gaps.

Update changed code maps and affected canonical documentation in the same change.
Report the transformation, exact verification, reused evidence, final revision,
remaining gaps and brief cohesion/responsiveness conclusions. Preserve local
promotion, issue and external-action authority boundaries.

## Compatibility and cache boundaries

Preserve validated user text bytes under the [compatibility contract](parity-contract.md).
Runtime SQL uses the cache's prepared-statement interface; callers must not bypass
its [explicit lifecycle boundary](cache-design.md#prepared-statement-execution-boundary).
Use [representative performance guidance](cache-design.md#performance-validation)
for large ledgers and update the [module map](code-organization.md) when ownership changes.

## Validation scope

Use the [contributor commands](../CONTRIBUTING.md#validation) and the
[workflow's evidence-reuse rules](workflow.md#validation-scope). The size checker
reports a review signal only; a below-threshold file still needs cohesion review.
Emacs static/ERT checks run in isolation under the [frontend validation contract](../frontends/emacs/CONTRIBUTING.md#validation).
Optional Nix and maintainer-helper gates apply when their inputs change. Core
contribution does not require jj, local release receipts or installed dogfood tools.

## Knowledge ownership

| Knowledge | Owner |
| --- | --- |
| CLI use, storage and wire formats | `user-docs/`, with exact syntax in CLI help |
| Emacs setup and user behavior | `frontends/emacs/README.md` and `frontends/emacs/user-guide.md` |
| Emacs implementation, code map and validation | `frontends/emacs/CONTRIBUTING.md` |
| Compatibility guarantees and change policy | `agent-docs/parity-contract.md` |
| Accepted rationale and design constraints | `agent-docs/decisions.md` and focused design pages |
| Contributor rules, architecture and optional operations | The corresponding routed project guide |
| Remaining concern and concise evidence/outcome | The applicable issue tracker; private ledgers are optional |
| Personal handoffs, raw experiments and deployment history | Ignored local state or private storage outside the repository |

Project documentation must not depend on the owner's private archive or ledger.
Keep personal global guidance intact when adopting its relevant rules here.
