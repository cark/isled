# Contributor scripts

Core commands live in [Contributing](../CONTRIBUTING.md). The portable Python
checks use Git and the standard library; product runtime needs none of the tools
in this directory. Python 3.9+ supports the core check/archive entry points.

## Portable checks and packaging

- `check-coding-standards.py` checks tracked working files or `--revision COMMIT`,
  including an initial commit. Source size is a review signal, not a cohesion
  verdict. Exit 3 requires organization review. Its `.sh` wrapper supports
  optional jj `--revision @` selection; ordinary contributors use Python directly.
- `check-repository.py` checks tracked private/generated paths, concrete workstation
  paths, symlinks and local documentation links/anchors. Fenced examples and the
  one synthetic header-identity home-path fixture are scoped exceptions. It does
  not establish that arbitrary prose is appropriate for publication.
- `repository_files.py` supplies Git tracked-file/revision selection for those checks.
- `test-contributor-checks.py` exercises the checks in disposable Git repositories,
  including initial commits, private files, missing links and source archives.
- `package-emacs.py` produces the frontend source tar with its user/contributor guides, demo GIFs and license, using
  Python's portable tar writer. It takes the version from `isled-pkg.el` and does
  not copy compiled output or tests. `make -C frontends/emacs package` is a wrapper.

## Optional environment and maintainer tools

These tools have narrower requirements than the CLI and portable contributor
checks. They are not gates every contributor must run.

- `dev.sh` enters the filtered pinned Nix shell; `-c COMMAND` runs one command.
  `nix-source.sh` selects shell or Rust-package inputs as described below.
  `test-nix-source.sh` and `test-dev-environment.py` exercise that boundary using
  disposable fixtures and real Nix/direnv. Run them when changing the boundary.
- `start-agent-lsp.sh` and `check-agent-lsp.py` provide optional pinned semantic
  tooling and its bounded smoke check. See [Rust navigation](../agent-docs/rust-navigation.md).
- `dogfood-release.sh`, `release_inputs.py`, `release_evidence.py` and
  `release_validation.py` provide optional jj/Linux artifact validation and local
  selection. [Dogfooding](../agent-docs/dogfooding.md) owns requirements, commands,
  receipts and rollback. `test-dogfood-release.sh` and `test-release-validation.py`
  test that lifecycle without touching a live release store.
- `private-graphical-emacs.py` runs a bounded serverless graphical check on an owned
  Linux Xvfb display, using private state and process-identity checks. It requires
  Xvfb and Emacs with the scenario's explicit dependencies. Its process-lifecycle
  regressions are in `test-private-graphical-emacs.py`; product assertions stay in
  frontend test scripts. [Frontend validation](../frontends/emacs/CONTRIBUTING.md#private-graphical-checks)
  owns startup, result and cleanup requirements.
- `emacs-preview.py` starts an interactive exact-jj-candidate preview on Linux with
  Bubblewrap, private HOME/XDG/server state and a disposable ledger. A personal
  profile is optional and must be explicitly selected. The host/configuration are
  read-only and networking is disabled. Use `start --candidate EXACT_COMMIT
  --profile vanilla`, `list`, and `close PREVIEW_ID`; `--help` explains the optional
  profile, executable and state-root parameters. Successful startup verifies
  dependencies, loaded source paths and an asynchronous view/refresh before
  returning. Close only recorded, identity-verified preview processes.
  `test-emacs-preview.py` and `test-emacs-preview-graphical.el` own helper coverage.

The Nix shell includes the Rust/C tools, Emacs validation dependencies, Python,
Git/jj and optional navigation tools. It does not install the frontend or configure
an agent client. Private receipts, transcripts, ledgers and deployment state stay
untracked and are not required to reproduce public contributor checks.

## Source boundary

Enter the pinned development environment through direnv or `scripts/dev.sh`, then
reuse it for Cargo, Make and helper commands. For a one-off command use
`scripts/dev.sh -c COMMAND`. Refresh when flake/lock/setup inputs change or the
established environment is stale; verify its workspace and pinned tools before reuse.

This section owns Isled's optional Nix inputs and commands.
The [contributor guide](../CONTRIBUTING.md) supplies a route without Nix. Never pass the raw checkout to
Nix: no bare `nix develop`, `nix develop .`, `nix flake check`, `path:$PWD` or `.#default`.
For a package check use `nix flake check "path:$(scripts/nix-source.sh)"`.

The Rust package source currently contains only `Cargo.toml`, `Cargo.lock`,
`src/`, and `tests/`. Keep that list aligned with real build and test inputs.
`scripts/nix-source.sh` owns two initial snapshot scopes within the same flake.
Its default includes package inputs plus `flake.nix` and `flake.lock`; use
`path:$(scripts/nix-source.sh)` for package builds and flake checks.
Its `--shell` mode includes only `flake.nix` and `flake.lock`; use
`path:$(scripts/nix-source.sh --shell)` for development shells. Direnv,
`scripts/dev.sh`, and the agent-lsp launcher select this mode automatically.
The shell depends on tool definitions and pins, not Rust/Cargo/test contents.
Do not add package source to shell inputs merely because both outputs share a
flake. Add any future imported shell definitions to its allowlist and direnv's
watch list together. Watch mutable checkout definitions before `use flake`, so
real environment changes still reload automatically. Stop if source filtering
fails; never pass an empty or unfiltered reference to Nix as a fallback.
Plain `nix develop` or `nix flake check` bypasses this explicit input boundary.
In a Git checkout, ordinary local Git flake references use
tracked files, but still include application source; explicit `path:` checkout
references bypass Git filtering altogether. Keep the wrappers for stable shell
inputs and for workspaces that may not expose Git metadata. Use `scripts/dev.sh -c COMMAND` for a one-off command.
Run `scripts/test-nix-source.sh` and `python3 scripts/test-dev-environment.py`
when changing this boundary: source edits must keep the shell/cache stable,
package inputs must invalidate package derivations, and tool-definition edits
must refresh the environment without using nix-direnv's stale-shell fallback.
The flake rejects source trees containing known local-state directories with
an actionable error. This guard runs after Nix copies its input: it exposes a
bypass but cannot prevent that first copy. The helper prevents the copy.
The helper includes current on-disk source, including new files under the allowed
trees; it does not export an older revision. Dependency updates edit the checkout's
lock file, not the immutable filtered snapshot. Inspect the resulting inputs
before refreshing the environment. Investigate unexpected store growth read-only
and report it; cleanup is a separate owner-authorized action.
