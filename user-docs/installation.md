# Installation and updates

Release bundles contain the CLI, its matching agent skill and the license.
Install the pair once, then use stable paths that follow your chosen version.

## Install a downloaded release

Download and verify the archive for your platform from
[GitHub releases](https://github.com/cark/isled/releases), then extract it fully.
From the extracted directory:

```console
./isled install
```

In Windows PowerShell, use `.\isled.exe install`. Keep the executable and its
adjacent files together. The installer needs no administrator access.

The installer verifies the complete bundle, stores it under `versions/VERSION/`,
then selects it through one `current` directory link. It prints these full paths:

| Path | Use |
| --- | --- |
| `current/isled` (`isled.exe` on Windows) | Run the selected CLI. |
| `current/skill/` | Register the skill with your agent. |
| `current/skill/SKILL.md` | Link the skill from project instructions. |
| `current/` | Add this directory to PATH. |

The installer does not edit your shell or agent configuration. Run
`isled installation` to show the paths again. Neither command needs a ledger.

## Where it lives

The default is the operating system's per-user data directory:

| Platform | Normal installation root |
| --- | --- |
| Linux | `$XDG_DATA_HOME/isled`, or `~/.local/share/isled` |
| macOS | `~/Library/Application Support/isled` |
| Windows | `%LOCALAPPDATA%\isled` |

To choose another location:

```console
./isled install --directory /path/to/isled
isled installation --directory /path/to/isled
```

Relative paths are relative to your current directory. `--root` selects a ledger
and cannot be used for these commands. Storage must be local; its root, version
directories and bundle files must not be links. The managed `current` link is
created by the installer.

Emacs uses the same default. Customize `isled-cli-directory` to override it.
After the first install, Emacs remembers the root returned by the CLI. If you
later change your platform data location, explicitly set that customization to
the new location. Old Emacs caches remain untouched for rollback.

## Upgrade or roll back

Download the new release, extract it and run its `install` command. Your existing
`current` paths then select both the new executable and its skill. Previous
versions stay in `versions/`; installation does not prune them.

To roll back, run the executable inside the older `versions/VERSION/` directory
with `install`, using the same `--directory` if you chose custom storage. You can
also rerun the installer from an older extracted archive. `current` follows your
selection, even when that selects a lower version.

For a fixed setup, use the executable and skill under the same `versions/VERSION/`
directory. Emacs always runs its exact compatible version, so a separate CLI
upgrade or rollback cannot redirect an already prepared frontend. Explicit
`M-x isled-setup-cli` selects the frontend's version again.

After switching versions, reload the skill or start a new agent conversation.
An agent that already loaded the old instructions cannot pick up new ones
just because the files changed.

## Failed or interrupted setup

Missing or damaged bundle files stop installation before activation. Existing
version directories are verified and reused, never overwritten. If one is
damaged, inspect it and move that version aside before retrying a fresh download;
keep other versions intact.

Unix switches `current` with one rename. Windows uses a directory junction and
two renames, with a temporary backup of the previous link. It needs neither
administrator rights nor Developer Mode. An interruption between the renames
can leave `current` briefly absent; rerun an extracted or versioned executable's
`install` command to recover. Do not replace `current` with your own directory.

## Cargo and Nix

Cargo installations stay manual. Use the complete `skills/isled/` directory from
the same source checkout as your executable. Nix packages the skill under
`share/isled/skill/` in its output and owns updates. These routes do not use
`isled install`; the managed installer never replaces their executables.

## Structured output

Integrations can retrieve the same paths without parsing terminal prose.
`isled install --json` and `isled installation --json` return schema 1:

| Field | Meaning |
| --- | --- |
| `schema_version` | `1` |
| `root` | Absolute installation root. |
| `version` | Selected bundle version, or `null` when none is installed. |
| `program` | Exact versioned executable, or `null` without a selection. |
| `executable`, `skill`, `skill_file`, `path_directory` | Absolute paths through `current`, kept unresolved. |

Inspection without an installation reports the proposed paths without creating
directories. Invalid existing installation state is an error, not an empty result.
Both commands exit 0 on success and 1 on failure; errors go to stderr.

The installer described here starts with 0.33.0. Published 0.32.0 archives keep
their original layout.
