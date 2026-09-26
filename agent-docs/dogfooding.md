# Optional maintainer releases

These helpers support a Git-colocated Jujutsu checkout on Linux with Bash,
Python, `flock`, GNU coreutils and the pinned Nix development environment.
They are optional; [ordinary contribution](../CONTRIBUTING.md) uses Git and the
direct Cargo/Emacs checks. Personal wrapper configuration, live state and release
journals belong outside tracked source.

## Promotion

Enter the [filtered environment](../scripts/README.md#source-boundary), select the
exact candidate with jj, and run:

```console
scripts/dogfood-release.sh validate EXACT_COMMIT
scripts/dogfood-release.sh promote EXACT_COMMIT
scripts/dogfood-release.sh status
```

Validation requires the exact working tree, runs missing or invalidated checks,
retains the optimized binary and writes a revision-bound receipt. Promotion verifies
the receipt and binary hash, installs that exact artifact into `.dogfood/releases/`,
and atomically updates `.dogfood/current`, retaining the prior selection as
`previous`. Promotion does not build or test. It requires explicit installation
authority; arbitrary source edits do not authorize replacing installed tools.

Use `validate EXACT_COMMIT --check-nix` when package/dependency/source-boundary
inputs change. This selects a check, not a push. `rollback` swaps current and
previous validated selections without rebuilding. Verify both selected identity
and installed behavior after an authorized installation or rollback. Configure any
stable launcher locally; no workstation path is part of the public procedure.

Emacs checks compile into temporary directories. Loading or installing an accepted
frontend is separate from CLI promotion; follow the [source-loading guide](../frontends/emacs/README.md#local-configuration)
and preserve any active user session. Do not let stale bytecode shadow source.

## Input-scoped evidence reuse

Use optimized binaries for representative 5k-ledger work; debug-build latency
is not a release performance estimate. The optional helper uses incremental
release compilation locally, without changing normal package profiles.

| Changed inputs | Invalidated evidence |
| --- | --- |
| Documentation only | Revision-specific content/link/whitespace checks |
| Emacs source or tests | Emacs compilation, lint and ERT |
| Rust source or tests | Rust checks, candidate CLI preparation and ERT |
| Rust production source or dependencies | Also optimized executable |
| Validation engine or pinned environment | All affected groups conservatively |
| Release helpers | Helper checks |

Fingerprints include source bytes/modes, dependencies, relevant tools/environment
and checker code. Commit identity binds the final receipt rather than every
reusable stage. A failure blocks candidate publication; successful independent
stages may be retained only while inputs remain unchanged. Missing/corrupt evidence
reruns its stage. Review still establishes semantic correctness and cohesion.

The default ignored `.dogfood/` store contains receipts, logs, retained artifacts
and revision selections. `ISLED_DOGFOOD_ROOT` can select an isolated store for
rehearsals. Store locking serializes validations; there is no automatic cleanup.
Old valid artifacts remain usable for rollback. Do not move local state into the
public source tree merely to make a release receipt available to contributors.

## Unexpected failures

Report unexpected product or installation failures promptly, including successful
automatic recovery. Distinguish a saved Markdown mutation from a failed cache
update, and distinguish a failed checker from failed activation. Preserve useful
failure evidence privately and state remaining uncertainty. Tests intentionally
injecting failures and first-use disposable cache creation are expected cases.
Issue creation and closure still require the applicable authority.
