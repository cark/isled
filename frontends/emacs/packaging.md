# Package manager recipes

These recipes prepare the first packaged release. Isled is not yet on MELPA,
and the public `release` branch and release tags will be created during
publication. For current source use, select `main` and build the CLI from the
same checkout using the [installation guide](README.md#installation).
Automatic CLI setup is implemented; public downloads await the first release.

All managers install the same Lisp libraries and declared dependencies. The
frontend's `isled-required-cli-version` selects its compatible CLI; a package
manager's version number does not. An unreleased frontend can retain that pin.

## MELPA

The [recipe](recipes/melpa/isled) follows `release`, which advances only after
the matching CLI release is publicly available. It selects the frontend libraries
and root MIT license. MELPA generates the package descriptor from `isled.el`.
There is no committed `isled-pkg.el` or package-specific build command.

The recipe omits tests, demos, contributor tools and Markdown documentation,
following [MELPA's packaging guidance](https://github.com/melpa/melpa/blob/master/CONTRIBUTING.org).
The standalone source tar retains its guides and images.

After archive acceptance, normal `package-install` or `use-package :ensure`
will install Isled. Emacs 30's bundled Transient is older than Isled requires;
package.el users need `package-install-upgrade-built-in` enabled.

## Elpaca

With Elpaca's usual use-package integration enabled:

```emacs-lisp
(use-package transient :ensure t)
(use-package isled
  :ensure (:host github :repo "cark/isled" :branch "release"
           :main "frontends/emacs/isled.el"
           :files ("frontends/emacs/isled*.el" "LICENSE")))
```

The explicit Transient declaration upgrades the bundled copy. The matching
[plain recipe](recipes/elpaca.el) also works with the `elpaca` macro.

For a fixed release, replace `:branch "release"` with `:tag "v0.32.0"`.
For an exact commit, use `:ref "FULL-COMMIT-ID"` and `:depth nil` so an older
commit remains reachable. To follow development, use `:branch "main"`.
See [Elpaca's recipe reference](https://github.com/progfolio/elpaca/blob/master/doc/manual.md#recipes).

## straight.el

With straight.el and its usual use-package integration enabled:

```emacs-lisp
(use-package transient :straight t)
(use-package isled
  :straight (isled :type git :host github :repo "cark/isled"
                   :branch "release"
                   :files ("frontends/emacs/isled*.el" "LICENSE")))
```

The [plain recipe](recipes/straight.el) also works with `straight-use-package`.
Use `:branch "main"` to follow development. For a fixed tag or commit, check
out that revision in straight's Isled repository and use
`straight-freeze-versions`; restoring the lockfile with `straight-thaw-versions`
restores the recorded commit. straight.el does not provide a recipe `:commit`
key. Resolve a release tag to its commit before freezing it.
See [straight.el's recipe and lockfile reference](https://github.com/radian-software/straight.el#the-recipe-format).

## Built-in package-vc

On Emacs 30.1 or newer:

```emacs-lisp
(setq package-install-upgrade-built-in t)
(use-package isled
  :vc (:url "https://github.com/cark/isled.git"
       :branch "release" :rev :newest
       :lisp-dir "frontends/emacs" :main-file "isled.el"))
```

`:rev :newest` follows the branch tip. Without it, use-package normally selects
the most recent version-header change, which can omit later fixes. Use
`:rev "v0.32.0"` or `:rev "FULL-COMMIT-ID"` to fix the revision. For development,
use `:branch "main" :rev :newest`.

For `package-vc-install`, pass the [plain recipe](recipes/package-vc.el) as its
first argument and an optional tag or commit as its second argument. Omitting
that second argument follows the branch tip. `.elpaignore` excludes contributor
scripts, recipes, tests and demos from byte compilation of the cloned repository.
See the Emacs Info node `(emacs) Fetching Package Sources` and
`(use-package) Install package from VC`.

## Shared installer boundary

Package managers own fetching Lisp, dependencies, autoloads and compilation.
They need no Isled-specific download or install hooks. Loading and compiling
the package must not fetch or run its CLI.

The installer runs on the first Isled command that needs the CLI,
using the frontend's explicit pin. It stores binaries outside package
directories and preserves them when a manager rebuilds or replaces the Lisp
package. It works without inspecting Git state, package-manager metadata
or archive version numbers. The [release contract](../../agent-docs/decisions.md#public-installation-direction-planned)
owns consent, integrity, upgrade and recovery behavior.

The downloader allows HTTPS only, with redirects limited to GitHub's release
delivery hosts. Metadata is limited to 256 KiB and archive/executable sizes to
128 MiB: generous headroom for the current few-megabyte binaries, with finite
limits for unexpected responses. Each asset gets two minutes to download;
executable identity checks get ten seconds. Both waits are cancellable. Hashing
and decompression use Emacs facilities; extraction accepts only the two regular
members written by release staging and retains the license beside the executable.

The [user guide](user-guide.md#cli-setup-and-upgrades) explains setup commands,
consent, cache recovery and explicit release/development executables.

To test an installed package against real staged binaries before publication:

```console
python3 scripts/package-emacs.py --output /path/to/isled-candidate.tar
python3 scripts/check-cli-installer.py \
  --package /path/to/isled-candidate.tar --artifacts /path/to/release-candidate \
  --dependencies /path/to/check-packages --output /path/to/new-installer-check
```

This verifies the complete staged set and serves it on loopback. Each scenario
starts a fresh batch editor with an empty tool PATH and replaces its package
directory. Checks cover first use, declined/canceled setup, missing assets,
offline cache reuse, explicit executables and unsupported platforms.
Add `--upgrade /path/to/upgrade-candidate` for two real versioned builds: corrupt
and interrupted upgrade downloads, retry, upgrade with the old CLI still running,
frontend rollback and an explicit version mismatch. The
[native staging workflow](../../scripts/releasing.md#native-staging) builds this
second candidate strictly for acceptance, with no version change to the release.
Only the test's request destination changes. Production HTTPS/redirect policy,
hash checks, extraction, identity checks and activation remain enabled. This
fixture establishes acceptance only on the native host where it runs; public
endpoint checks remain part of publication. Logs and the JSON receipt record
each case, the source and package identities, editor version and platform.
Use `--live` instead of the upgrade fixture to check public HTTPS delivery with
no URL substitution. It covers consent, installation, offline package replacement,
explicit executables and unsupported-platform handling.
`check-published-cli.py` retrieves and verifies the complete pinned release, runs
those live cases, then runs the frontend suite against the managed executable;
native CI uses this alongside the source-built checks.

## Reproduce the packaging checks

The check uses Python 3.9+, Git, Emacs 30.1+ and three external tool checkouts:
[MELPA](https://github.com/melpa/melpa),
[Elpaca](https://github.com/progfolio/elpaca) and
[straight.el](https://github.com/radian-software/straight.el).
Record their exact revisions; the output receipt does this automatically.
Git-based managers resolve their normal dependencies over the network. The
archive and package-vc checks use an explicit isolated directory populated by
the [contributor dependency setup](../../CONTRIBUTING.md#emacs-checks-without-nix).

Start from a committed or snapshotted Isled candidate, with the complete verified
artifact set from [release staging](../../scripts/releasing.md):

```console
python3 -B scripts/check-package-recipes.py \
  --revision COMMIT --artifacts /path/to/release-candidate \
  --dependencies /path/to/check-packages \
  --melpa /path/to/melpa --elpaca /path/to/elpaca \
  --straight /path/to/straight.el --output /path/to/new-check-directory
```

Use straight.el's `develop` branch when preparing its checkout. The output
directory must be new. Each case gets a separate editor configuration and package
directory; no working daemon or real ledger is used. The check creates local
release/tag refs and an unreleased frontend revision in a disposable Git
repository. It neither publishes refs nor changes the source checkout.

Checks cover MELPA package construction, direct Git branch/tag/commit selection,
all runtime libraries and bytecode, dependency versions, load-time side effects,
and the CLI pin's mapping to real verified artifacts. They also install an
unreleased frontend with a different Lisp version and the same CLI pin.
Add `--published` to check the actual public `release`, tag, commit and `main`
refs anonymously; omit it to keep using disposable local refs. This is a focused
package-manager check on one host, not an OS-by-manager matrix or acceptance of
CLI provisioning. Logs and JSON receipts remain in the
output directory; `--managers` and `--selectors` allow focused reruns.

## Submission handoff

The initial packaged release uses the direct Git routes above. Once the pinned
CLI assets and distribution refs are public and verified, users can install
through their package manager without waiting for MELPA listing.

The [MELPA submission draft](recipes/melpa-submission.md) is prepared locally.
Before sending it, confirm the public release assets and `release` branch are
available and that the maintainer has reviewed the package and submission.
MELPA's [PR template](https://github.com/melpa/melpa/blob/master/.github/PULL_REQUEST_TEMPLATE.md)
also requires at least one month of public repository history. Keep that
submission condition separate from local recipe acceptance and the first release.

Runtime files retain their MIT SPDX headers, author credit and `Assisted-by`
attribution. Attribution identifies current Codex assistance; it is not a complete
historical model inventory. Recheck MELPA's current requirements and package
lint when submitting. Archive acceptance remains MELPA's decision.
