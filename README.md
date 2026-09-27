# Isled — a personal issue ledger

Keep project concerns, evidence and decisions beyond the current conversation.
Isled stores issues as local Markdown files, with a CLI to manage them and an
[Emacs frontend](frontends/emacs/README.md) to explore and edit them.

Coding agents are the first audience. People can use the same ledger from the
terminal or work visually in Emacs: follow a dependency, read the reasoning,
and pick up where the last session stopped.

[Get started](#installation) · [Agent skill](#use-it-with-an-agent) ·
[Emacs tour](frontends/emacs/README.md) · [User guide](user-docs/README.md)

## What it keeps for you

- **Context:** what needs attention and why it matters.
- **Dependencies:** what is ready and what is waiting on other work.
- **Evidence and outcomes:** what was checked and how the concern was resolved.

Each issue has a stable ID and a file under `.issues/`. Markdown is the source
of truth; SQLite is a disposable query cache. The ledger stays local and is
ignored by Git, so cloning the source does not copy private project notes.

## Use it with an agent

The included [Isled skill](skills/isled/SKILL.md) teaches an agent to find the
ledger, inspect issues, follow dependencies and record progress through the CLI.
It also covers when to ask before changing or closing an issue.

The installer supplies the matching skill with the CLI. Run `isled installation`,
or `M-x isled-show-installation` in Emacs, to get its full `current/skill/` path.
Use that directory in your agent's skill setup, or link its `SKILL.md` from your
project instructions. Keep the reference files with it.

These paths follow upgrades and rollbacks. An agent that has already loaded the
skill may need to reload it or start a new conversation. The skill covers using
Isled; [contributor guidance](CONTRIBUTING.md) covers working on Isled itself.

## Emacs frontend

Browse a dependency hierarchy, filter as you type, and create or edit issues
in a structured draft. The view refreshes when files change, including changes
made by an agent through the CLI.

[See the demos and install the package](frontends/emacs/README.md).
The frontend offers to download its matching CLI on first use.

## Installation

**In Emacs:** use the [package installation guide](frontends/emacs/README.md#installation).
No Rust compiler or manual CLI setup is needed.

**For the terminal or an agent:** get the archive for your platform from the
[release page](https://github.com/cark/isled/releases). Verify it against the
supplied SHA-256 checksums and extract the whole archive. From its directory, run:

```console
./isled install
```

On Windows, use `.\isled.exe install`. The installer shows the full executable
and skill paths through `current`, plus the directory to add to PATH. No
administrator access is needed. Run `isled installation` to find these paths again.

To upgrade, download the new archive and run its installer. Previous versions
stay available for rollback. See [installation and updates](user-docs/installation.md)
for storage locations, custom directories and pinned paths.

**From source:** install the [build requirements](#requirements), then run
`cargo install --path . --locked` in a checkout. Cargo's binary directory,
normally `~/.cargo/bin`, must be on `PATH`. Use `skills/isled/` from that checkout
for the matching skill. Nix supplies it at `share/isled/skill/` in the package
output and manages its own updates.

## Quick start

From your project directory:

```console
isled init
isled add 'Explain the backup procedure' --kind maintenance 'Document how to restore the project from a backup.'
isled list --with-path
isled show 0001
```

`init` creates `.issues/` and adds it to `.gitignore`. `add` prints the new ID;
the first issue in a fresh ledger is `0001`. Commands find the nearest ledger
in the current directory or its parents. Use `--root PATH` to choose one explicitly.

Continue with the [user guide](user-docs/README.md), or run
`isled help COMMAND` for exact syntax and examples.

## Requirements

| What you use | What you need |
| --- | --- |
| Prebuilt CLI | No separate SQLite or C runtime. Cached queries need a writable `.issues/.cache/`. |
| Emacs frontend | Emacs 30.1+ with built-in TLS and zlib; `markdown-mode` 2.6+ and Transient 0.8.0+. The package manager installs Lisp dependencies. |
| Source build | Rust 1.97+, Cargo and a C compiler for bundled SQLite. |

Prebuilt releases target **x86-64 Linux 5.4+**, **x86-64 Windows 10+** and
**Apple Silicon macOS 15+**. Other platforms can use a source build.

Native CI checks installation and recovery on Ubuntu 24.04, Windows Server 2025
and macOS 15. The new shared installer still needs native release acceptance.
Linux 5.4 and Windows 10 are compatibility targets, not direct test environments.
See the [release checks](scripts/releasing.md#native-staging).

The Emacs-managed macOS installation works with Gatekeeper enabled, without
publisher signing or notarization. Standalone downloads with browser quarantine
on macOS, and desktop Windows SmartScreen, remain untested.

## Development environment

Start with [Contributing](CONTRIBUTING.md) for builds and checks. The optional
[pinned Nix environment](scripts/README.md#source-boundary) is available through
`scripts/dev.sh` or direnv.

## AI use

Isled is developed with substantial help from AI coding agents, including its
code, tests and documentation.

<a id="support"></a>

## Support and license

Report bugs and suggest improvements through [GitHub issues](https://github.com/cark/isled/issues).
Include your OS, relevant Emacs/CLI versions and a small reproduction with
sample data. Keep private ledgers out of reports.

<a id="license"></a>

[MIT License](LICENSE). Copyright (c) 2026 Sacha De Vos.
