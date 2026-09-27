# Isled — a personal issue ledger

Isled keeps a project's issues in local Markdown files. Use it to record concerns,
collect evidence, track dependencies, and preserve the reasoning behind decisions.
A command-line interface manages the ledger; an optional Emacs frontend lets you
browse, add, edit, close, and follow issues without leaving your editor.

Each issue has a stable ID and its own file under `.issues/`. Markdown is the
source of truth; SQLite supplies a disposable query cache. The ledger is local
and ignored by Git, so cloning a project's source does not copy its issues.

## Installation

From a source checkout, with the [build requirements](#requirements) installed:

```console
cargo install --path . --locked
```

Ensure Cargo's installation directory (normally `~/.cargo/bin`) is on `PATH`.
Run `isled --help` to see the available commands.

## Quick start

In a new project directory:

```console
isled init
isled add 'Explain the backup procedure' --kind maintenance 'Document how to restore the project from a backup.'
isled list --with-path
isled show 0001
```

`init` creates `.issues/` and adds it to `.gitignore`. `add` creates an issue and
prints its ID; the first issue in a fresh ledger is `0001`. Commands discover the
nearest ledger in the current directory or its ancestors. Use `--root PATH` to
select a project explicitly.

See the [user guide](user-docs/README.md) for filtering, dependencies, evidence,
and closure, or use `isled help COMMAND` for exact command syntax and examples.

## Emacs frontend

Follow the [frontend setup guide](frontends/emacs/README.md#getting-started) to
install the package or load it from a checkout. Open a project's issue view with
`M-x isled`; `C-x p i` chooses a project when that binding is available.
Use `M-x isled-open-directory` to choose another local directory.
Issue rows show dependency gutters; `f` filters and `d` reverses direction.
The guide covers [dependency selection and filtering](frontends/emacs/README.md#dependency-graph-view),
filtering, navigation, appearance, and key customization.

## Requirements

- **CLI:** no Bash, Perl, or separate SQLite runtime is required. Cached queries
  need a writable `.issues/.cache/` directory.
- **Build:** Rust 1.97 or newer, Cargo, and a C compiler for bundled SQLite.
  [Cargo.toml](Cargo.toml) declares the Rust minimum.
- **Emacs frontend:** Emacs 30.1 or newer, `markdown-mode` 2.6 or newer, and
  Transient 0.8.0 or newer, as declared in the
  [package metadata](frontends/emacs/isled.el). For the current source workflow,
  explicitly configure the matching CLI as described in
  [frontend installation](frontends/emacs/README.md#installation). Managed setup
  requires built-in TLS and zlib support in Emacs; public binaries are not yet
  published. When loading source directly, install these
  dependencies yourself; package archive installation uses the declared dependencies.

Prebuilt CLI releases target x86-64 Linux 5.4+, x86-64 Windows 10+, and Apple
Silicon macOS 15+. The oldest Linux and Windows versions are compatibility
targets, not direct test environments: native staging uses Ubuntu 24.04,
Windows Server 2025 and macOS 15. The [release checks](scripts/releasing.md#native-staging)
cover prepared artifacts; public downloads become available when the first
release is published. Other platforms can use a source build.

## Development environment

The optional pinned Nix environment provides the build and development tools.
Enter it once with direnv or the filtered wrapper, then run checks inside it:

```console
scripts/dev.sh
cargo test --locked
```

For one command, use `scripts/dev.sh -c cargo test --locked`.
[Contributing](CONTRIBUTING.md) covers Git-only builds, checks and portable Emacs validation;
[script documentation](scripts/README.md) covers build helpers and optional tooling.

## License

Isled is licensed under the [MIT License](LICENSE).
Copyright (c) 2026 Sacha De Vos.
