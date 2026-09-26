# Contributing to Isled

A normal Git checkout is sufficient. See [requirements](README.md#requirements)
for the Rust/C toolchain and Emacs runtime dependencies. Contributor checks also
use Python 3.9 or newer and Git. Nix, Jujutsu and Linux graphical-preview tools
are optional; no personal ledger, agent configuration or installed Isled is needed.

Read [coding standards](agent-docs/coding-standards.md),
[workflow](agent-docs/workflow.md) and the [project routes](agent-docs/00-start-here.md)
for your change. Preserve unrelated work and user-authored data. Use disposable
ledgers for experiments and tests.

## Build

```console
cargo build --locked
cargo run --locked -- --help
```

For a local source installation, use `cargo install --path . --locked` and make
Cargo's binary directory available on PATH. Use `isled --root DIRECTORY` to choose a
separate disposable ledger when trying commands. The [user guide](user-docs/README.md)
explains normal use; the [frontend guide](frontends/emacs/README.md) covers Emacs setup.

## Validation

Run the applicable gates from the checkout root:

```console
cargo fmt --check
cargo check --locked
cargo test --locked
cargo clippy --locked --all-targets -- -D warnings
python3 scripts/check-coding-standards.py
python3 scripts/check-repository.py
python3 -B scripts/test-contributor-checks.py
```

The size checker covers tracked working files, or files changed in an explicit
Git commit with `--revision COMMIT`, including an initial commit. Exit 3 means a
source-organization review is required; passing never establishes cohesion.
The repository check inspects tracked paths, known workstation coupling and local
documentation links. Both work without jj or Nix. On systems naming Python `python`,
use that executable instead of `python3`.

Test changes should protect current contracts and meaningful regressions. Private
Bash-oracle history is not needed for the retained Rust suite. The manually ignored
[5k measurements](tests/large_ledger.rs) remain available; timings are diagnostic,
not universal CI thresholds. Native macOS/Windows acceptance belongs to the CI
work and is not established merely by running these checks on Linux.

## Emacs checks without Nix

Use Emacs 30.1+ and an isolated directory containing `markdown-mode`, Transient
and `package-lint` with their dependencies. For example, from the checkout root,
this explicitly installs test dependencies into ignored `.check-packages/` using
GNU ELPA and MELPA; it does not load your init or alter your normal package directory.
This installation example uses POSIX shell quoting:

```console
emacs -Q --batch --eval "(progn (require 'package) (setq package-user-dir (expand-file-name \".check-packages\" default-directory) package-install-upgrade-built-in t) (add-to-list 'package-archives '(\"melpa\" . \"https://melpa.org/packages/\") t) (package-refresh-contents) (dolist (pkg '(markdown-mode transient package-lint)) (package-install pkg)))"
```

Allowing built-in package upgrades is necessary because Emacs 30 bundles a
Transient older than the [required version](README.md#requirements).
Build the candidate CLI, then set `ISLED_CHECK_PACKAGE_DIR` to that directory and
run the isolated entry point. In a POSIX shell:

```console
cargo build --locked
ISLED_CHECK_PACKAGE_DIR="$PWD/.check-packages" emacs -Q --batch -l frontends/emacs/test/run-check.el
```

In PowerShell, after installing the same dependencies:

```powershell
cargo build --locked
$env:ISLED_CHECK_PACKAGE_DIR = Join-Path (Get-Location) '.check-packages'
emacs -Q --batch -l frontends/emacs/test/run-check.el
```

For custom build directories, set `ISLED_CHECK_PROGRAM` to the candidate executable.
The default is `target/debug/isled` (`isled.exe` on Windows). Static checks require
Package-lint and register the declared package dependencies; missing dependencies
fail instead of silently skipping lint. Compilation writes only temporary bytecode.
The same entry point runs ERT against the selected CLI using temporary ledgers.
`ISLED_CHECK_PHASE=static` or `tests` supports focused validation and evidence reuse.

Alternatively set `ISLED_CHECK_LOAD_PATH` to explicit dependency directories,
separated by the platform's PATH separator. The optional Nix shell supplies those
packages automatically; `make -C frontends/emacs check` calls the same runner.
See [frontend validation](frontends/emacs/CONTRIBUTING.md#validation) for optional graphical
checks and isolation requirements. Never run this runner through a working daemon.

## Optional tooling

- [Nix environment and source filtering](scripts/README.md#source-boundary).
- [Maintainer jj validation/promotion](agent-docs/dogfooding.md).
- [Rust semantic navigation](agent-docs/rust-navigation.md).
- [Frontend source archive](frontends/emacs/CONTRIBUTING.md#package-archive).

Public documentation and checks must remain independent of those optional workflows
and private state. Keep root metadata, help, skill, code maps and user documentation
aligned when interfaces or requirements change. Report exact checks, skipped coverage
and the final revision in your contribution.
