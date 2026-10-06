# Accepted decisions

This page records current rationale and consequential tradeoffs. Current behavior
belongs in the [user contracts](../user-docs/README.md) and
[Emacs guide](../frontends/emacs/README.md); implementation and tests establish
compliance. Historical experiments and deployment records are not prerequisites
for understanding or contributing to this project.

## Design discipline

Use [cohesive, simple, invariant-bearing designs](coding-standards.md).
Abstractions must answer a present need; future options can retain a clean seam
without acquiring a framework. Documentation follows responsibility and retrieval
cost rather than a numeric page-size target. The product remains a local,
single-user ledger; no service, network API or backend framework is selected.

## Authority, persistence, and future storage

Markdown is authoritative and directly inspectable. Ordered Markdown sections
make human reading and deterministic parsing compatible; the
[record grammar](../user-docs/record-format.md) is the single supported format.
Require UTF-8 for names and records while preserving opaque parent paths through
lossless wire encodings. Validate only what an operation needs so unrelated
malformed prose cannot block targeted work; retain raw-byte recovery diagnostics.

SQLite supplies a rebuildable derived cache, not another authoritative store.
Shared Rust-side caching improves repeated CLI calls as well as frontend use.
Keep domain operations independent of filesystem details through pure parsing,
mutation plans and narrow I/O boundaries. An authoritative database, dual parser,
repository trait or migration framework needs a concrete future requirement.

Retain bytes, parsed issues and failures for one command so reconciliation and
output share work. Corrections must keep retained state coherent without rereading
their own output. Reuse prepared statements through encapsulated connection APIs;
parameter binding and transaction/lock ordering remain explicit. Stable content
fingerprints avoid rewriting unchanged projections, accepting negligible accidental
collision risk and rebuilding an affected issue's projection rather than tracking
field-level changes. [Cache design](cache-design.md) owns those boundaries.

A bounded reader pipeline moves ownership to one consumer instead of sharing a
SQLite connection or parsed cache between workers. Avoid tiny-workload alternate
paths and recycling schemes without evidence. The one-command CLI can let process
exit reclaim retained memory; library operations keep normal cleanup, including
lock/transaction release in both cases. Measure end-to-end costs before claiming
speedups from allocation or cleanup changes alone.

External-edit freshness is best effort. Own mutations update affected cache rows;
targeted reads reconcile the requested issue and direct neighbors. Directory
mtime is a cheap membership hint, not proof that content is unchanged; compare
identities rather than counts. Explicit targeted/full refresh and the integrity
checker cover gaps. No resident Rust watcher or stale-cache overwrite of Markdown
is selected. See the [cache contract](../user-docs/cache.md).

## Batch issue inspection

Multi-ID `show` supports surveying issues. Readable combined output takes precedence
over byte-exact concatenation; titles supply separation without decorative framing
or a new output format. Bad records should not prevent useful inspection of other
requested records. Single-ID `show` remains the opaque valid-UTF-8 recovery path.
The [user contract](../user-docs/README.md#inspecting-several-issues) owns ordering,
repeats, framing, diagnostics and exit behavior. This does not justify a hidden
whole-ledger scan or an unmeasured performance claim.

## Brief lock contention

CLI mutations and asynchronous refresh can overlap. A 500 ms bounded acquisition
wait preserves the simple exclusive lock while absorbing brief contention.
Retry acquiring the lock only, never an operation that may have changed data.
Shared locks and upgrade coordination are unnecessary for the accepted workload.

## Generated relation warnings

Rust owns structured warnings and Emacs presents actionable findings. Inspection
may repair a copied title because the target's title is authoritative; other
repairs require a deliberate choice. Reuse the held lock and the inspected
neighborhood without recursive repair or hidden graph-wide checking.

Unmatched relations warn on both endpoints and remain conservatively blocking
when both issues are open. Complete or remove the relation explicitly; missing
targets allow removal. Unreadable records expose the actual error and file/trash
actions, without silently deleting relationships. Preserve identity and best-effort
screen position after controls disappear. [Synthetic recovery fixtures](../frontends/emacs/test/fixtures/relation-warnings/README.md)
make these paths reproducible without real ledger mutations.

Retain last-known persistent findings in the disposable cache, including unreadable
records and inconsistent relations; exclude transient lock/operational failures.
Only rechecking a condition clears it, with direct neighbors rechecked when needed.
The Emacs indicator remains visible through filtering. Warning jumps reuse normal
history, coalesce repeated locations and restore the previous view with `M-,`.
Absence of known warnings does not prove a complete integrity audit.

## Mutation and interface boundaries

Pure plans separate meaning from locked publication. Only filesystem code allocates
IDs, supplies path bytes, stages replacements and publishes. Per-file atomic
replacement, deterministic ordering, bounded locking and an explicit integrity
checker fit this low-contention tool. Interrupted multi-file writes remain possible
and diagnosable; there is no transaction journal promising all-or-nothing crash
recovery across records. Preserve validation, freshness and publication ordering.

Mirrored dependencies and copied titles let either endpoint explain direct
relations without a whole-ledger read. The reason belongs to the outgoing edge.
Preserve relations after closure because they carry durable rationale. Closure is
terminal: invalidated or new work receives a new issue rather than reopening old
history. Evidence and Outcome are distinct from authorization to close; consuming
projects define that authority. Allow deliberate corrections to closed prose with
a warning for the explicitly changed record, retaining the lifecycle.

Statement input supports complete stdin authoring and literal replacement without
requiring ad hoc file extraction or a patch language. Creation validates before
allocating an ID; reject reserved section headings before publication. Empty
replacement means deletion, with unique-match selection unless explicitly widened.
This remains Statement-specific rather than a generalized editing framework.

Titles are semantic content; filenames and creation-time slugs remain stable
through renames. Ergonomic CLI ID spellings normalize at the boundary without
weakening canonical stored IDs. Use mature crates for generic grammar and Unicode
semantics; keep product-specific rules local and authored bytes preserved.
Rust library source compatibility is not a public API promise; CLI, storage and
wire compatibility remain governed by the [contract](parity-contract.md).

Metadata-only selection belongs in composable `list`, text matching in `search`,
and frontend data in dedicated versioned wire commands. Prefer clear diagnostics
and help over aliases. `add` is the sole creation command; mistaken `create` forms
point to it before project discovery. Dependency inspection traverses only the
requested direction, with historical leaves retained without expanding irrelevant
branches. Compact prose references navigate but do not create dependency edges.

## Issue conclusion and lifecycle vocabulary

Outcome explains what was decided or done and why, including rejection or no
change. Statement owns the concern and Evidence owns observations. The familiar
word Outcome replaced the former administrative label with a clean interface
boundary; no old-name aliases or permanent dual record grammar remain.

Add / Edit / Close and Open / Closed describe actions and state without implying
that every closed concern was solved. Saving an Outcome never implicitly closes
an issue. Current wire/storage versions and legacy-input rejection are specified
in the [compatibility contract](parity-contract.md), not inferred from historical
migration tools.

## Frontend architecture and presentation

Rust owns ledger interpretation, references, readiness, filtering and graph layout.
Typed versioned payloads keep frontends from duplicating Markdown/dependency
parsing. A complete heading-text index plus bounded body loading keeps native
navigation, search, wrapping and scrolling useful on 5,000 retained issues.
Only nearby expanded bodies need transfer and presentation. Hash complete returned
meaning, including derived diagnostics, and reject obsolete asynchronous replies.

Recompute filtered membership before detail demand; the old list cannot define a
new result. Union demand across every displaying window, deduplicate requested IDs,
reuse shared detail data and retain applied body properties off-screen. Repeated
Markdown work and reflow would harm return to cached content. Hidden views defer
rendering and request no details; visible demand and freshness drive work rather
than an eager whole-ledger fetch or resident server.

Compare compiled frontend costs under representative/default GC settings. Sparse
font specifications retain semantic faces, weight contrast and frame-specific font
selection without captured font objects. Heading improvements do not eliminate
expanded-body allocation. Discarded body-buffer reuse reduced allocations without
a useful latency gain. Keep performance claims specific to the measured path.
Do not globally alter the user's GC policy; large read-only rebuilds may locally
raise the threshold and restore it afterward as documented in the frontend guide.

Semantic faces inherit ordinary Emacs/Markdown defaults. The body face supplies
only an unspecified background fallback so explicit face and theme choices win.
Padding and hidden duplicate titles alter presentation properties, not authored
text or reference coordinates. Retain the hidden boundary newline to avoid moving
the next heading when folding. Keymaps and `use-package` own customization; initialize
defaults once and preserve user changes across reloads. A narrow retirement of old
package defaults is separate from installing current bindings.

Each view owns filtering and folding; ledger data, requests and notification watches
are shared. Window/view pairs own navigation history and semantic positions.
Duplicating a view copies its state/history and then evolves independently; normal
window splitting still shows one shared view. Preserve other windows during async
navigation and release shared resources after the last view/draft subscriber leaves.
Replies cannot recreate dead sessions. Hidden views remain available for quick
return, with accumulated rendering changes coalesced.

Expanded sections get a best-effort fit without hiding point. Delayed body arrival
respects subsequent movement and other windows. Folding can restore a remembered
pre-fit viewport only without intervening movement; refresh, filter change and
resize invalidate that intention. Ordinary search covers headings and materialized
bodies, including folded bodies, without fetching every issue. Standard search-reveal
hooks support completion previews; temporary reveal changes visibility, while final
acceptance performs normal expansion and bounded revalidation. No Consult/Vertico
runtime dependency is required.

## Bounded chunk prefetching

Chunk ordered issue headings independently of body height. Each displaying window
requests the visible screen and two screens on either side, rounded to chunks;
union windows and request only expanded bodies needing detail. Explicit opening
adds immediate demand. Hash/revision checks establish freshness, not mere presence
in a cache. Coalesce around the latest destination and keep Rust asynchronous even
if a user outruns prefetching; no queued movement or synchronous wait guarantees
instant readiness.

Retain content by stable ID/hash while recomputing membership after filtering or
updates. Reject obsolete membership and preserve the destination when possible.
Batch missing detail requests through the shared queue, then present incrementally
with visible work first; do not eagerly format all replies in one callback.
The [frontend guide](../frontends/emacs/CONTRIBUTING.md#bounded-loading) owns current bounds
and behavior. The chosen lookahead is a responsiveness policy, not a hard guarantee
for arbitrary issue body sizes or machines.

## Filter completion and direct selection

Status, kind and tag terms combine with literal text using AND; Rust owns matching.
Use ordinary completion APIs independent of a particular framework, with contextual
suggestions preserving typed values and deliberate no-match selections. A compact
interface need not acquire a search cache or bespoke parser state. TAB uses standard
completion so editing an earlier token preserves trailing terms. Explicit picks and
preview/cancellation preserve view/history semantics.

Direct issue selection covers the whole ledger, including closed and filtered-out
issues, then uses normal reveal and shared history. Filter highlights identify the
matching text without becoming stored issue content. Conventional keymaps and
named commands remain the customization surface.

## Issue-file opening direction

Opening a well-formed local canonical issue file can reveal its issue in the ledger
view, including filtered-out or closed records. Rust validates the filename/identity
and canonical ledger before redirection; do not trust text resemblance alone.
Preserve ordinary file-opening fallback for malformed files, unsupported locations
or failed lookup. Remote/TRAMP and non-regular files retain normal file behavior.

Reuse an existing view when appropriate and preserve browsing context in history.
Map source-line destinations to the canonical body when possible, without inventing
new reference semantics. The explicit Open Markdown source action bypasses routing
so direct record inspection/editing remains available. Install lightweight routing
without eagerly loading the browser or overwriting personal key bindings.

## Project ledger entry commands

Project commands use ordinary Emacs project selection and canonical local roots;
explicit directory opening remains available. Only create a missing ledger through
a deliberate initialization action. Default invocation reuses the most recently
used view; a prefix creates an independent view, and explicit duplication preserves
its source state. Respect ordinary window placement and existing bindings.

## Structured issue creation and editing

Use a separate structured draft with title, kind, tags, Statement, Evidence, Outcome
and explicit dependency directions. Keep labels protected but navigation/copying
unrestricted, with theme-friendly field styling. Standard save/cancel keys and window
placement reduce custom machinery. One draft per existing issue preserves unsaved
work; new drafts have no allocated ID until successful save.

One Rust save operation checks the expected version, fields and graph under the
ledger lock before publishing. Validation/stale-save rejection publishes nothing;
I/O failure during multi-file publication may be partial and must be distinguished
from rejection. Preserve drafts and reconcile actual saved state before retrying.
Use Compare, Reload or explicit confirmed Overwrite rather than automatic merge;
recheck the confirmed version again before replacement. Neighbor updates must not
silently discard unrelated edits.

Idle validation creates no records and discards replies for old draft generations.
Errors remain selectable beside fields without moving point unexpectedly. Completion
uses existing vocabulary while permitting new valid values; prose references never
silently create relationships. Watches can signal Changed on disk without reloading
a draft. Closing is an explicit editor intent that validates edits and closure
together; ordinary saves remain edits even when Outcome is filled in.

## Dependency issue view

Use aligned unique rows and a graph gutter rather than a tree or deep indentation:
shared prerequisites form a DAG. Hierarchy is enabled by default but can be toggled
without changing filters or browsing state. Strict status selection comes first;
additional filters project the graph while retaining circles for connected issues
and dots for independence within the status selection. Avoid hidden-edge prose
notes, ambiguous crossings and excessive rightward drift. Rust computes complete
layout before pagination; Emacs paints bounded visible ranges. The
[graph design](dependency-graph-view.md) owns ordering, junction and caching rationale,
including accepted wide-graph limits and the decision not to persist layouts.

## Nix development inputs

Filter before flake evaluation: filtering a package derivation alone is too late
to prevent the initial source copy. Shell snapshots contain tools and pins only;
package snapshots also contain current Rust inputs. This avoids source edits
creating new shell/cache identities while preserving actual environment refresh.
Use the [documented wrappers](../scripts/README.md#source-boundary); Nix is optional.

## Public contributor boundary

The source tree and engineering requirements are self-contained. A normal Git
checkout supports building and checking the CLI and frontend. Optional jj, Nix,
Linux graphical and local-release tools retain useful maintainer workflows without
requiring every contributor to adopt them. Selected standards belong to the project
while personal global policies remain independently maintained in their own scope.
Raw operational history and private ledgers stay outside tracked source; concrete
boundary checks supplement human review of public documentation and attribution.

## Future directions

Optional ledger tracking remains an investigation. The motivation is a personal
ledger becoming useful to another contributor; distributed concurrent allocation,
conflict resolution and synchronization require a concrete multi-user use case.
The current local ignored-ledger default is unchanged.

### Optional issue work tracking (planned)

Work state and the work log are optional. An absent Work state means Not queued;
an absent log means no recorded time. Keep work state independent of Open/Closed
and dependency readiness so ordinary issue tracking needs no scheduling or clock.

The states are Not queued, Queued, In progress and Awaiting owner.
Awaiting owner has a visible reason: Review means work ready for owner acceptance;
Clarification means an answer is needed before work can continue. Entering either
stops the active span. Distinguishing the reasons preserves the small state model
while keeping review readiness separate from a task blocked on an owner answer.
Store Reason and Question as children of the Work state metadata entry so the
current wait is readable as one group. Clarification requires a brief, non-empty
Question there; supporting context may stay in Statement. This lets humans and
frontends find the pending question directly, and agents retrieve it structurally.

```markdown
- **Work state:** awaiting-owner
  - **Reason:** clarification
  - **Question:** Should elapsed time always be visible, or only on request?
```

For owner review, Reason is `review` and the Question entry is unnecessary.
Different issues can proceed in parallel, with one worker at a time on each issue
and at most one active span per issue.
Pausing closes a span without changing In progress; resuming opens another.
Completed spans accumulate implementation, engineering review and repair time.
Queued and owner-waiting time remain separate from recorded work.

Store spans in an optional Work log section as a Markdown table with Started
(UTC), Stopped (UTC) and Activity columns. Activity may be empty; an empty stop
marks the active span. Calculate totals from the spans rather than storing a
second value that can drift. The table keeps the history readable with ordinary
Markdown tools and gives each pause or handoff its own entry.

```markdown
## Work log

| Started (UTC)       | Stopped (UTC)       | Activity       |
|---------------------|---------------------|----------------|
| 2026-10-06 09:00:00 | 2026-10-06 09:30:00 | Implementation |
| 2026-10-06 10:00:00 |                     | Review         |
```

An open span persists across restarts. Ending a CLI invocation or editor session
does not establish when work stopped. For a clock left running accidentally,
allow the human or coordinator to record the actual stopping time later so the
total reflects that explicit time rather than an inferred interruption.

Prefer simple shared CLI and Emacs actions that update state and timing together
where appropriate. Humans can invoke them directly; coordinators can invoke the
same operations at worker handoffs. Start selects In progress and starts the clock
by default. Both interfaces also offer Start without timing, which selects
In progress without opening a span. This makes timed work one action while keeping
state tracking usable on its own. Task assignments and queue ordering belong to
the coordinating workflow. Work state grants no execution or closure authority.

Closing an issue stops its active span, preserves its complete work log and removes
its current Work state. Closure remains one action, and the terminal record keeps
its timing history without claiming that work is still underway.

The new implementation must read existing issues unchanged, without conversion.
Once a ledger uses work tracking, its tools must understand the new format; older
versions cannot read those records. Release the CLI and matching Emacs frontend
together so users receive a compatible pair. Supported edits must preserve work
state and span history. This keeps ordinary upgrades simple while avoiding silent
loss of tracking data through an older tool.

This records the planned direction, not available commands. Finalize command
syntax and timing presentation during implementation within these decisions and
the [compatibility contract](parity-contract.md).

<a id="public-installation-direction-planned"></a>

### Public installation direction

The target is a normal Emacs package installation with package-managed setup of a
compatible, precompiled Rust executable. On first use, Isled downloads it
automatically and completes setup inside Emacs. This timing works
across package managers without downloading during package loading or compilation.
Users should not need a checkout, Rust toolchain, manual CLI download or
executable-path setup for the ordinary route. The two parts work as one product,
while downloadable CLI binaries remain available for standalone use.

The first release will target three platforms. Source CI runs native checks on
the runners below; release staging separately checks the distributed artifacts.

| Compatibility target | Rust binary target | Native acceptance runner |
| --- | --- | --- |
| Linux kernel 5.4+, x86-64 | `x86_64-unknown-linux-musl` | `ubuntu-24.04` |
| Windows 10+, x86-64 | `x86_64-pc-windows-msvc` | `windows-latest` (Windows Server) |
| macOS 15+, Apple Silicon | `aarch64-apple-darwin` | `macos-15` |

Use local validation for ordinary development pushes. Hosted CI runs one Linux
job on pull requests so contributors get feedback. Reserve the full three-platform
matrix for the `release-artifacts` preparation branch and explicit manual runs;
ordinary branch and tag pushes start no workflows. Release staging keeps its
native artifact, installation, upgrade and rollback checks before publication.
There is no scheduled CI. This limits repeated work while retaining release
acceptance; Windows/macOS regressions may be found later during preparation.
Run the full matrix manually sooner when a platform-sensitive change warrants it.

Keep the initial build and support scope small. Intel Macs, Linux ARM64 and
native Windows ARM64 releases are deferred; revisit them if users need them.
Keep CI to one standard native runner per platform, running Rust tests and
isolated Emacs integration checks. Record actual OS, kernel and tool versions;
runner image updates must not silently redefine compatibility targets. Additional
VMs, emulation jobs and self-hosted runners are outside the initial CI scope.

When managed setup has no supported binary for the user's platform, explain
that limit and link to source-build instructions. Do not compile automatically.
Users can explicitly configure a matching executable they built themselves;
this does not extend the tested platform commitment.

Windows 10 compatibility is required, with native Windows Server testing accepted
in place of Windows 10/11 desktop jobs. Use the ordinary x86-64 MSVC toolchain on
`windows-latest` and check dependencies for newer OS requirements. Windows 10
remains an explicitly untested compatibility target.

Distribute Linux builds as a self-contained `x86_64-unknown-linux-musl`
executable, with the C runtime and SQLite linked statically. This avoids a
dependency on the host's glibc version or separately installed runtime libraries,
at the cost of a larger executable. Use the generic x86-64 CPU baseline for Rust
and native dependencies, without requiring AVX or build-machine CPU features.
Kernel 5.4, the [original Ubuntu 20.04 baseline](https://ubuntu.com/kernel/lifecycle),
is a moderate older-system target. It accommodates older installations without
committing to the toolchain's much older theoretical floor.

Verify Linux artifact linkage and run the musl executable through the applicable
CLI and Emacs integration checks on the Ubuntu runner. Kernel 5.4 compatibility
is a build target, not a claim of testing on that kernel. Keep that gap explicit;
add targeted older-system checks if a concrete compatibility problem requires
them, rather than maintaining a separate guest system from the outset.

macOS 15 is the minimum so the project can test it directly on a maintained
Apple Silicon runner. The [macOS 14 runner retires on November 2, 2026](https://github.com/actions/runner-images/issues/13518).
Set the deployment target to 15.0 consistently for Rust and bundled C code.
Older macOS releases are outside the initial support commitment.

Release distribution will not use publisher signing or Apple notarization.
The normal ARM64 linker-generated ad-hoc signature needs no signing identity and
does not identify a publisher. Validate the actual Emacs download, verification
and execution route with normal macOS security settings. An isolated `spctl`
rejection does not establish that this route fails. If supporting macOS requires
publisher signing, notarization or weakening security settings, drop macOS from
the supported release targets rather than introduce those requirements.

The existing Emacs 30.1+ requirement still applies. Distinguish intended
compatibility, completed tests and known gaps in release documentation; do not
turn toolchain support or a proposed test route into a claim of passing tests.

Tagged releases use one shared version for the Rust executable and Emacs
package, starting at 0.32.0. This advances the current frontend version rather
than restarting its version sequence. Release tags use `vMAJOR.MINOR.PATCH`,
beginning with `v0.32.0`. Keep Cargo, the tagged Emacs package and Nix package
metadata aligned during release preparation. The current candidate is 0.33.1.
Ordinary Cargo builds report `VERSION-dev`; explicit `release-binary` builds and
the versioned Nix package report `VERSION`. This marker separates contributor
builds from release packaging; it does not prove a binary has been published.
The [release staging guide](../scripts/releasing.md) owns artifact names,
verification metadata and preparation commands.

Stage the complete binary set, Emacs package, artifact manifest and SHA-256
checksums in a draft GitHub release. Publish it with
[release immutability](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)
enabled, after checking the staged artifacts. Published assets and their tag
must remain fixed; corrections require a new version. Advancing a frontend pin
or release branch follows successful publication of the required assets.

Download binaries and their release-specific verification metadata over HTTPS
from the project's GitHub releases. Verify the selected artifact's SHA-256 before
running it, including before invoking `isled --version`, and reject missing,
invalid or mismatched checksums. Verification must not require users to install
extra tools. This trusts GitHub and the project's release process: checksums
distributed alongside the binaries are integrity checks, not independent
publisher signatures. Publisher signing and notarization are excluded by the
distribution policy above; checksum verification does not substitute for them.

Each frontend revision declares one known compatible published CLI release.
Tagged releases keep the shared release version: frontend 0.32.0 pins CLI 0.32.0.
Unreleased frontend revisions can retain that CLI pin while their requirements
remain compatible. Select that exact published CLI for managed downloads, using
the local cached copy when available. Do not search for an arbitrary latest
release or guess compatibility from a version range. This explicit pin keeps the
first release free of a compatibility matrix.

Check executable identity and version through `isled --version` before use.
An explicitly configured release executable, including a Nix-managed one, must
match the declared CLI pin too; report a different or unreportable version and
leave it untouched. Do not silently substitute a managed executable for an
explicit override. Explicit development builds remain a contributor workflow;
identify them as such rather than presenting them as published release binaries.

The first command that needs the CLI automatically downloads the pinned release
when it is not already cached, with progress and cancellation. No confirmation
prompt or stored consent is required: installing the frontend and invoking its
commands is sufficient. The same behavior applies after frontend upgrades.
A frontend update that retains the same CLI pin
reuses the existing binary. Keep executables in version-specific locations and
retain the previous binary so
rolling back the Emacs package can reuse it. If download, verification or
activation fails, preserve existing binaries and offer retry; the new frontend
waits for its matching executable instead of using an incompatible older one.
This managed upgrade policy does not replace or bypass an explicit executable
override. Package loading and compilation still perform no downloads. Any consent
files left by older frontends are ignored and left untouched.

Use direct Git installation through Elpaca, straight.el and package-vc for the
initial packaged release. Publish and verify the pinned CLI assets before
advertising those routes. MELPA submission and acceptance follow when its
requirements are met; they do not delay the first release. This gives users
normal package-manager installation while archive review is pending.

Use regular MELPA as the planned archive channel, with its recipe tracking a
`release` branch. Advance that branch to a tested release revision only after
the matching CLI artifacts and verification metadata are publicly available.
Development continues on `main`; it does not require publishing a binary for
every commit. This keeps ordinary package updates paired with available binaries
without maintaining a separate package archive. MELPA supports branch selection;
its [tree-sitter Rust component](https://github.com/melpa/melpa/blob/master/recipes/tsc)
uses this arrangement.

MELPA's generated package version is separate from the shared Isled release
version. Select the CLI using the explicit required version in the frontend,
never by interpreting an archive-assigned package version. Test the recipe
locally against real staged artifacts before submission. MELPA inclusion remains
subject to its maintainers' review; choosing the channel does not publish or
submit the package.

Keep CLI setup independent of the Emacs package manager. Package managers install
the Lisp files and declared dependencies; Isled provisions its CLI when a user
first invokes a command that needs it. Package loading, autoload generation and
compilation must not provision the CLI. Store managed binaries outside package
installation directories so package updates and removal do not erase them.

The frontend source carries its required CLI identity. Select the binary from
that identity, without inspecting the package manager, its generated metadata,
the checkout's branch name or Git metadata. Following the `release` branch, or
selecting a published release tag or its exact commit, therefore uses the same
first-use download and upgrade behavior as an archive installation. Unreleased
frontend revisions use that same setup with their declared compatible CLI pin.

Document and verify the archive route through `package.el` and representative
direct Git routes through
[Elpaca](https://github.com/progfolio/elpaca/blob/master/doc/manual.md#recipes),
[straight.el](https://github.com/radian-software/straight.el#the-recipe-format)
and built-in [package-vc](https://www.gnu.org/software/emacs/manual/html_node/emacs/Fetching-Package-Sources.html),
including their `use-package` integration where applicable. Recipes must select
the intended revision, include the frontend files and resolve its dependencies.
Keep runtime provisioning shared; package managers need no Isled-specific download
hooks. Other managers that install the same package should fit this contract,
but list completed installation checks separately from expected compatibility.
Exercise recipe differences with focused checks rather than multiplying the
native OS matrix by every package manager.

There will be no nightly releases. Lisp-only development can continue using a
known compatible published CLI. When the frontend needs new CLI behavior,
publish a CLI release with that behavior and update the pin before advancing
`main` or the `release` branch to the dependent frontend. The trigger includes
wire changes, new commands or fields and relied-upon fixes; an unchanged schema
number alone does not prove compatibility. The existing
[graph extension](../user-docs/frontend.md#dependency-layout), for example,
requires updated CLI behavior without changing schema 3.

Once the first CLI release is available, CI must exercise the frontend against
its pinned published binary as well as the repository-built CLI. Missing release
assets or a compatibility failure block publication of a dependent frontend.
An unavailable pin is a retryable setup error, not permission to choose another
version or compile automatically. Contributors changing Rust can still build
and explicitly configure a CLI from the same checkout; distinguish those builds
from published releases and document this source workflow separately.

Reliable platform builds and versioned release artifacts must precede the
package-managed installer and clean-system installation/upgrade checks.

Deliver this as one sequence: release contract, native CI, versioned artifacts,
archive preparation, Emacs-managed installation, clean-install/upgrade acceptance,
then publication. Check archive constraints during the initial design, but complete
archive preparation against real staged artifacts. This keeps each step grounded
in the preceding result and leaves final acceptance to the integrated package.

Bootstrap the first release without requiring it to be public before acceptance.
Initial native CI tests the repository-built CLI. Packaging then supplies real
staged archives for recipe preparation and installer validation. Once the installer
is integrated, rebuild the complete candidate from one final revision and test
the actual staged files through an isolated download source. Exercise the normal
verification and setup path; do not bypass it with a preinstalled executable or
weaken the production download policy. Upgrade and rollback checks can use two
locally staged versioned builds before any public release exists.

Publication owns the final external steps: enable release immutability, publish
the complete validated draft, verify anonymous downloads and the live installer
path, then advance the distribution branch for direct Git installation.
Activate ongoing frontend checks against the pinned published CLI at that point.
Submit the MELPA recipe later, once its public-history and maintainer-review
requirements are met, and verify archive installation after acceptance.
The staged checks establish prepublication acceptance; the live checks establish
that the public endpoints deliver those same artifacts. Preserve this distinction
in the release evidence, and use a new version if a published artifact needs a fix.

Nix stays optional. Respect explicitly configured executables and retain manual
binaries and source builds as alternatives. The shared installer is implemented;
user instructions lead with public packages and managed first-use setup.
Source-development configuration lives in the contributor guide. Explicit source
builds opt into the matching `-dev` identity through `isled-use-development-cli`.

### Shared CLI and skill installation

Distribute the complete [agent skill](../skills/isled/SKILL.md), including its
reference files, beside the executable in each CLI release archive. Keep both
from the same release together. The v0.32.0 archives contain only the executable and license and remain
immutable. The 0.33.0 candidate implements this layout; native release acceptance
and publication remain separate. See the [installation guide](../user-docs/installation.md)
for commands and storage paths.

Standalone and Emacs-managed installations share a default per-user storage
directory outside Emacs's own directories, using the platform's application-data
location:

| Platform | Default installation root | Directory convention |
| --- | --- | --- |
| Linux | `$XDG_DATA_HOME/isled`, normally `~/.local/share/isled` | [XDG Base Directory Specification](https://specifications.freedesktop.org/basedir/0.8/) |
| macOS | `~/Library/Application Support/isled` | [Application Support](https://developer.apple.com/documentation/foundation/url/applicationsupportdirectory) |
| Windows | `%LOCALAPPDATA%\isled` | [Local AppData known folder](https://learn.microsoft.com/en-us/windows/win32/shell/knownfolderid) |

Use the [`dirs` crate's `data_local_dir()`](https://docs.rs/dirs/latest/dirs/fn.data_local_dir.html)
and append `isled` to its result. Delegate platform selection, environment handling
and OS directory lookup to the crate. The table describes its expected locations,
not a separate lookup implementation to maintain. If it cannot find a directory,
report the failure and explain the explicit `--directory` option. Explicit
destinations take precedence. The CLI owns this resolution for both entry points
so Emacs and standalone installs agree for the same environment.

Retain each release in a versioned directory, with a single `current` directory
link selecting the active bundle:

```text
isled/
  versions/
    VERSION/
      isled                  # isled.exe on Windows
      LICENSE
      bundle.json            # complete payload hashes and identity
      skill/
        SKILL.md
        references/
  current -> versions/VERSION/
```

Users add `current/` to PATH and configure their agent to use `current/skill/`.
Both CLI installation output and Emacs installation completion must show the
full absolute executable path through `current/isled` (`current/isled.exe` on
Windows) and the full absolute skill directory path through `current/skill/`.
Also identify its `SKILL.md` entry point and the `current/` directory to add to
PATH. Preserve `current` in these displayed paths; do not resolve the link to a
versioned location. Explain that these are the stable paths to use in shell and
agent configuration, and make them easy to copy and retrieve again in both
interfaces. Emacs must not rely solely on a transient minibuffer message.

Users can select fixed versioned paths when they want to pin their setup.
This avoids maintaining exported copies in arbitrary agent directories. Updating
files cannot refresh instructions already loaded in an agent conversation;
document when the agent needs to reload the skill or start a new session.

The CLI owns local bundle installation through `isled install`, with an
optional `--directory` destination. Standalone users download and extract a
release, then run its executable's installer; upgrading repeats that flow using
the new release. The extracted bundle also remains directly usable. Initial
scope does not include an automatic downloader/updater in the CLI. Installation
needs no administrator privileges and does not edit shell or agent configuration.

Emacs downloads and verifies its exact compatible release, then calls the same
CLI installer. Preserve automatic first-use downloads, offline reuse and explicit
executable overrides. Emacs continues executing the exact versioned path so
another installation changing `current` cannot change its selected CLI.

For existing Emacs installations using the old default storage location, put
new releases in the shared directory and leave the old cache available for
rollback. Do not move or delete that cache automatically. Honor explicitly
configured storage locations and keep externally managed executables intact.

Prepare and verify the complete bundle before switching the single `current`
link. Keep prior versions for rollback and preserve the previous active bundle
on failed installation. `current` denotes the deliberately activated release,
including a rollback; it does not select the highest version found on disk or
an arbitrary latest GitHub release. The one directory link avoids independently
switching the executable and skill, but does not pin separate reads across an
upgrade or refresh a running agent's context.

Use a directory symlink on Linux/macOS. Windows must support ordinary users
without elevation or Developer Mode; a directory junction is the candidate
mechanism, with creation, switching and failure recovery to be validated natively.
Do not claim atomic replacement or cross-platform acceptance before those checks.

The managed `current` layout applies to release bundles and Emacs-managed
installation. Source installations through Cargo remain manually managed;
users take the matching skill from their source checkout. Nix packages the
complete skill alongside the executable and retain responsibility for updates.
The new installer does not manage or replace Cargo or Nix installations. Document
where each route supplies the skill without making source users adopt the managed
release layout.

Implement the archive transition in a new release, coordinating its packaging,
verification and matching frontend pin. Native acceptance must cover both managed
entry points, complete skill contents, interrupted installation, upgrades,
rollback and an older CLI still running while `current` changes. Verify that both
installation interfaces report the usable executable and skill paths through
`current`, including after an upgrade and with a custom installation directory.
Update live help, user guides and release instructions when these behaviors
become available.
