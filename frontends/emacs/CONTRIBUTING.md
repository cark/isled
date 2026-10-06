# Contributing to the Emacs frontend

For installation and daily use, start with the [README](README.md). The
[user guide](user-guide.md) owns interaction and customization; the root
[contributor guide](../../CONTRIBUTING.md) owns shared setup and checks.

- [Validation and isolation](#validation)
- [Building a package archive](#package-archive)
- [Package manager recipes](packaging.md) and [release checks](#package-installation-and-release-checks)
- [Code map](#code-map)
- [Loading and rendering](#bounded-loading)
- [Recording README demos](#recording-readme-demos)

## Source development setup

Build the CLI from the same checkout as the frontend:

```console
cargo build --locked
```

Install the [frontend dependencies](README.md#installation), then point Emacs
at this checkout's executable and opt into its development version identity:

```emacs-lisp
(setq isled-program (expand-file-name "~/src/isled/target/debug/isled")
      isled-use-development-cli t)
```

On Windows, use the path to `isled.exe`. Load the frontend with the
[source configuration example](user-guide.md#local-configuration), or build and
install the [package archive](#package-archive). The explicit executable is
checked against the frontend's CLI pin and is never replaced by a download.
`cargo install --path . --locked` is another option; configure its installed path.

## Validation

The [resettable relation recovery demo](test/fixtures/relation-warnings/README.md)
owns baseline records, reset commands, and interactive checks. Its retained live
copy belongs under ignored `.dogfood/relation-warning-demo/`; never use the
baseline itself or a real ledger for destructive recovery tests.

The [5k Rust and frontend benchmarks](../../tests/large_ledger.rs) retain synthetic
fixtures for timing and memory investigations. Separate CLI startup, summary/detail
transfer, decoding, formatting and scrolling costs. Compare compiled frontend code
on ordinary and difficult DAGs, retaining the documented width limitations. The
[loading rationale](../../agent-docs/decisions.md#frontend-architecture-and-presentation)
explains the implemented boundary; timings on one machine do not establish native
support or universal latency bounds.
The focused fold regression inspects displayed glyphs after opening and folding
neighboring bodies, including wrapped text, then scrolls every heading and
connector through the top row in both directions:

```sh
python3 scripts/private-graphical-emacs.py \
  --script frontends/emacs/test/graph-fold-graphical.el \
  --load-path frontends/emacs --load-path frontends/emacs/test
```

The [portable contributor setup](../../CONTRIBUTING.md#emacs-checks-without-nix)
provides explicit package directories and the candidate CLI. Its
[`install-packages.el`](test/install-packages.el) entry point explicitly installs
check dependencies into `ISLED_CHECK_PACKAGE_DIR`; ordinary validation does not
download packages. Run from the root:

```console
emacs -Q --batch -l frontends/emacs/test/run-check.el
```

Set `ISLED_CHECK_PACKAGE_DIR` to an isolated package directory, or use explicit
`ISLED_CHECK_LOAD_PATH` directories. The optional Nix shell supplies dependencies;
`make -C frontends/emacs check` calls the same runner. Use `ISLED_CHECK_PROGRAM`
for a custom candidate executable and `ISLED_CHECK_PHASE=static` or `tests` for
focused checks. The default runs both phases, with all required dependencies.

Checks balance parentheses, compile into temporary directories with warnings as
errors, run Checkdoc and Package-lint without a homepage exemption, and execute
ERT including temporary-ledger CLI integration. Missing lint/dependencies fail;
no user init is loaded and no bytecode is installed beside source. The
[validation-scope policy](../../agent-docs/workflow.md#validation-scope) governs
proportionality and evidence reuse. Add a second compiled/source pass only for a
concrete loading or macro-expansion risk.

Automated checks never contact a working Emacs daemon. A separately authorized
live review must preserve windows, buffers and unsaved work; a test failure never
authorizes restarting or terminating that daemon.

### Private graphical checks

When correctness depends on real display geometry or completion interaction,
use a separate `emacs -Q` on an owned private X display. The batch requirement
above applies to ordinary automated checks; it does not require forcing graphical
initialization through batch mode. Never connect these tests to the working
daemon or reuse its environment, sockets or display.

Choose scenarios that exercise the changed behavior through the real command
loop and relevant configuration. Reuse that evidence at review/integration while
its inputs remain valid; do not automatically add every configuration, frame,
source/bytecode or repeated-run combination. Keep product assertions in the
scenario script and lifecycle checks in the shared runner. Repair or extend the
runner only for a demonstrated gap in that boundary.

Validate test-script syntax before launch. Every runner must own and record its
child processes, use unique temporary paths, bound startup and execution, and
handle startup errors as failures rather than leave an unattended debugger.
Request orderly Emacs exit and wait for its recorded exit status before stopping
and reaping Xvfb. Timeout cleanup may terminate verified owned processes, but
must still reap Emacs before its display and report the run as failed.
Do not rely on an unchecked external tool for the only shutdown path.

A passing run requires both successful assertions and successful startup and
teardown. Never mask unexpected exits with `|| true` or infer success solely
from printed assertions. Preserve the script, command, PID, exit status and
relevant logs on failure, report it promptly, and distinguish observations made
before failure from completed validation. Clean successful temporary runs;
retain only useful bounded failure evidence. Handoffs must include the runner's
actual result. These checks belong to each test run, not every conversation turn;
do not disable crash notifications to hide failures.

Use [`scripts/private-graphical-emacs.py`](../../scripts/private-graphical-emacs.py)
for serverless graphical checks. Pass one Lisp script with its explicit load
paths, prerequisites and environment; the runner supplies its private result
path as `PI_RESULT`. A script must write the configured success marker there
only after its assertions pass and request normal Emacs exit. The runner
enforces the lifecycle above and
its focused process tests live in
[`scripts/test-private-graphical-emacs.py`](../../scripts/test-private-graphical-emacs.py).

### Interactive candidate previews

For a requested review of a visible candidate on Linux, use
[`scripts/emacs-preview.py`](../../scripts/README.md) instead of loading the
candidate into the working daemon or assembling another ad hoc Emacs process.
The helper accepts one exact Jujutsu revision and starts either a vanilla frame
or a frame using an explicit local configuration directory. Personal previews
must select an Emacs executable whose packaged load path contains that
configuration's dependencies; the helper records the resolved executable and
loaded candidate files rather than embedding machine-specific store paths.

A preview is required when the owner requests an interactive review or a specific
acceptance question needs it, not at every handoff. Reuse the recorded working
executable/configuration pair. Keep the helper's readiness contract about usable
startup and refresh; feature-specific completion or rendering assertions belong
in the product's checks or the requested owner review.

Each preview has a clear candidate/profile title, private state, process
namespace and socket, a
disposable representative ledger, bounded startup readiness that includes a
successful asynchronous initial view and refresh, and a manifest
with commands and process identity. The sandbox makes the host and personal
configuration read-only, supplies a writable private `/dev/null` bind, removes shared desktop IPC endpoints and disables networking, so package bootstrap or update
attempts fail instead of changing shared state. Use the helper's `list` and
`close` commands for identity-checked cleanup, including after the user closes
the preview frame directly. Automated checks still use the
private graphical runner above and must not leave an interactive preview open.
## Package archive

Build a locally installable package archive from the checkout root with Python
3.9 or newer; Nix and a development shell are optional:

```console
python3 scripts/package-emacs.py
```

`make -C frontends/emacs package` calls the same packager. It includes source,
guides and demo GIFs and generates `isled-pkg.el` from the main library headers.
There is no separately maintained descriptor or Makefile version.
This does not create an Emacs package flake output.

The [package recipes guide](packaging.md) covers installation with Emacs package
managers. The [release checks below](#package-installation-and-release-checks)
cover construction, acceptance and the archive submission handoff.

Package installation byte-compiles the frontend. Use that compiled package for
large-ledger work: interpreted source loading remains useful during development
but has materially higher callback costs. The package does not change Emacs GC
settings globally. Compare compiled/source execution and default/configured GC
when attributing rendering costs.

Then use `M-x package-install-file` on
the versioned archive in `frontends/emacs/dist/`. The `isled.el` header owns the version;
the generated `dist/` directory
is not source and is ignored.

## Package installation and release checks

### Recipe contents

The [MELPA recipe](recipes/melpa/isled) follows `release`, which advances after
the matching CLI is public. It selects the frontend libraries and root MIT
license. MELPA generates the descriptor from `isled.el`; no committed
`isled-pkg.el` or package-specific build command is needed.

The recipe omits tests, demos, contributor tools and Markdown guides, following
[MELPA's packaging guidance](https://github.com/melpa/melpa/blob/master/CONTRIBUTING.org).
The standalone source tar retains its guides and images.

### Installer acceptance

Package managers own fetching Lisp, dependencies, autoloads and compilation.
They need no Isled-specific download or install hooks. Loading and compiling
the package must not fetch or run its CLI.

The installer runs on the first Isled command that needs the CLI,
using the frontend's explicit pin. It stores complete executable/skill bundles outside package
directories and preserves them when a manager rebuilds or replaces the Lisp
package. It works without inspecting Git state, package-manager metadata
or archive version numbers. The [release contract](../../agent-docs/decisions.md#public-installation-direction-planned)
owns automatic download, integrity, upgrade and recovery behavior.

The downloader allows HTTPS only, with redirects limited to GitHub's release
delivery hosts. Metadata is limited to 256 KiB and archive/executable sizes to
128 MiB: generous headroom for the current few-megabyte binaries, with finite
limits for unexpected responses. Each asset gets two minutes to download;
executable identity checks get ten seconds. Both waits are cancellable. Hashing
and decompression use Emacs facilities; extraction accepts only the six regular
members in the [release bundle](../../scripts/releasing.md#artifact-contract).
The verified CLI then owns platform-directory resolution, immutable version
storage and `current` activation, with a cancellable one-minute timeout.
Emacs displays the returned stable paths and executes its exact versioned CLI.

The [user guide](user-guide.md#cli-setup-and-upgrades) explains setup commands,
cancellation, cache recovery and explicit release/development executables.

To test an installed package against real staged binaries before publication:

```console
python3 scripts/package-emacs.py --output /path/to/isled-candidate.tar
python3 scripts/check-cli-installer.py \
  --package /path/to/isled-candidate.tar --artifacts /path/to/release-candidate \
  --dependencies /path/to/check-packages --output /path/to/new-installer-check
```

This verifies the complete staged set and serves it on loopback. Each scenario
starts a fresh batch editor with an empty tool PATH and replaces its package
directory. Checks cover automatic first use, canceled setup, missing assets,
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
no URL substitution. It covers automatic installation, offline package replacement,
explicit executables and unsupported-platform handling.
`check-published-cli.py` retrieves and verifies the complete pinned release, builds
the current frontend package and runs those live cases against the published CLI.
It then runs the frontend suite against the managed executable;
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

## Code map

- `isled-work-data.el` validates work summaries and complete spans and formats
  completed-time labels. `isled-work.el` owns asynchronous work actions and
  history buffers. Work state and clock invariants remain in Rust.

- `isled-cli.el` owns automatic setup and shared CLI readiness; `isled-executable.el`
  checks identity asynchronously and caches evidence only for unchanged files.
- `isled-install.el` owns private download staging and invokes the Rust installer.
  `isled-installation.el` owns that process and the default-root locator;
  `isled-installation-view.el` keeps copyable paths in a dismissible side window.
  `isled-bundle.el` validates complete stored bundles.
  `isled-download.el` owns cancellable HTTPS delivery with restricted redirects;
  `isled-release.el` validates pinned metadata and `isled-archive.el` reads only
  the expected regular archive members using built-in decompression.

- [`isled-entry.el`](isled-entry.el) owns current-context, project and directory
  selection plus explicit destination choices; [`isled-context.el`](isled-context.el)
  owns selected-location identity and recent-view lookup.
- [`isled-initialize.el`](isled-initialize.el) owns explicit asynchronous creation
  and protects the invoking editor context while it completes.

- [`isled.el`](isled.el) owns lightweight public setup, command
  autoloads, one-time mode-map defaults, and default project-prefix registration.

- [`isled-snapshot.el`](isled-snapshot.el) owns shared typed
  data, issue/reference validation, native-path conversion to Emacs file names,
  and the supported complete-snapshot codec. Windows drive and UNC paths are
  converted at decoding; Unix path bytes and Rust wire formats stay unchanged.
- [`isled-frontend.el`](isled-frontend.el) validates bounded
  response data; [`isled-process.el`](isled-process.el) owns
  asynchronous process execution.
- [`isled-data.el`](isled-data.el) owns retained details and
  target metadata. It retains a mutable combined projection: a full view rebuilds
  membership, while detail replies replace/remove only touched identities.
  [`isled-sequence.el`](isled-sequence.el) owns private indexed
  list spines that preserve order during those updates; [`isled-loading.el`](isled-loading.el) owns
  request coalescing, stale-response fences, and nearby-range scheduling.
- [`isled-session.el`](isled-session.el) owns shared ledger
  detail tables, serialized process work, shared notification ownership and view
  registrations. [`isled-buffers.el`](isled-buffers.el) owns
  view creation, duplication and reuse.
- [`isled-windows.el`](isled-windows.el) owns display-change
  observation and the union of nearby expanded IDs across displaying windows.
- [`isled-viewport.el`](isled-viewport.el) owns newly needed body
  formatting across actual text-screen ranges and preserves window anchors.
- [`isled-jump.el`](isled-jump.el) owns the ledger-wide ID/title chooser and its late-reply fence.
- [`isled-navigation.el`](isled-navigation.el) owns window/view
  navigation memories, shared duplicate-suppressing history recording, and
  asynchronous origin checks.
- [`isled-expansion.el`](isled-expansion.el) owns expansion
  fitting and its window-local, cancellable pre-fit viewport through folding or
  asynchronous body delivery.
- [`isled-view.el`](isled-view.el) owns pure filtering and selection.
- [`isled-graph-model.el`](isled-graph-model.el) validates compact Rust layouts,
  indexes row identities and continuing lanes, and orders selected headings.
  [`isled-graph-drawing.el`](isled-graph-drawing.el) validates shared drawing
  steps against those exact dependencies and indexes their physical tracks.
  [`isled-graph-glyphs.el`](isled-graph-glyphs.el) derives directional node and
  connector lines. [`isled-graph-gutter.el`](isled-graph-gutter.el) paints nearby
  glyphs, anchors nodes outside folds, and composes body panel prefixes. [`isled-graph.el`](isled-graph.el) owns
  presentation toggling, direction reversal and the query/presentation header.
  [`isled-listing.el`](isled-listing.el) owns exclusive hierarchy/ID/oldest-first
  selection and the last flat choice. [`isled-view-state.el`](isled-view-state.el)
  owns the restorable view value shared by those commands and the browser.
  Rust's omitted-connection
  counts preserve the circle marker when filters hide every neighbor; filters use
  the ordinary loading queue.
- [`isled-presentation.el`](isled-presentation.el) owns semantic
  faces, Markdown presentation, literal work-table cell alignment, typed
  reference properties and diagnostic text.
- [`isled-rows.el`](isled-rows.el) owns identity indexes, complete
  heading/routing text and separate integer heading and body boundaries.
- [`isled-fold.el`](isled-fold.el) owns standard search-reveal
  hooks and the distinction between temporary visibility and explicit expansion.
- [`isled-sections.el`](isled-sections.el) owns row rendering and
  visible structural navigation stops. Rendering and expansion restoration index
  snapshot identities for repeated lookups; they retain the snapshot objects.
  Its show/hide wrappers synchronize heading backgrounds and boundary indentation;
  frontend commands and accepted search matches use the same row opening path.
- [`isled-filter.el`](isled-filter.el) owns the filter prompt,
  live preview, successful prompt completion and cancellation restoration.
  The prompt retains parsed criteria for its current
  valid input through acceptance; loading queues retain those criteria alongside
  the editable filter, while view/history state keeps its existing query value.
  [`isled-filter-query.el`](isled-filter-query.el)
  owns query tokens/criteria and status replacement; [`isled-filter-completion.el`](isled-filter-completion.el)
  owns exact token contexts, independently parsed remaining criteria, current
  choice values and status insertion cleanup.
  [`isled-filter-display.el`](isled-filter-display.el) owns
  completion-session ownership, selected-candidate observation and narrow optional
  completion-package refresh bridges.
  [`isled-filter-preview.el`](isled-filter-preview.el) owns
  temporary candidate result previews, typed-query restoration and its prompt-owned
  observer timer.
  Loading carries choice context alongside previews and keeps view freshness
  independent of cursor-only completion changes.
  The interaction modules
  [`isled-filter-inline.el`](isled-filter-inline.el),
  [`isled-filter-picker.el`](isled-filter-picker.el), and
  [`isled-filter-minibuffer.el`](isled-filter-minibuffer.el)
  own inline suggestions, recursive token selection, and whole-query completion
  respectively.
- [`isled-header.el`](isled-header.el) owns pure directory
  disambiguation and width-aware identity presentation.
- [`isled-auto-refresh.el`](isled-auto-refresh.el) owns directory
  watches, notification coalescing, and polling fallback; the controller performs
  request scheduling and view restoration.
- [`isled-browser.el`](isled-browser.el) owns the major mode,
  keymap, per-ledger buffer state, and semantic navigation history.
- `isled-source.el` owns explicit Markdown source visits and routing bypass.
- `isled-file-routing.el` owns lightweight activation, file candidate
  recognition and deliberate file-display adapters. `isled-file-visit.el`
  owns asynchronous Rust validation, source-origin fences and navigation into
  the target view.
- [`test/`](test/) mirrors those boundaries with ERT coverage and a version 2 fixture.

`isled-warnings.el` owns the known-finding header affordance and its ordinary
history jump; the bounded decoder owns its typed Rust target.


## Dependency rendering

Rust computes the complete logical layout from selected metadata, independently
of loaded bodies. Emacs retains that plan and paints glyph strings only near
visible windows; offscreen rows preserve both gutter width and routing height
with spacing placeholders. Connector lines have real buffer positions outside
foldable bodies, so ordinary line-by-line scrolling can place them at the window
top without blank or stuck rows. Painting changes display properties without
inserting text or moving rows. Expanded panels continue their border and background
across these routing rows; folding removes that panel styling while retaining the
connectors. Bodies continue using bounded loading.
The [wire contract](../../user-docs/frontend.md#dependency-layout)
owns conditional tokens, edge limits and failure behavior. Graph view requires
the updated CLI and frontend; older CLI versions have no graph fallback.

## Bounded loading

The [bounded protocol](../../user-docs/frontend.md) owns request/reply fields.
Opening a view, changing filters, and refreshing are asynchronous. Full refresh
reconciles the ledger and obtains Rust-filtered summaries and ledger-wide
unreadable diagnostics. Only after that list arrives can Emacs compute which
expanded issues are nearby; it then requests details separately. Filter changes
use cached summary selection, and scrolling uses targeted detail batches, with
no second full reconciliation.

Each displaying window contributes its visible screen plus two full text screens
on either side, rounded outward to intersecting 32-heading chunks. Chunk boundaries count issue headings, not body
lines; visible coverage counts actual displayed text. An off-screen point also
prepares its prospective destination before recentering. Only expanded issues
in these ranges request bodies. Boundaries are derived from the current row
vector after filtering or membership changes, not retained as cache identities.
An index of expanded rows rules out distant bodies using conservative heading
bounds before doing screen-layout work. Already formatted bodies do not schedule
background preparation. The shared ledger session requests the union of expanded IDs across its views
and those windows, once per ID, with
their retained live hashes. Windows on other visible frames contribute too;
undisplayed buffers request no nearby details. New bodies show a
subdued loading placeholder. Unchanged replies retain cached bodies; changed,
deleted, and problem replies update the view. Off-screen details stay cached
and are checked again when they enter the range. This bounds the requested
issue set, not the size of unusually long individual records.

Each ledger serializes Rust requests across its views. Each view coalesces
pending work to its latest useful request. Needed details dispatch immediately
when the session is free; request completion dispatches the latest remaining
demand without a scheduling delay. Rust stays asynchronous. Movement, scrolling another window, splits,
resizing, and display changes update demand, including background frame changes
and minimization/restoration. One shared observer compares small window signatures
before redisplay and schedules heading traversal only when they change. Hiding the buffer cancels
its background formatting demand; a queued batch with no remaining demand launches no process.
Returning to the range rechecks retained hashes. Observers are removed when the
last participating view stops loading, is killed, or changes major mode,
preserving other packages' redisplay functions.
Complete display is best effort: if navigation outruns asynchronous data,
loading placeholders remain until the response arrives. Available visible text
is formatted synchronously, so an unusually expensive body can briefly pause input.
A newer refresh, filter choice, or history destination invalidates obsolete
replies. Running Rust
commands finish normally so they can release their locks; killing a view discards
its reply and cancels timers. Errors keep the last good view and appear in the
header; `g` retries. Failed detail requests do not automatically retry on movement. Cache recovery happens inside Rust without a frontend
recovery handshake or notice when it succeeds.

Complete headings are inserted as ordinary text in one batch. Matching row
identities update in place; structural changes rebuild the list with semantic
anchor restoration. Detail delivery inserts retained body text first and formats
visible bodies before redisplay. One additional nearby body per ledger session is
prepared per background callback, favouring proximity and direction of travel
within the same two-screen margins. A 1 ms timer yields between bodies so Emacs
can service input and redisplay; it does not delay Rust requests. A large detail batch does not eagerly format all
returned bodies. Presentation coverage counts actual body height and is rechecked
after formatting changes wrapping, unlike the fixed heading chunks above. Applied properties remain cached off-screen to avoid repeated
Markdown work and layout changes when returning. Explicit expansion and temporary
search reveal format the chosen cached body immediately. Window-change observation also formats
newly visible cached bodies before redisplay, including a distant jump destination;
it never waits for Rust or performs
a reconciliation. This bounds new
formatting work, not total retained text or an unusually long individual body.
Large structural rebuilds can still pause Emacs; loading is asynchronous but
buffer updates execute on Emacs's main thread.
Generated views disable undo recording so rebuilding them does not retain old
rows. Reply processing temporarily allows at least 16 MiB of allocation between
collections, preserving larger user thresholds and restoring the configured
threshold afterward, including on errors. This bounds allocation overhead during
large read-only rebuilds without changing the user's global GC policy; issue
editors retain normal undo. Re-measure status switches on representative 5k
ledgers when changing this path.



## Presentation

The [snapshot contract](../../user-docs/snapshot.md) owns wire fields,
encodings, readiness, and reference coordinates. The renderer consumes
Rust-owned annotations rather than searching record text. Issue references are bold:
ready targets use semantic success, waiting open targets use link, closed
targets use struck-through shadow, and missing targets use non-underlined
semantic error. Ordinary Markdown links remain normal-weight and underlined.
The authored text is unchanged. The view wraps and scrolls like a normal buffer.
The generated view disables `hl-line-mode`; semantic heading and body faces
provide its visual structure.

Sparse font specifications reduce repeated heading font selection while retaining
semantic faces, weight contrast and per-frame fonts. This does not eliminate
expanded-body allocation or change native scrolling. Preserve theme/customization
behavior when evaluating further presentation optimizations.



## Structured editor

Implementation responsibilities: `isled-editor-model.el` owns state/wire decoding,
`isled-editor-form.el` fields/diagnostics, `isled-editor-completion.el` completion
and bounded documentation, `isled-editor-feedback.el` header/save/watch feedback,
and `isled-editor.el` lifecycle/save coordination. `isled-session.el` retains
one watch until its last view or draft subscriber leaves.
The editor ERT suite covers draft validation, save/conflict handling and lifecycle
boundaries with disposable fixtures.

## Completion integration

Choices update asynchronously without inserting text or moving point. Later query
terms and a still-valid selected candidate survive updates. Moving the cursor
requests choices without repeating the view payload; valid text edits combine
preview and choices in one request. Partial structured tokens can request choices
while retaining the last valid results. Replies for obsolete text, cursor spans,
closed prompts or displaced views are discarded. The recursive picker remains
cancellable while waiting and late replies cannot reopen it.

All interfaces share the standard completion data. Small optional Vertico and
Corfu refresh bridges invalidate their input-based display caches; neither
package is required. They retain a selected candidate only while refreshing the
same completion context, never after editing or moving to another token.

Contextual completion stays independent of optional completion frameworks;
measure query and presentation costs separately when changing it.

<details>
<summary>Completion package compatibility details</summary>

Inline suggestions use public Corfu settings locally; they do not change global
completion settings. Minibuffer suggestions use a local `basic` completion style
for this query category because Orderless does not respect the cursor position
inside a whole query. Its Vertico insertion adapter also calls Vertico's internal
refresh function to prevent stale selection during queued input. The separate
picker needs no Vertico-specific code. These details do not affect other prompts.

</details>

## Source upgrades

Upgrading a source-loaded older version removes the former package defaults
`o`, `c`, `a`, and `s` once when they still name their former commands. This
narrow migration does not install current defaults. Later reloads preserve
personal uses of those keys and all other mode-map changes.

Source loading reads from the configured checkout. If you compile locally for
interactive use, rebuild or remove old bytecode before reloading so it cannot
shadow newer source. Routine validation compiles only into temporary directories
and does not install those files into the source tree or a running editor.

`isled-program` defaults to nil for managed release setup. During isolated
development, explicitly select the repository-built binary and allow its `-dev`
identity; its numeric version must still match the frontend pin:

```emacs-lisp
(setq isled-use-development-cli t
      isled-program
      (expand-file-name "target/debug/isled" my-isled-checkout))
```

## Shared ledger sessions

Views share retained detail data and serialized Rust work, but keep separate
filtered projections. Refreshing any view reconciles once and updates each
view's own filter. Simultaneous refresh requests share that reconciliation.
Hidden views retain their rendered text and coalesce changes until shown again;
returning to an unchanged view needs no reconstruction or Rust wait. Hidden
views request no details. Rendered text and display properties are view-owned;
sharing the decoded detail cache does not eliminate that per-view memory cost. One private ledger buffer owns notifications and polling
fallback until the last view is killed. Closing a window retains its view.

## Automatic refresh

Each ledger watches its flat `.issues/` directory by default while any view
buffer exists, including when every view is hidden. Real
create, change, rename, and delete events are coalesced with a short one-shot
idle timer before one full refresh. The normal Linux `inotify` path does
not poll the ledger. If directory notifications are unavailable or a stopped
watch cannot be restored, the header reports a visible degraded state and the
shared ledger owner uses Auto Revert polling as a correctness fallback. Set
`isled-auto-revert` to nil before opening a view to disable both
mechanisms. Automatic refresh and `g` preserve the active filter and every
filter's remembered view. On an automatic failure, the last good view remains
visible and a retryable error appears in the header line.
After initial root discovery, watch installation is followed by one reconciliation
refresh to close the setup race. Unchanged snapshots perform no Markdown
writes; a copied-title correction may trigger one further no-op refresh.
Killing the last view removes the ledger watch and pending timers. Killing one
view leaves surviving views active; in-flight results cannot resurrect killed
views or an ended session. A stopped
watch is restored when possible. The `kqueue` backend cannot observe existing
child-file content changes and uses polling. Built-in non-file Auto Revert alone
does not cover the ledger's required child-file and shared-view refresh semantics.

The native auto-refresh integration test changes a disposable ledger directly:
in-place edit, atomic replacement, creation, rename and deletion. It waits for the
normal notification/idle-timer or Auto Revert path to update an open view, without
requesting refresh itself. Each CI runner logs its actual backend and whether it
used notifications or polling; closing the view must release its watch.



## Recording README demos

The README GIFs show the actual frontend with a fictional Trail Notes backlog.
[`demo/record.el`](demo/record.el) creates its ten issues and dependencies through
the CLI in the runner's private HOME: an offline release sequence, a sync sequence
with two prerequisites, an independent fix and a completed task. Keep the example
focused on ordinary work sequences with few joins. It uses normal frontend
commands to browse and filter, then create an eleventh issue, edit it and verify
the saved text. The Work clip queues a task, starts and pauses timing, resumes,
requests review, and opens both history and the stored Work log. One fictional
earlier session is seeded through the CLI so completed time is readable; the
recorded transitions use the real Work menu. It exports the displayed Emacs frames as PNGs. The capture uses the built-in Modus
Vivendi Tinted theme, hides the mode line, and shows key hints in the echo area.
Keep the default line spacing so vertical gutter strokes meet between rows.
It loads no user init and must never
run in a working daemon. Capture currently requires Linux/Xvfb, graphical Emacs
with PNG frame export, DejaVu Sans Mono, and ImageMagick for GIF encoding.

Build the candidate CLI and use the [portable dependency setup](../../CONTRIBUTING.md#emacs-checks-without-nix)
or an Emacs executable with the declared packages and their dependencies. Pass
explicit dependency directories as additional `--load-path` options when needed.
From the repository root, with a new artifact directory:

```sh
python3 scripts/private-graphical-emacs.py \
  --script frontends/emacs/demo/record.el \
  --load-path frontends/emacs \
  --env "ISLED_DEMO_PROGRAM=$PWD/target/debug/isled" \
  --screen 1080x680x24 --timeout 150 \
  --artifacts /tmp/isled-readme-demo --keep-success

magick -delay 25 /tmp/isled-readme-demo/frames/hierarchy/*.png \
  -layers Optimize -loop 0 frontends/emacs/images/hierarchy.gif
magick -delay 25 /tmp/isled-readme-demo/frames/filtering/*.png \
  -layers Optimize -loop 0 frontends/emacs/images/filtering.gif
magick -delay 25 /tmp/isled-readme-demo/frames/editing/*.png \
  -layers Optimize -loop 0 frontends/emacs/images/editing.gif
magick -delay 25 /tmp/isled-readme-demo/frames/work-tracking/*.png \
  -layers Optimize -loop 0 frontends/emacs/images/work-tracking.gif
```

Check the runner's success and cleanup result, then inspect the opening, expanded,
filtered, draft, saved, work-menu and history frames for legibility and unintended UI. The clips loop at
four frames per second. Keep the fixture fictional and the output bounded; only
the selected GIFs belong in the source tree, not raw frames or runner logs.
