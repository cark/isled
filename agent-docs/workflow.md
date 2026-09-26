# Contributor workflow

## Scope and execution

Keep each change focused on a concrete outcome. Discuss unsettled product,
architecture and compatibility decisions with the maintainer before changing
those boundaries. Existing authorization covers ordinary reversible implementation
choices within the agreed scope. Preserve unrelated work and supported contracts.

Prefer established build, test and preview entry points. A refactor does not
implicitly authorize a feature, schema change, deployment or publishing. Tool
failures do not authorize recovery actions against unrelated processes or files.
Report unexpected failures, their effect on stored data or verification, and
remaining uncertainty even when recovery succeeds. Diagnose the supported path
instead of silently bypassing a failure to obtain a passing result.

## Validation scope

Use one proportionate acceptance pass. Review the delta and run checks that
establish its affected behavior and boundaries. Tests protect observable contracts
and meaningful invariants; add regressions for material gaps rather than mirroring
the implementation. A separate reviewer or extra matrix needs a concrete risk or
maintainer request. Passing tests do not settle unresolved contract or cohesion
questions.

Reuse passing evidence while relevant inputs remain unchanged, including source,
callers, dependencies, fixtures and configuration. A new revision identifier or
unrelated documentation change alone does not invalidate evidence. Recheck affected
interactions and conflict resolutions after integration. Artifact identity and
installed behavior still require direct verification when installation is in scope.
Report the checked inputs/revision, reused evidence, skipped checks and final
candidate. Do not claim native platform support from cross-compilation alone.

The [contributor commands](../CONTRIBUTING.md#validation) own ordinary gates.
Optional maintainer validation may reuse receipts; contributors need neither
those receipts nor a local installation. Nix checks are conditional on changes to
packaging, dependencies or source boundaries. A docs-only change uses focused
link/content and whitespace checks; it does not require rebuilding the product.

## Development environments

Use declared dependencies and a reproducible setup. When changing an environment,
inspect its actual source inputs before building: exclude private state, generated
outputs, caches and VCS metadata unless required. Ignore rules alone are not proof
of a build boundary. The [Nix source guide](../scripts/README.md#source-boundary)
owns this project's optional source allowlists and commands. Source edits must not
invalidate a tool-only shell; tool-definition changes must refresh it without a
stale-shell fallback.

Reuse a verified environment during normal work. Tests use disposable ledgers and
fresh Emacs processes with explicit dependencies. Do not load personal init files,
contact a working daemon, or install validation bytecode alongside source. Optional
live reviews need explicit authorization and must preserve users' work.

## Documentation ownership

Use the [knowledge ownership map](coding-standards.md#knowledge-ownership).
Current behavior belongs in user/API documentation, accepted tradeoffs in design
docs, contributor rules in these guides, and remaining concerns in the applicable
issue tracker. Link to the canonical owner instead of duplicating specifications.
Accepted designs must be understandable without access to private issue records.

Explain why a decision fits the constraint, including material tradeoffs. Give the
basis for limits and defaults: measurement, calculation, a maintainer requirement
or an explicit estimate. Preserve uncertainty instead of inventing a rationale.
Update behavior, contracts, code maps, help, skill and dependency declarations in
the same change when affected. Metadata owns version declarations.

Keep pages focused and easy to navigate. File length is diagnostic, not a reason
to fragment a cohesive document. Substantial reusable investigations may be curated
into maintained project documentation; raw local experiments, deployment journals,
personal handoffs and private discussion history stay outside the tracked tree.
Ordinary fixes need no standalone report.

## Public repository boundary

Tracked files must be useful without a contributor's private filesystem or
configuration. Keep personal agent settings, real ledgers, installed artifacts,
caches and session history in ignored local state or outside the checkout. Never
make those files required startup context. Generic maintainer helpers can remain
public and optional, with their actual platform dependencies documented.

Run `python3 scripts/check-repository.py` to check tracked content and local links.
The checker catches concrete coupling and generated/private paths; it cannot
classify arbitrary prose as suitable for publication. Review publication content
and attribution as well. New rules or examples must use generic paths rather than
copying a working machine's setup.

Project requirements are self-contained. Contributors may also keep personal
global guidance; adopting a rule here neither removes it there nor creates an
automatic synchronization obligation. Review changes deliberately in each scope.
