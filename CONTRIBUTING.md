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
python3 -B scripts/test-release-staging.py
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

## GitHub CI

Ordinary branch and tag pushes do not start hosted checks. Run the applicable
[local validation](#validation) before pushing. The [CI workflow](.github/workflows/ci.yml)
provides one Linux job for pull requests and the full native matrix for release
preparation:

| Event | Hosted checks |
| --- | --- |
| Pull request | Linux source, frontend and published-CLI checks. |
| Push to `release-artifacts` | All three CI platforms, plus the separate [release staging workflow](scripts/releasing.md#native-staging). |
| Manual CI run | All three CI platforms. Use this for an earlier platform check or live publication checks. |

Jobs use Rust 1.97.1, Emacs 30.2 from the existing Nixpkgs pin on Linux/macOS,
and Emacs 30.1 on Windows. The
[shared editor setup](.github/actions/setup-emacs/action.yml) checks built-in
TLS and zlib support before installation tests:

| Runner | CLI target |
| --- | --- |
| `ubuntu-24.04` | `x86_64-unknown-linux-musl` |
| `macos-15` (Apple Silicon) | `aarch64-apple-darwin` |
| `windows-latest` (Windows Server) | `x86_64-pc-windows-msvc` |

Full Windows/macOS acceptance happens during release preparation. A passing
Linux PR check alone does not establish those platforms' compatibility.

Each job runs the contributor Python checks, Rust tests and isolated Emacs
static/ERT checks against the CLI it builds. Linux also runs formatting and
Clippy, builds bundled SQLite with musl and a generic x86-64 CPU baseline, and
rejects an executable requiring a dynamic loader or shared libraries. macOS uses
deployment target 15.0 for Rust and bundled C code. Actions are pinned to commits;
the logs identify the actual runner, compiler, Emacs and resolved package versions.

These jobs exercise newer hosted systems. They do not test Windows 10 or Linux
kernel 5.4 directly, nor do batch Emacs checks establish graphical behavior.
Invalid-byte filename recovery is exercised on Linux; the native macOS filesystem
rejects those fixtures during creation. Unix permission/symlink tests retain their
platform guards.
Keep these gaps separate from the [planned compatibility targets](agent-docs/decisions.md#public-installation-direction-planned).
Except on `release-artifacts`, each job also downloads the frontend's exact published CLI pin anonymously,
checks the release assets, exercises managed first use and offline reuse, then
runs the frontend suite against that executable. A missing or incompatible
release fails the check. Source-built tests still run separately. Release preparation
tests the new pin against staged assets; public delivery is checked after publication.

To reproduce a target locally, install Rust 1.97.1 with that target, set
`CARGO_BUILD_TARGET`, then run `cargo test --locked --no-fail-fast`
and `cargo build --locked`. For Linux musl, install `musl-tools` and use
`CC_x86_64_unknown_linux_musl=musl-gcc`,
`CFLAGS_x86_64_unknown_linux_musl="-march=x86-64 -mtune=generic"` and
`RUSTFLAGS="-C target-cpu=x86-64"`. Follow the Emacs setup below with
`ISLED_CHECK_PROGRAM` pointing at `target/TARGET/debug/isled` (`isled.exe` on Windows).
Use a native machine to establish native acceptance; record actual run results
and any skips when reporting validation.

## Emacs checks without Nix

Use Emacs 30.1+ and an isolated directory containing `markdown-mode`, Transient
and `package-lint` with their dependencies. The same explicit setup used by CI
installs stable GNU/NonGNU ELPA packages and logs their resolved versions.
From the checkout root, in a POSIX shell:

```console
export ISLED_CHECK_PACKAGE_DIR="$PWD/.check-packages"
emacs -Q --batch -l frontends/emacs/test/install-packages.el
```

The setup requires an explicit package directory; it does not load your init or
alter your normal packages. It allows built-in upgrades because Emacs 30 bundles
a Transient older than the [required version](README.md#requirements).
This isolated setup downloads packages over HTTPS and disables package signature
checks so contributors and CI do not need GnuPG. It does not change signature
settings in a normal Emacs session.
Build the candidate CLI, then set `ISLED_CHECK_PACKAGE_DIR` to that directory and
run the isolated entry point. In a POSIX shell:

```console
cargo build --locked
ISLED_CHECK_PACKAGE_DIR="$PWD/.check-packages" emacs -Q --batch -l frontends/emacs/test/run-check.el
```

In PowerShell:

```powershell
$env:ISLED_CHECK_PACKAGE_DIR = Join-Path (Get-Location) '.check-packages'
emacs -Q --batch -l frontends/emacs/test/install-packages.el
cargo build --locked
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
- [Versioned release staging](scripts/releasing.md).
- [Frontend source archive](frontends/emacs/CONTRIBUTING.md#package-archive).

Public documentation and checks must remain independent of those optional workflows
and private state. Keep root metadata, help, skill, code maps and user documentation
aligned when interfaces or requirements change. Report exact checks, skipped coverage
and the final revision in your contribution.
