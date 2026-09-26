# Isled contributor guide

Start with [contributing](CONTRIBUTING.md) and the relevant routes in
[the project guide](agent-docs/00-start-here.md). These instructions apply to
human and agent contributions; no personal configuration or private ledger is
required. A normal Git checkout supports the contributor workflow. If this
checkout uses Jujutsu, use jj for version-control mutations and preserve its
working-copy state.

Read [coding standards](agent-docs/coding-standards.md) and
[workflow](agent-docs/workflow.md) for source or documentation changes.
Read [compatibility](agent-docs/parity-contract.md) for CLI, storage, error or
wire changes; [module ownership](agent-docs/code-organization.md) when boundaries
change; and [refactoring](agent-docs/refactoring.md) before refactors.

Automated Emacs checks use the [isolated validation procedure](frontends/emacs/README.md#validation).
Never run tests against a working daemon or real issue ledger. Preserve unrelated
changes and unsaved work. Publishing, installed-tool replacement and issue closure
require the applicable maintainer or consuming-project authorization.

Update affected canonical docs in the same change. The [Isled skill](skills/isled/SKILL.md)
owns agent usage of the product, not contributor environment setup. Keep
[requirements](README.md#requirements), help, skill and metadata aligned when
interfaces or dependencies change. Report exact validation, relevant gaps and
the final revision. Use proportionate checks and reuse equivalent evidence.

Nix and jj-based [maintainer tools](agent-docs/dogfooding.md) are optional.
For Nix, use the [filtered source entry points](scripts/README.md#source-boundary).
Keep personal configuration, handoffs and operational history outside tracked
files; run the documented repository-boundary check before publication.
