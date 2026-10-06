# Package manager recipes

These recipes install Isled directly from GitHub. The `release` branch follows
frontend versions whose compatible CLI is already published; `v0.35.0` selects
this release. On first use, the frontend automatically downloads its
matching CLI.

You can also follow `main`: an unreleased frontend can keep the same published
CLI pin. To test an unpublished CLI change, use the
[source development setup](CONTRIBUTING.md#source-development-setup).

All managers install the same Lisp libraries and declared dependencies. The
frontend's `isled-required-cli-version` selects its compatible CLI; a package
manager's version number does not.

An unreleased frontend can retain that pin only while its required CLI behavior
remains compatible. A wire change requires a new compatible CLI pin and a paired
release. Until that release is published, use the matching source build described
in [source development setup](CONTRIBUTING.md#source-development-setup).

## MELPA

Isled is not listed on MELPA yet. Use one of the GitHub recipes below or the
[release archive](README.md#from-the-release-archive).

Package.el users need `package-install-upgrade-built-in` enabled so Emacs 30's
older bundled Transient can be upgraded.

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

For a fixed release, replace `:branch "release"` with `:tag "v0.35.0"`.
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
`:rev "v0.35.0"` or `:rev "FULL-COMMIT-ID"` to fix the revision. For development,
use `:branch "main" :rev :newest`.

For `package-vc-install`, pass the [plain recipe](recipes/package-vc.el) as its
first argument and an optional tag or commit as its second argument. Omitting
that second argument follows the branch tip. `.elpaignore` excludes contributor
scripts, recipes, tests and demos from byte compilation of the cloned repository.
See the Emacs Info node `(emacs) Fetching Package Sources` and
`(use-package) Install package from VC`.

## CLI setup and updates

Your package manager installs the Lisp code, dependencies, autoloads and bytecode.
It needs no Isled-specific install hook. Loading or compiling the package does
not download or run a CLI.

The first Isled command that needs it downloads the frontend's exact compatible
CLI and matching agent skill. They live outside package directories, so package
rebuilds leave them intact. Setup shows their stable `current` paths; retrieve
them again with `M-x isled-show-installation`.

A frontend update reuses its CLI offline while the pin is unchanged. A new pin
needs its published release, or an explicit matching source build. Work state,
timers and queue ordering are available from 0.35.0.

See [setup and recovery](user-guide.md#cli-setup-and-upgrades) for cancellation,
upgrades and separately installed executables.

<a id="shared-installer-boundary"></a>
<a id="reproduce-the-packaging-checks"></a>
<a id="submission-handoff"></a>

## For contributors

Recipe construction, installer acceptance and archive submission live in
[package installation and release checks](CONTRIBUTING.md#package-installation-and-release-checks).
