# Emacs frontend

This directory contains the Emacs 30.1+ browsing frontend for
`isled`. Rust owns ledger discovery and issue semantics; the package
consumes `isled frontend --stdin` and renders typed results as
indexed, expandable text rows. Expanded canonical content receives `markdown-view-mode`
presentation properties without being parsed for issue data in Emacs:
decorative markup is hidden, list markers use display bullets, and headings,
emphasis, code, and links retain theme-aware faces.

## Getting started

After [installing the package](#package-archive), visit a file or directory inside
a project and run `M-x isled` for its ledger, or press `C-x p i` to choose
a project. Use `M-x isled-open-directory` for any other directory.
The shortcut and [issue-file routing](#opening-issue-files) are registered
automatically without loading the browser until needed. Existing bindings are preserved; see [key binding configuration](#key-binding)
to change it. Loading directly from a checkout needs the small
[source setup](#local-configuration) below.

| Key | Action |
| --- | --- |
| `C-x p i` | Choose a project and open or return to its view. |
| `C-u C-x p i` | Choose a project and create an additional independent view. |
| `f` in an issue view | Filter issues by status, tags, kind or text. |
| `v` | Toggle hierarchical/flat presentation. |
| `d` | Reverse dependency direction in hierarchical mode. |
| `g` | Refresh, keeping the current query. |
| `j` | Jump to an issue by ID or title. |
| `?` | Show the available commands and their keys. |

Emacs notation means `C-x p i` is a sequence: hold Control and press `x`, release
Control, then press `p` and `i`. `C-u` supplies a prefix argument before that
sequence. The `f`, `g`, and `?` bindings above are local to the issue view.

Start with [filter examples](#filter-examples), choose your preferred
[completion interface](#completion-interfaces), or read about
[navigation and folding](#navigation-and-folding). `f` filters issue records
through Rust; ordinary `C-s` searches text already present in the Emacs buffer.
See [buffer search and preview](#search-and-preview) for folded-body behavior.

## Dependency graph view

Hierarchical mode is enabled by default. Press `v` to switch between hierarchical
and flat presentation of the same selection. Flat mode lists issues in ID order
without a dependency gutter. Switching preserves the query, selected issue and
expanded bodies; returning to hierarchical mode restores its last direction.
Filtering, status shortcuts and navigation work the same way in both modes.

Hierarchical mode displays existing wait relations. Every selected issue appears
once; titles stay aligned beside a gutter showing branches and joins. Long chains
run vertically. Readiness colors and body expansion retain their meaning. The
initial direction is prerequisites first; press `d` in hierarchical mode to reverse
it while preserving the query and selected issue when present.

`O`, `C` and `A` choose Open, Closed or All, preserving other query terms. Status
selection is strict: Open never adds closed issues as context. Press `f` for the
ordinary [filter prompt](#issue-filtering), with live previews and completion;
`RET` keeps the query and `C-g` restores the original view. Only matching issues
appear. An edge appears only when both endpoints are selected; hidden intermediates
are never replaced by invented edges. Following an issue outside the selection
uses normal navigation; Back restores the previous query and direction.

The gutter uses `•` for an issue independent within the status selection, `○`
for a connected issue, and `│` for a continuing dependency. When tag, kind or text
filters hide direct neighbors, the circle remains without adding notes to the
heading. Connections outside Open/Closed/All do not affect this distinction;
reversing direction preserves it. A visible root with a filtered prerequisite may
still be blocked; readiness colors remain authoritative.

For example, `s:open t:rust timeout` shows only open Rust-tagged issues containing
`timeout` anywhere in their complete record. Rust computes matching, omitted
connection counts and layout without requiring Emacs to load every body. Full-text
matching may still scan candidate records in Rust. Ordinary `C-s` retains its
[buffer-only search scope](#search-and-preview). The header shows the complete query
and the active presentation or dependency direction.

Each connected group of visible issues stays together; groups and independent
issues are placed by their smallest issue ID. Independents can appear before,
between or after groups, but never interrupt a thread. Within a group, dependency
order takes precedence and newly unblocked branches are followed first, preferring
narrower branches and then issue ID when several become ready together.

Relations excluded by status do not affect the marker, so changing Open/Closed/All
can change a dot to a circle or vice versa. Multiple roots feeding a shared dependent
all keep their circles. Column one is reserved for starts in the displayed direction,
including independent issues; connected threads move into higher columns and stay
there through their ends.
Consecutive circles in an active higher lane form a straight chain. A separate
connector line appears only for a horizontal route, using rounded corners and
T junctions (`├`, `┤`, `┬`, `┴`). Merges and splits use separate lines; there are
no four-way junctions. Sources with identical destinations can share a segment,
preserving every direct dependency. At an unavoidable crossing without a join,
the horizontal stroke interrupts the vertical stroke for that line.
Column placement distinguishes chains from independent issues even when
all bodies are folded. Connectors continue beside expanded bodies and
wrapped lines. Body panels remain to the right of the gutter. Folding changes vertical
spacing without recalculating lanes. Very wide graphs may look awkward or extend
past the window. When the gutter itself is at least as wide as a displaying
window, the buffer temporarily truncates lines to avoid unusable wrapping;
normal wrapping returns after widening the window or filtering to a narrower graph.
The initial view does not compact lanes or omit relations.

In the Open prerequisites-first view, ready work normally appears in column one;
closing a prerequisite moves the next unblocked issue there. Column one denotes
a visible graph root, while readiness colors reflect the actual ledger. All or
Closed selections, additional filters and unavailable blockers can make those meanings differ.

Rust computes the complete logical layout from selected metadata, independently
of loaded bodies. Emacs retains that plan and paints glyph strings only near
visible windows; offscreen rows preserve both gutter width and routing height
with spacing placeholders. Connector lines have real buffer positions outside
foldable bodies, so ordinary line-by-line scrolling can place them at the window
top without blank or stuck rows. Painting changes display properties without
inserting text or moving rows. Bodies continue using bounded loading.
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

## Known warnings

The header shows a compact clickable **⚠ Known warnings** indicator whenever Rust reports
a retained issue finding, including on issues hidden by the current filter.
Click it, press `!` in the ledger buffer, or choose **Known warning** in the Help menu to reveal a
warning. Repeating the action advances through warnings in issue-ID order,
including multiple warnings within one issue, and wraps after the last. Unreadable records lead to their ledger
diagnostic and existing file actions. `M-,` restores the starting filter, folds
and position through ordinary jump history. Consecutive duplicate destinations
coalesce in the shared history API; jumping to the current location adds no entry.
Delayed navigation keeps the existing
window and cursor-movement fences.

The indicator stays visible while scrolling and has no adjacent button. It
disappears when the last known finding clears. Its absence is not
a whole-ledger health certificate. The [shared cache contract](../../user-docs/cache.md#known-warnings)
owns retention, neighbor rechecks and excluded temporary failures.

## Navigation and folding

Press `j` (`isled-jump-to-issue`) to choose a readable issue by ID or title from
this ledger, including closed issues and issues hidden by the active filter.
Completion shows titles and status through the configured minibuffer framework;
short numeric IDs with an optional `#` are accepted too. Choosing an issue reveals
and expands it through the shared navigation API. `M-,` restores the starting
filter and position. Canceling or entering an unknown ID leaves the view alone.
The metadata request is asynchronous; moving away before it returns cancels the
prompt. This command does not select a different ledger or create issues.

Expanded issues with Rust-generated relation diagnostics show a compact
theme-aware `Warnings` section above their stored content. This generated block
and its indentation do not use the expanded issue body's background; stored
content retains its usual background. Controls and gutter remain unchanged.
These are local checks, not a whole-ledger audit. Related existing IDs use
normal issue navigation and history; absent IDs are non-actionable. Generated
warnings are separate from canonical content and disappear after a fresh payload
no longer reports them. Rust automatically corrects stale copied titles before
rendering; no relation is silently added or removed. Missing mirrors offer
`[Complete relation] [Remove relation]` on both endpoints. Completion prompts
for a reason if only the Blocking half survives. Missing targets offer
`[Remove relation]`. Either surviving half still blocks readiness when its
blocker is unresolved or unavailable.

Unreadable files appear separately with the actual error and
`[Open file] [Move to trash]`, also available beneath related warnings.
The ledger-wide list occupies a conditional `Ledger warnings` area above the
issues, using a theme-aware `header-line`-derived background distinct from the
expanded-body face. Two uncolored left margin columns precede two columns of
inner padding; wrapped lines keep that inset. An uncolored blank row above the
area, blank inner rows above and below,
and an uncolored separator keep it distinct from the issue list. No area or
spacing is inserted when there are no ledger-wide diagnostics. This presentation
does not change warning scope or recovery actions.
Diagnostic details and their controls are inset two further columns beneath
`Ledger warnings`, including wrapped lines, without shifting the background.
Opening uses an ordinary editable file buffer; trashing confirms the exact
path and refuses non-regular files or symlinks. Relations remain until explicitly
removed. These narrowly scoped recovery actions are the only issue mutations
in this otherwise browsing-oriented frontend. Buttons use the same TAB/S-TAB,
RET, and mouse navigation as links. After a successful action, point lands on
a remaining warning in the same issue (next in order when available, otherwise
the last), or its heading when none remain. A ledger-level action instead lands
on the next available recovery control or the start of the view. Failures keep
the current view and report the error.

Refresh retains issue-relative screen anchors rather than obsolete absolute
buffer positions. Action refresh prefers the affected issue's heading as its
anchor. Keeping that issue at the same screen position is best effort: buffer
bounds and keeping point visible take precedence; no blank rows are invented
above the beginning of the buffer. Ordinary notification refresh uses the same
anchoring so the follow-up filesystem event does not undo the position.

`TAB` and `S-TAB` move between issue headings and
actionable targets in expanded bodies. `C-TAB` and `C-S-TAB` move directly to the
next or previous issue
heading, skipping links and the rest of the containing issue without wrapping.
These distinct key events target graphical Emacs; terminal support varies.
Cursor keys retain ordinary character-precise movement.
`RET`, `M-.`, and mouse-2 select and expand an
existing referenced issue in the same buffer, switching the open/closed filter
when required, retaining All when active. `M-.` is issue-reference-only and reports when point is not on
one. These jumps use semantic history belonging to each window/view pair: `M-,` goes back,
`C-M-,` goes forward, and a new issue jump after going back discards the
forward branch. History restores the opaque filter view, including selection,
expansion, and issue-relative point, through the same boundary used by filter
memory; refreshed or removed issues therefore use its normal restoration
fallbacks. Other Markdown file navigation remains in Emacs's buffer history.
Routing adds no global xref or mark entries; link callers retain their own
ordinary history behavior.
Back/Forward restores the saved filter and folds in the shared view buffer,
affecting all windows displaying it; other windows retain their semantic
positions where possible and keep their own histories. Navigation memories
survive ordinary buffer switches and are detached when a window or view dies.
Delayed navigation applies only while its originating window still displays
the view at the expected point, and never steals focus from another window.
Markdown links resolve relative to the canonical issue file. Plain local issue
file targets use [issue-file routing](#opening-issue-files); other targets retain
Markdown's normal behavior. Missing issue references remain non-actionable. Away
from a target, `RET` toggles the containing issue. `C-RET` collapses all issues
in the current view; there is no expand-all menu action. `n` and `p` no longer
navigate. Explicit `M-x isled-open` still opens the record read-only.
Explicit toggles and issue-reference jumps make a best-effort, minimal scroll
adjustment in the invoking window to show the expanded issue. If the issue is
taller than the window, point stays visible and takes priority over showing the
whole body. Fitting uses Emacs display geometry, including wrapped lines, and
does not move point or adjust other windows. If details arrive later, fitting
is retried only while the originating window still shows this view with unchanged
point and scroll position; navigating away cancels fitting, not body delivery.
When automatic fitting changes that window's viewport, folding the same issue
restores its original pre-fit viewport while point and scroll remain unchanged.
Delayed body delivery and further automatic fits retain that first viewport.
Any intervening point movement or scrolling, including moving away and back,
cancels restoration, as do full refresh, filter change and window resize. Point
visibility and buffer bounds take precedence over exact restoration. Fitting and
restoration remain per-window even though folds are shared by a view buffer.
Filter previews and history restoration retain their existing positioning.

Each window/view pair remembers, per filter, only its most recently collapsed issue and issue-relative
cursor position. Expanding that issue again restores point, clamped if its body
has shortened after refresh. Collapsing another issue replaces that filter's
memory; `C-RET` clears only the active filter's memory. This is window/view-local
filter memory, independent of jump history, not a per-issue position cache.
Matching row identities are updated in place during refresh and detail delivery.
Unchanged bodies and their presentation are retained, preserving external markers
and avoiding repeated Markdown work. Structural membership or ledger-diagnostic
changes rebuild the list and use the established semantic anchor restoration.

<a id="issue-search"></a>

### Opening issue files

Opening a well-formed local `.issues/NNNN-name.md` file reveals and expands its
issue in the target ledger's most recently used view. This includes ordinary
`find-file`, other-window/frame variants, Markdown and Org file links, and
agent-shell file links. Routing uses the window selected by the original open
operation; it does not introduce another split. Other independent views keep
their filters and browsing state. When the target is outside the current filter,
normal issue navigation reveals it, and `M-,` restores the preceding filter,
folds and position.

The originating buffer stays visible while Rust validates the complete record
and canonical identity asynchronously. A successful route opens the ledger view
without visiting or creating a Markdown file buffer. Invalid records or
validation/executable failures use the original file-opening command and show a
brief explanation. Opening never initializes a ledger. Moving away, editing the
origin, opening another file, or changing the destination view cancels stale
navigation. Existing modified issue-file buffers open as Markdown with their
drafts intact; already open, unmodified file buffers are preserved.

For agent-shell links, ledger views use `agent-shell-file-display-action` when
available, including its no-display setting; standalone agent-shell Markdown
uses the current window. Its path-based file callback is used for source links
and validation fallback. Org retains application selection and its configured
standard file-window/frame command. Recognized opens complete asynchronously;
callers needing a file buffer must continue to use `find-file-noselect`.

Explicit source-line destinations (including agent-shell line/column arguments)
and fragment links such as `issue.md#statement` retain the caller's normal
Markdown navigation. Remote files and symlinks, including symlinked ancestor
directories, never route. Background `find-file-noselect` calls still return
ordinary file buffers; arbitrary third-party display functions need their own
adapter. The `s` action and explicit source/recovery commands always open source.

Routing is enabled by `isled-setup`. Disable it at any time with:

```emacs-lisp
(setq isled-file-routing nil)
```

### Open Markdown source

Press `s` in an issue heading or body, or choose **Markdown source** under **Read** in
`?`, to visit that issue's canonical file in the current window.
The action uses `switch-to-buffer` and does not split the window. The command
`isled-open-source` is also available for personal bindings, for example
`(keymap-set isled-mode-map "s" #'isled-open-source)`.
The Transient menu closes before the file is displayed.

Existing file buffers retain their point, unsaved edits and read-only state.
A newly visited file starts at its heading. Malformed source opens normally for
repair; a missing or renamed file reports that source is unavailable without
creating an empty file. Away from an issue, the command reports “No issue at
point”. File permission errors and read-only files use ordinary Emacs behavior.
Saving uses normal Emacs file saving; existing issue-view notifications and
refresh pick up the result. The action does not save, repair or validate content.

This is raw Markdown access, distinct from future structured issue editing.
It dynamically binds `isled-inhibit-file-routing` while visiting and
displaying the source; automatic issue-file routing honors that bypass.

## Add, edit and close issues

Use `a` (`isled-add-issue`) for a new draft and `e` (`isled-edit-issue`) for the
issue at point. The editor uses a separate split, respects `display-buffer-alist`,
and reuses an existing draft of the same issue across ledger views. New drafts
start at Title, are independent and receive an ID only on a successful save. The usual header
shows ledger/issue identity, draft state and a persistent Help hint. It marks
unsaved drafts, failed saves and changes on disk without taking over the keys.
Statement starts with at least three display lines and grows with its content;
its extra display space does not add whitespace to the issue.

Editable fields have customizable `isled-editor-field` and
`isled-editor-active-field` faces with contrasting light/dark colors and visible
blank field space. Separate tags with spaces or commas (for example, `hello coucou` or
`hello, coucou`). Empty Kind and Tags fields offer existing ledger values on TAB.
Errors are selectable, copyable protected text outside field values; labels remain
protected while ordinary cursor movement and copying remain available. Edit title, kind, tags, Statement,
Evidence entries, Outcome and dependencies in either direction. Kind/tag
completion accepts new valid names. Use `#` for issue completion in Title,
Statement, Evidence and Outcome; accepting an ID ends that reference so following
spaces and prose do not restart it. Adding Evidence or a relation focuses the new entry. Removing an entry stays
on a neighbor, or its section’s Add button when none remain. Re-rendering retains
the current field and offset when it still exists.
Field text uses a consistent normal weight; the active background indicates focus. Outer Statement whitespace is trimmed for validation and saving; internal
Markdown whitespace remains intact. Repeated tags save once, in first-occurrence
order, and completion omits tags already entered. Empty Evidence saves as Pending.
Ordinary editing never closes an issue; status is informational.

- `C-x C-s`: save and keep editing.
- `C-c C-c`: save and return to the issue in the ledger.
- `C-c C-k`: cancel unsaved edits after confirmation; earlier saves remain.
- `C-TAB` / `C-S-TAB`: next/previous field or button; commands can be rebound.
- `TAB`: completion, or indentation in multiline bodies; it never inserts a tab
  into a single-line field. `C-c ?`: Transient help below the selected editor
  window, with the same placement and dismissal behavior as ledger help.
- Revert draft: reload the saved issue, or reset a new draft after confirmation.

Rust validates after `isled-editor-validation-delay` idle seconds without
publishing or allocating. Errors appear beside fields without entering issue
text; old replies cannot replace newer edits. Failed saves leave point and scroll
context in place, show a brief minibuffer explanation and retain a header marker.
Use Next error in Help to move explicitly to a diagnostic. A stale save offers
Compare, Revert (reload) and confirmed Overwrite in Help; it does not open the
menu automatically. Save rechecks under the ledger lock. Overwrite checks
that the confirmed version has not changed again. Modified Markdown source
buffers must be dealt with before a structured save; they are never auto-reverted.
Uncertain or partial saves preserve the draft and require inspecting/reconciling
saved state before retrying, especially after creation.

Open drafts subscribe to the ledger's shared directory watch, including while no
ledger view remains. After a coalesced notification (or the existing polling
fallback), Rust checks the saved version. A difference marks Changed on disk;
it never replaces the draft or advances its baseline. Failed checks are visible
in the header. This follows the ledger's automatic-refresh setting and remains
best effort; save-time version checking is authoritative.

Issue completion matches IDs or titles in the current ledger; prose references
insert `#NNNN` and do not create dependencies. Local Markdown link targets complete
relative to the ledger root. Standard completion-at-point metadata supports stock
Emacs, Corfu and Company without requiring those packages or changing preview
visibility settings. On request, documentation shows up to 16 KiB of the selected
local issue's Markdown; no web links are fetched.

The [draft wire contract](../../user-docs/editor.md) owns Rust save semantics.

Use `c` (`isled-close-issue`) to prepare closure in the shared editor. Existing
unsaved draft fields are retained. Point starts at Outcome, the header says
Closing issue, and status shows Open → Closed until save succeeds. In this mode,
`C-x C-s` saves and closes while staying; `C-c C-c` saves and closes then returns.
Cancel leaves the saved issue open. Revert confirms discarding edits, reloads the
saved fields, keeps closing intent and returns point to Outcome. After successful
closure the buffer becomes an ordinary editor for the closed issue. Rust enforces
Evidence/Outcome and stale-save rules before any publication.
Implementation responsibilities: `isled-editor-model.el` owns state/wire decoding,
`isled-editor-form.el` fields/diagnostics, `isled-editor-completion.el` completion
and bounded documentation, `isled-editor-feedback.el` header/save/watch feedback,
and `isled-editor.el` lifecycle/save coordination. `isled-session.el` retains
one watch until its last view or draft subscriber leaves.
The editor ERT suite covers draft validation, save/conflict handling and lifecycle
boundaries with disposable fixtures.

## Issue filtering

Press `f` (or use Filter issues in `?`) to edit the complete current query in
the minibuffer. Initially Open prefills `s:open `, Closed prefills `s:closed `,
and All has no status term. Filtering combines all terms with AND:

- `t:rust` requires the tag; `k:bug` requires the kind.
- `s:open` or `s:closed` sets status. In manually typed queries the last status
  term wins. Selecting a status through completion replaces all status terms,
  keeping other terms in their original order. No status term means both statuses;
  there is no `s:all`.
- Ordinary words match case-insensitively anywhere in the complete Markdown
  record, including title, Statement, Evidence, Outcome and relation reasons.
  Words may occur in different sections. `"two words"` matches a literal phrase.
- Recognized unquoted prefixes always mean filters. Quote `"t:rust"` or `"t:"`
  to find that literal text. Empty structured values and unfinished quotes need
  completion before the query can be accepted; they leave the last results visible.

<a id="search-examples"></a>

### Filter examples

These examples are complete queries; replace the current minibuffer text to try
one. Leaving `s:open` in place continues to restrict results to open issues.

| Query | Find |
| --- | --- |
| `s:open t:rust` | Open issues tagged `rust`. |
| `k:bug` | Bugs with either status. |
| `s:closed "disk full"` | Closed issues containing the phrase `disk full`. |
| `t:rust t:emacs startup` | Issues with both tags and the word `startup`. |
| `"t:rust"` | The literal text `t:rust`, rather than a tag filter. |

Remove every term for an unfiltered view. Remove just `s:open` or `s:closed` to
include both statuses while keeping the other terms. Status values are `open`
and `closed`; there is no `s:all` term. To keep refining an existing filter,
press `f` again: its text is prefilled with a trailing space ready for another term.

Rust owns matching and returns compact summaries. Results preview asynchronously
while typing, keeping the current display until a valid current reply arrives.
Edits coalesce while a request runs; obsolete replies cannot replace newer input.
`RET` keeps the full input. `C-g` cancels the filter and restores the previous query and
position and rejects abandoned replies. Text filters read metadata-selected
candidate records; there is no new filter cache or response-time guarantee.

### Completion interfaces

A short syntax hint stays in the invoking view's header while the prompt is
active. Completion offers tags inside `t:`, kinds inside `k:`, statuses
inside `s:`, and all structured choices between terms. Choices come only from
readable cached issues matching the other provisional AND constraints, including
words and quoted phrases. The exact token being edited is excluded; duplicate
terms elsewhere still constrain choices. Status choices ignore all existing
status terms, matching their replacement behavior. When no readable issue matches,
there are no choices. Quoted tokens stay literal.

Use `M-x customize-option RET isled-filter-interface RET` to choose
and save your preferred interaction:

| Choice | Behavior |
| --- | --- |
| **Inline suggestions** (default) | Suggestions appear automatically for the token at point. Uses Corfu when it owns completion, or the standard Emacs completion window when stock completion owns it. Other completion UIs retain control. `TAB` also completes explicitly. |
| **Separate filter picker** | `TAB` immediately opens an ordinary completion prompt for one structured token, showing “Loading choices…” until a pending reply arrives. Choices update automatically; `RET` inserts one and `C-g` returns to the unchanged filter. Uses Vertico when enabled. |
| **Minibuffer suggestions** | Shows ordinary minibuffer choices while editing the whole query. `TAB` inserts a selected Vertico candidate while keeping later terms. Uses the standard completion window when stock completion owns the prompt. |

For example, to select the separate picker:

```elisp
(use-package isled
  :custom
  (isled-filter-interface 'separate-filter-picker))
```

To require TAB before inline suggestions appear, set
`isled-filter-inline-auto` to nil with `M-x customize-option`, or use:

```elisp
(setq isled-filter-inline-auto nil)
```

It defaults to t. The setting controls opening only: an open completion UI still
updates its choices and previews highlighted candidates. Dismissing it in manual
mode keeps it closed until another TAB. A TAB pressed while choices are pending
opens suggestions when that exact input's reply arrives. This affects only inline
filter prompts; other filter interfaces and global completion settings are unchanged.

The other values are `inline-suggestions` and `minibuffer-suggestions`.
When whole-query suggestions are selected with an unsupported completion reader,
that invocation uses the existing separate filter picker: edit the query normally
and press TAB to choose one token through your native completion UI. The saved
`isled-filter-interface` preference stays unchanged.
`M-x isled-filter` opens the same prompt as `f`. The former command
`isled-search` and option `isled-search-interface` remain
compatibility aliases for existing configurations.
All three work without optional completion packages. In the stock completion
window, `M-v` selects the window and `RET` inserts a choice while leaving filter
open; `RET` back in the filter prompt keeps the complete query. In the separate
picker, this accepts the inner token prompt first. Choices resize with normal
Emacs window rules. Dismissing inline or minibuffer suggestions keeps them closed
until the input or point changes. Type a space after completing a term to continue.
If a completion popup or the separate picker is active, `C-g` may dismiss that
first; press it again in the outer filter prompt to cancel the filter itself.

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

In an owned stock, Vertico or Corfu completion session, highlighting a candidate
also previews the results that inserting it would produce. The typed query and
completion choices stay unchanged. Dismissing suggestions restores typed-query
results (or the last valid view for incomplete input); cancelling the entire
filter restores its original view. Inserting a candidate and accepting the full
query keep their usual meanings. Candidate observation runs only while the filter
prompt is open, with a short delay; the existing request queue coalesces rapid
movement and rejects obsolete results. Other completion frameworks receive no
highlight adapter or forced stock popup. Their settings and ordinary completion
outside the filter prompt remain unchanged.

Contextual completion stays independent of optional completion frameworks;
measure query and presentation costs separately when changing it.

Open/Closed/All commands replace or remove only status when a filter is active;
tag, kind and text constraints survive. Duplicated views copy the whole query
and then remain independent. Following a reference outside the results opens its
status view without the filter constraints; Back restores the full prior query,
folds and position. References already in the results retain the query.
`g` and automatic refresh retain the current query. Native buffer filter and
fold previews remain separate from Rust issue filtering.

<details>
<summary>Completion package compatibility details</summary>

Inline suggestions use public Corfu settings locally; they do not change global
completion settings. Minibuffer suggestions use a local `basic` completion style
for this query category because Orderless does not respect the cursor position
inside a whole query. Its Vertico insertion adapter also calls Vertico's internal
refresh function to prevent stale selection during queued input. The separate
picker needs no Vertico-specific code. These details do not affect other prompts.

</details>

## Search and preview

Ordinary buffer search covers headings and materialized bodies. Once a body has
been displayed, collapsing it retains its text for search. Bodies that have
never been materialized are not in-buffer search candidates; search does not
fetch the whole ledger. A new filtered view need not materialize its cached but
never-displayed bodies just to search them.

Temporary search/preview reveals use standard Emacs invisible-overlay hooks.
They change visibility without changing logical expansion or requesting fresh
details for that issue. Moving away or cancelling restores its fold; accepting
the match opens it normally and permits bounded revalidation. Consult/Vertico
are optional user tools, not frontend dependencies.

<a id="customization"></a>

## Customization

The frontend uses ordinary Emacs faces for colors, font family, size, weight,
slant, underlining and other text attributes. Use the
[appearance faces](#theme-and-identity-styling) for visual changes and the
[keymap guide](#key-binding) for the project shortcut, issue-mode keys, command
remapping, and load-order-safe examples. The package adds neither a separate
binding framework nor individual options for face attributes or keys.

<a id="theme-and-identity-styling"></a>

### Theme and identity styling

Expanded bodies hide the canonical first-line title without deleting its text
or parsing Markdown. The current open-right panel experiment embeds the expanded
title in a subdued `┌──` top border. The title has no colored background;
one space of padding and one additional margin space remain on each side.
The remaining rule extends to each
window's right text edge at redisplay time. Wrapped title rows continue the
left vertical rather than repeating the corner. Collapsed headings remain plain.
Set `isled-title-background` to non-nil to color expanded titles and
their inner padding; the default is nil. The body background and outer title
margins are unaffected. Refresh with `g` after changing the option, or toggle
a section to apply it there.
There is no separate underline row or outside top margin. The boundary prefix
is cleared when folded so it cannot affect the next heading.
The background is inset two columns; inside it, text has one column of left
padding and a blank line above and below. Wrapped lines use the same left inset.
The top padding line shares the body's inset.
Adjacent expanded issues retain a background-free separator regardless of
expansion order.
Panel corners and the right rule are anchored to each title's overlay so
folding a neighbor cannot suppress the opening corner during redisplay.
The current bracket experiment places a subdued, theme-aware `│` in the first
column on body and wrapped lines, ending with `└────` on the bottom
separator. These are display prefixes, not issue text or navigation targets.
There is no right padding. The trailing outside blank line is retained. Display
properties preserve authored text and reference coordinates.
Markdown headings stay at the padded body edge; their content, including bullets
and wrapped lines, is inset two more columns without shifting the background.
Heading recognition is reused from Markdown mode, not a second Markdown parser.
Expanded bodies use a distinct `mode-line-inactive`-derived background. The
body face borrows only that face's background and leaves its foreground
unspecified, so ordinary prose and Markdown syntax retain their normal theme
faces. A direct customization of `isled-expanded-body-face` remains
authoritative, including across theme changes.
Issue IDs, titles, filters, Markdown syntax, expanded-body backgrounds, and the
persistent help hint all inherit standard Emacs or dependency faces, so the
active theme owns their actual colors. The hint's activation key, brackets,
and description use three distinct semantic faces for restrained contrast.
Live font locking is disabled in the generated buffer because
expanded Markdown bodies arrive with stable display faces already applied.
Section headings display the Rust-provided ID using canonical compact-reference
spelling such as `#0001`. Only that complete spelling is state-colored: ready
uses semantic success, waiting uses link color without an underline, and
closed uses struck-through shadow. The adjacent title retains the ordinary
heading face. Between ID and title, headings show the Rust-provided kind, for
example `#0007  [maintenance] Review the backup procedure`.
Kind text inherits `font-lock-type-face`; its brackets inherit `shadow`, both
at normal weight without a badge background or per-kind color palette. The
active theme supplies the colors. The label remains visible when expanded and
is part of the issue heading, not a separate navigation target. Custom kinds
are displayed verbatim. The executable must provide the snapshot `kind` field;
the frontend does not derive classification from Markdown content.

Customize one face interactively with, for example, `M-x customize-face RET
isled-issue-title-face RET`, or browse them together with `M-x
customize-group RET isled RET`. Customize writes standard face
settings, which apply whether the browser is already open or loads later.

The same settings can live in a `use-package` declaration. This example changes
both colors and typography; `Monospace` is the portable generic fixed-width
family name:

```emacs-lisp
(use-package isled
  :custom-face
  (isled-expanded-body-face
   ((t (:background "#20242b" :foreground "#e6e6e6"
        :family "Monospace" :height 1.1 :weight medium))))
  (isled-issue-title-face
   ((t (:foreground "#5fafff" :family "Monospace"
        :height 1.15 :weight semi-bold))))
  (isled-ready-issue-id-face
   ((t (:foreground "#5faf5f" :weight bold)))))
```

Themes use the same faces. Place forms like these in a theme definition after
its `deftheme` form:

```emacs-lisp
(custom-theme-set-faces
 'my-theme
 '(isled-warning-face
   ((t (:foreground "#ff5f5f" :weight bold))))
 '(isled-expanded-body-face
   ((t (:background "#303030")))))
```

Without an explicit background, `isled-expanded-body-face` follows the
active theme's `mode-line-inactive` background. Explicit Customize, theme,
`use-package :custom-face`, and direct face settings take precedence and survive
rendering, refresh, theme changes and package reload. Other unspecified body
attributes continue to come from ordinary text and Markdown faces.

#### Face reference

| Visual role | Face |
| --- | --- |
| Header product name, directory, count and filter | `isled-header-title-face`, `isled-header-directory-face`, `isled-header-count-face`, `isled-header-filter-face` |
| Header errors and warnings | `isled-error-face`, `isled-warning-face` |
| Issue ID base and ready, waiting or closed state | `isled-issue-id-face`, `isled-ready-issue-id-face`, `isled-waiting-issue-id-face`, `isled-closed-issue-id-face` |
| Issue title, kind and kind brackets | `isled-issue-title-face`, `isled-issue-kind-face`, `isled-issue-kind-bracket-face` |
| Expanded body, optional title background and ledger warning area | `isled-expanded-body-face`, `isled-panel-title-face`, `isled-panel-title-background-face`, `isled-ledger-warning-face` |
| Panel bracket and rule | `isled-body-bracket-face`, `isled-panel-rule-face` |
| Ready, waiting, closed and missing references | `isled-ready-reference-face`, `isled-waiting-reference-face`, `isled-closed-reference-face`, `isled-missing-target-reference-face` |
| Ordinary Markdown links | `isled-markdown-link-face` |
| Diagnostic controls, loading/empty text and pointer highlight | `isled-action-face`, `isled-subdued-face`, `isled-target-highlight-face` |
| Persistent help key, delimiters and text | `isled-help-key-face`, `isled-help-delimiter-face`, `isled-help-text-face` |

Expanded Markdown deliberately reuses `markdown-mode` faces rather than copying
them into package-specific options. Customize `markdown-header-face`,
`markdown-bold-face`, `markdown-italic-face`, `markdown-code-face`,
`markdown-inline-code-face`, `markdown-list-face`, `markdown-blockquote-face`
and the other `markdown-*` faces to style the corresponding syntax. Ordinary
Markdown links inherit `markdown-link-face` through
`isled-markdown-link-face`, which keeps the browser's link behavior.

## Local configuration

Source loading and package installation are separate choices. Configure your
checkout path explicitly and preserve any running editor session when upgrading.

Load the mutable checkout through the existing Elpaca/use-package setup:

```emacs-lisp
(defvar my-isled-checkout (read-directory-name "Isled checkout: "))

(use-package isled
  :ensure nil
  :load-path (expand-file-name "frontends/emacs" my-isled-checkout)
  :commands (isled isled-setup)
  :init (isled-setup))
```

### Key binding

`isled-setup` installs `C-x p i` for `isled-open-project` when that slot
is unbound. An existing binding is preserved. `C-u C-x p i` shows the same
chooser and creates an additional view for the selected location. Package installation loads
this registration automatically through generated autoloads; the source setup
above calls the public setup function. Both keep the browser unloaded. Repeated
setup calls preserve later overrides, including removal of the binding. No personal binding snippet is needed.

Use ordinary keymap configuration to remove or replace the default. The binding belongs to the built-in `project-prefix-map`; Projectile is not
required. Run overrides
after the lightweight `isled` entry file, so they work whether project.el or the package
loads first and survive later browser loading. For example, to remove it:

```emacs-lisp
(with-eval-after-load 'isled
  (keymap-unset project-prefix-map "i" t))
```

Or move it to `C-x p j` (choosing a key whose existing binding you intend to replace):

```emacs-lisp
(with-eval-after-load 'isled
  (keymap-unset project-prefix-map "i" t)
  (keymap-set project-prefix-map "j" #'isled-open-project))
```

The same override can be expressed in `use-package` (add these keywords to an
existing declaration; keep its local checkout recipe when applicable):

```emacs-lisp
(use-package isled
  :bind (:map project-prefix-map ("j" . isled-open-project))
  :config (keymap-unset project-prefix-map "i" t))
```

Issue-view keys live in `isled-mode-map`. The map is initialized with
its defaults by the lightweight `isled` entry module, so `use-package
:bind` can configure it before the browser loads. Loading or reloading the
browser does not reinstall defaults, reset the map parent, or overwrite later
bindings, command remappings, and intentional unbindings.

This ordinary Emacs configuration runs when the browser is first loaded and
also works when it is already present:

```emacs-lisp
(with-eval-after-load 'isled-browser
  (keymap-set isled-mode-map "r" #'isled-refresh)
  (keymap-unset isled-mode-map "g")
  (keymap-set isled-mode-map
              "<remap> <isled-next>" #'next-line))
```

The equivalent `use-package` form can configure both the project entry and the
mode map before opening a view:

```emacs-lisp
(use-package isled
  :commands (isled isled-setup)
  :init (isled-setup)
  :bind (:map project-prefix-map
              ("j" . isled-open-project)
              :map isled-mode-map
              ("r" . isled-refresh))
  :config
  (keymap-unset project-prefix-map "i" t)
  (keymap-unset isled-mode-map "g")
  (keymap-set isled-mode-map
              "<remap> <isled-next>" #'next-line))
```

Keep `:ensure nil` and the `:load-path` from the [local checkout
recipe](#local-configuration) when using that setup. A packaged installation
does not need them.

The default issue-view bindings are:

| Key | Command | Purpose |
| --- | --- | --- |
| `f` | `isled-filter` | Filter issues by status, tags, kind or text. |
| `v` | `isled-graph-toggle` | Toggle hierarchical/flat presentation. |
| `d` | `isled-graph-reverse` | Reverse dependency direction in hierarchical mode. |
| `O`, `C`, `A` | `isled-filter-open`, `isled-filter-closed`, `isled-filter-all` | Select status. |
| `g` | `isled-refresh` | Refresh the current view. |
| `j` | `isled-jump-to-issue` | Choose an issue by ID or title from this ledger. |
| `TAB`, `<tab>` | `isled-next` | Move to the next issue or actionable body target. |
| `S-TAB`, `<backtab>` | `isled-previous` | Move to the previous issue or actionable body target. |
| `C-TAB` | `isled-next-issue` | Move to the next issue heading. |
| `C-S-TAB`, `C-<backtab>` | `isled-previous-issue` | Move to the previous issue heading. |
| `RET` | `isled-activate` | Toggle an issue or activate the target at point. |
| `C-RET` | `isled-collapse-all` | Collapse all issues in the view. |
| `M-.` | `isled-jump-to-reference` | Jump to the issue reference at point. |
| `M-,` | `isled-history-back` | Move backward through issue-view history. |
| `C-M-,` | `isled-history-forward` | Move forward through issue-view history. |
| `?` | `isled-help` | Open the issue-view help menu. |
| `q` | `quit-window` | Quit the issue view. |

`n` and `p` are deliberately undefined in the mode map; ordinary line movement
uses `C-n`, `C-p`, and the arrow keys. Terminal representations of shifted Tab
can vary, so the map also recognizes `C-S-<iso-lefttab>` for previous-issue
movement.

All package commands remain callable through `M-x` or personal bindings,
independently of the defaults. In addition to the commands above,
`isled-open` visits the selected canonical issue file,
`isled-duplicate-view` creates an independent view, and
`isled-filter-open`, `isled-filter-closed`, and
`isled-filter-all` change only the status part of the current query.
`isled-search` remains a compatibility alias of
`isled-filter`. Rendered issue and link targets use
`isled-target-map`, whose default mouse binding is `<mouse-2>` to
`isled-activate-mouse`.

The header derives its Help key from `isled-mode-map`; if the command
has no local key, it honestly shows `M-x isled-help`. The Transient
help menu has its own displayed suffix keys and invokes the documented commands
directly. Changing the mode-map binding for a command does not rewrite that
menu's legend or suffix keys.

Upgrading a source-loaded older version removes the former package defaults
`o`, `c`, `a`, and `s` once when they still name their former commands. This
narrow migration does not install current defaults. Later reloads preserve
personal uses of those keys and all other mode-map changes.

The package declares `markdown-mode` and Transient 0.8.0+
dependencies. Another local setup must
install them before source-loading with `:ensure nil`. Installing the packaged
tar through `package-install-file` resolves them through configured package
archives.

The help menus use the per-prefix `display-action` slot introduced in
[Transient 0.8.0](https://github.com/magit/transient/blob/v0.8.0/CHANGELOG).
Emacs 30's bundled Transient is too old. With `package.el`, enable
`package-install-upgrade-built-in` before installing Transient, then restart
Emacs if the older version was already loaded.

Source loading reads from the configured checkout. If you compile locally for
interactive use, rebuild or remove old bytecode before reloading so it cannot
shadow newer source. Routine validation compiles only into temporary directories
and does not install those files into the source tree or a running editor.

`isled-program` defaults to the `isled` executable found through `PATH`.
During isolated
development it can instead name the repository-built binary:

```emacs-lisp
(setq isled-program
      (expand-file-name "target/debug/isled" my-isled-checkout))
```

## Opening projects and directories

| Command | Location selection |
| --- | --- |
| `isled` | Current Emacs project root, otherwise current directory; no chooser. |
| `isled-open-project` (`C-x p i`) | Always choose, defaulting to the current project. |
| `isled-open-directory` | Choose any existing local directory; no project registration. |

Only the project command has a default key. The project chooser uses Emacs's
known project roots and permits entering a directory; it does not scan their
ledgers to populate completion. Directory entry requires no Git project or
project history. Remote directories and symlinked `.issues` stores are unsupported;
symlinked paths to a project resolve to its canonical location.

If the selected location has no ledger, choose Open parent ledger (the default
when present), Create ledger here, or Cancel. Prompts show the actual paths. When
no parent exists, choose Create or Cancel. Creation happens only after explicitly
choosing Create, using the CLI's existing `init` behavior, including `.gitignore`.
The asynchronous command reports failure without retrying it. If you move away
before successful creation finishes, it reports completion without redirecting
you; invoke the entry command again when ready.

View reuse follows the selected location. Two projects or directories using the
same parent ledger share data but keep independent filters, folds and positions.
Selecting a project's exact root through either chooser reuses the same context;
plain entry returns to its most recently used view. A parent choice is remembered
while a view for that context remains open, not saved as a permanent association.
If a local ledger appears meanwhile, choose between it and the retained parent.
Existing views keep their original ledger until explicitly replaced or closed.

Inside a view, `isled` stays there. Both chooser commands still prompt and default
to that view's selected location, including when it uses a parent ledger.
A prefix argument creates another view: copy that location's most recent view's
filters, folds and position if available, otherwise start Open with issues
collapsed. `C-u M-x isled` inside a view duplicates that specific view, as does
`isled-duplicate-view`. Duplication selects a sensible
split, first using the preferred split function, then retrying with automatic
display thresholds relaxed. Minimum window sizes still apply; if neither split
fits, the duplicate uses the invoking window. Global split settings are unchanged.
Ordinary window splitting continues to display the same shared view buffer.
Views share retained detail data and serialized Rust work, but keep separate
filtered projections. Refreshing any view reconciles once and updates each
view's own filter. Simultaneous refresh requests share that reconciliation.
Hidden views retain their rendered text and coalesce changes until shown again;
returning to an unchanged view needs no reconstruction or Rust wait. Hidden
views request no details. Rendered text and display properties are view-owned;
sharing the decoded detail cache does not eliminate that per-view memory cost. One private ledger buffer owns notifications and polling
fallback until the last view is killed. Closing a window retains its view.

## Identity header

The theme-aware header shows `Isled`, the selected context directory, visible
issue count, the complete filter in one bracket group, and `[?] Help`. It does
not repeat a buffer-body title. A shared parent ledger is shown beside the title
when space allows; the directory tooltip retains both context and ledger paths.
Each window fits its own header: reduce the path
to its final directory name first, then shorten filter text with an ellipsis,
retaining a recognizable portion where space allows. Only then drop decorative
title/count information and truncate the directory further. Extremely narrow
windows prioritize what fits; filter cannot remain readable at zero width.
Hover over shortened directory/filter text for its full value. Buffer names and
Uniquify settings remain unchanged. Refresh diagnostics take priority and expose
their full message on hover. During issue filtering, the syntax hint or input error
occupies the header. No ledger reads or counting occur during header redisplay.

## Help menu

Press `?` for a conventional
Transient menu arranged in three columns with focused headings: Navigate and
History; Filter and Display; Read, Change and Exit. `O`, `C` and `A`
stay together with `f` under Filter. Navigate's next/previous item commands visit issue
headings and actionable links; the issue-only commands skip links.
Actions run in the originating issue view.
Help includes filtering, the hierarchical/flat toggle and Open/Closed/All status
actions. Direction reversal is shown in hierarchical mode. Both presentations
use the same filtering commands for every query.
Help stays open for filters, folding,
refresh, issue navigation, and ordinary cursor movement or scrolling. Opening
a menu does not transfer keyboard focus: arrow keys, `C-n`/`C-p`, and paging
keys move the issue view even after menu actions refresh its bindings. Opening
a file or invoking another outside command dismisses it. `q` or `C-g` dismisses
the menu; `Q` quits the view from the menu. The popup splits only the selected
issue window below it; other windows are not reused. If that window cannot
split, help reports insufficient room rather than displacing another buffer.
These settings apply only to this menu. Outside the menu, all existing
shortcuts remain unchanged, including `q` to quit the view. The header still
reports refresh errors and polling fallback.

## Filter memory

Use `O`, `C`, or `A` to choose status, or `f` to edit the
[filter query](#issue-filtering). Lowercase `a` adds an issue and `c` closes one;
`o` has no package binding. A new view starts with Open issues; the header
shows the active query and visible issue count. Filter changes do not add
jump-history entries.

The named commands `isled-filter-open`, `isled-filter-closed`,
and `isled-filter-all` also remain available through `M-x` and personal
bindings. They replace or remove only the status constraint. For example:

```emacs-lisp
(with-eval-after-load 'isled-browser
  (keymap-set isled-mode-map "o" #'isled-filter-open))
```

On an authorized reload from the older version, only bindings still pointing
to their former default status commands are cleared. Other personal bindings
and already unassigned keys are preserved.

Only Open and Closed retain separate cursor memories per window/view pair,
saved before leaving them. Filters and folding remain shared by the view buffer. All has no saved destination view. Switching status retains the current
issue and its cursor when visible; otherwise it restores the destination's saved
selection, expanded sections, and issue-relative cursor. Without a usable saved
position, the nearest visible replacement is selected, or none for an empty
result. Entering All retains current expansions; when the current issue survives
another status switch, its expansion is retained alongside the destination's.
No per-tag view cache is created. If refresh removes the issue containing
the saved cursor, the next issue in ID order takes its row; the preceding final
issue is used when there is no successor. Point lands on that replacement's
heading rather than inheriting the vanished issue's offset. Invalid expanded
IDs are discarded without otherwise moving point.

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

## Package archive

Build a locally installable package archive using `gnumake` from the project
development shell. This does not create an Emacs package flake output:

```console
make -C frontends/emacs package
```

Package installation byte-compiles the frontend. Use that compiled package for
large-ledger work: interpreted source loading remains useful during development
but has materially higher callback costs. The package does not change Emacs GC
settings globally. Compare compiled/source execution and default/configured GC
when attributing rendering costs.

Then use `M-x package-install-file` on
the versioned archive in `frontends/emacs/dist/`. Package metadata owns the version;
the generated `dist/` directory
is not source and is ignored.

## Code map

- [`isled-entry.el`](isled-entry.el) owns current-context, project and directory
  selection plus explicit destination choices; [`isled-context.el`](isled-context.el)
  owns selected-location identity and recent-view lookup.
- [`isled-initialize.el`](isled-initialize.el) owns explicit asynchronous creation
  and protects the invoking editor context while it completes.

- [`isled.el`](isled.el) owns lightweight public setup, command
  autoloads, one-time mode-map defaults, and default project-prefix registration.

- [`isled-snapshot.el`](isled-snapshot.el) owns shared typed
  data, issue/reference validation, and the supported complete-snapshot codec.
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
  Rust's omitted-connection
  counts preserve the circle marker when filters hide every neighbor; filters use
  the ordinary loading queue.
- [`isled-presentation.el`](isled-presentation.el) owns semantic
  faces, Markdown presentation, typed reference properties and diagnostic text.
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
provides explicit package directories and the candidate CLI. Run from the root:

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
