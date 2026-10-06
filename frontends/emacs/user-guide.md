# Emacs user guide

Start with the [README](README.md) for installation and a short tour. This guide
covers everyday use, then the options for making Isled feel at home in your setup.

For a first session: open a project, press `RET` to read an issue, `f` to narrow
the list, and `w` to pick up work. `?` keeps the commands close at hand.

- [Projects and independent views](#opening-projects-and-directories)
- [Navigation, folding and source files](#navigation-and-folding)
- [Adding, editing and closing issues](#add-edit-and-close-issues)
- [Work state and time](#work-state-and-time)
- [Filtering and completion](#issue-filtering)
- [Reading dependency graphs](#dependency-graph-view)
- [Refresh](#automatic-refresh) and [warnings](#known-warnings)
- [Appearance](#theme-and-identity-styling) and [key bindings](#key-binding)
- [Loading from a checkout](#local-configuration)
- [CLI setup and upgrades](#cli-setup-and-upgrades)

## Opening projects and directories

| Command | Open |
| --- | --- |
| `isled` | The current project's ledger, or the current directory's ledger outside a project. |
| `isled-open-project` (`C-x p i`) | A project chosen from Emacs's known projects. You can also enter a directory. |
| `isled-open-directory` | Any existing local directory, without registering it as a project. |

The project chooser lists known roots without scanning their ledgers. A directory
needs neither Git nor project history. Remote directories and symlinked `.issues`
stores are unsupported; a symlink to a project resolves to its canonical location.

### Choosing a ledger

If the location has no ledger, Isled offers **Open parent ledger**, **Create ledger
here**, or **Cancel**. The parent is the default when one exists. Each choice shows
its path, so you can decide where the issues belong.

Choosing Create runs `isled init`, including its `.gitignore` setup. If creation
fails, Isled reports the error. If you leave before it finishes, completion does
not pull you back: run an opening command again when ready.

Isled remembers your parent-ledger choice while a view for that location remains
open. If a local ledger appears later, it offers a choice between the two.
Existing views keep their ledger until you replace or close them.

### Keeping separate views

Each selected project or directory has its own filters, folds and position, even
when several use the same parent ledger. Opening the same location returns to
its most recently used view. Selecting a project's exact root through either
chooser uses that same set of views.

Inside a view, `isled` stays there. The chooser commands still prompt, using the
view's selected location as their default.

Use a prefix argument to open another view. It copies the location's most recent
view, or starts with Open issues collapsed if there is none. Inside a view,
`C-u M-x isled` and `isled-duplicate-view` duplicate that particular view.

The duplicate opens in a split when space permits, otherwise in the current
window. Ordinary window splitting displays the same view buffer: its filters
and folds remain shared. Use duplication when you want to browse independently.

Refreshing one view updates the others without replacing their filters. Closing
a window leaves its view available; killing the buffer discards it.

## Navigation and folding

| Key | Action |
| --- | --- |
| `TAB` / `S-TAB` | Move between issue headings and links or buttons in expanded issues. |
| `C-TAB` / `C-S-TAB` | Move directly to the next or previous issue heading, without wrapping. |
| `RET` | Expand or collapse the current issue, or activate the target at point. |
| `C-RET` | Collapse every issue in this view. |
| `j` | Find an issue by ID or title. |
| `M-.` | Follow the issue reference at point. |
| `M-,` / `C-M-,` | Go back or forward through issue navigation. |

Modified Tab keys depend on terminal support. All commands can be rebound;
see the [key binding reference](#key-binding).

### Finding and following issues

Press `j` (`isled-jump-to-issue`) to search the current ledger by ID or title.
Completion includes closed issues and issues outside your filter. Short IDs,
with or without `#`, work too. Selecting an issue reveals and expands it;
canceling or entering an unknown ID leaves the view unchanged.

Follow an issue reference with `RET`, `M-.` or mouse-2. A target already in the
results keeps the current query. A target outside them opens its status view
without the other filter constraints. An All view stays All. Missing references
cannot be followed.

Use `M-,` to return to your previous query, folds and position. `C-M-,` moves
forward again; following a new reference after going back replaces the forward
history. Each window and view has its own history, which survives buffer switches.
Other Markdown links use Emacs's normal navigation history.

Windows showing the same view share its query and folds, so restoring history
changes those in every such window. Their cursor positions are preserved where
possible, and their histories remain separate. If you move away while a jump is
loading, the delayed result will not take over another window or move you back.

### Reading expanded issues

Opening an issue scrolls just enough to show its details when possible. If the
body is taller than the window, keeping point visible takes priority. Folding
it again restores the earlier viewport if you have not moved or scrolled since
opening it. Refreshing, filtering or resizing also ends that restoration.

For each filter, each window remembers the last issue you collapsed and your
position inside it. Reopening that issue restores point. Collapsing a different
issue replaces the memory; `C-RET` clears it for the current filter. This memory
is separate from navigation history.

Refresh tries to keep the same issue at the same screen position. Buffer limits
and keeping point visible can require a small adjustment. Other windows keep
their own positions even though the view's folds are shared.

Warnings appear above an issue's stored content. See [Known warnings](#known-warnings)
for their meaning and recovery actions.

<a id="issue-search"></a>

### Opening issue files

Opening a valid local `.issues/NNNN-name.md` file normally reveals its issue in
the ledger view. This works with `find-file`, its other-window and other-frame
variants, and Markdown, Org and agent-shell file links.

Isled uses the target ledger's most recent view and the window chosen by the
original open command. It adds no extra split. If the issue is outside that
view's filter, navigation reveals it; `M-,` returns to the previous view state.
Other independent views keep their filters and folds.

While Isled checks the record, the originating buffer stays visible. A successful
check opens the issue view without creating a Markdown buffer. If validation or
the CLI fails, the original file-opening command runs with a brief explanation.
Opening a file never creates a ledger.

Some opens deliberately stay in Markdown:

- Files with unsaved edits in an existing buffer.
- Links to a source line, column or fragment such as `issue.md#statement`.
- Remote files and paths containing symlinks.
- Explicit source and recovery actions, including `s`.

Moving away, editing the originating buffer, opening another file or changing
the destination view cancels a pending jump. Existing file buffers are preserved.

Agent-shell links honor `agent-shell-file-display-action`, including no-display;
standalone agent-shell Markdown uses the current window. Org keeps its application
selection and configured file-opening command.

Routing is enabled by `isled-setup`. To disable it:

```emacs-lisp
(setq isled-file-routing nil)
```

For Lisp integrations, `find-file-noselect` still returns an ordinary file buffer.
Recognized display commands route asynchronously; other display functions need
an adapter.

### Open Markdown source

Press `s` (`isled-open-source`), or choose **Markdown source** under **Read** in
`?`, to open the current issue's file in the same window. This always opens
Markdown, even when automatic file routing is enabled.

Existing buffers keep their point, unsaved edits and read-only state. A newly
visited file starts at its heading. Malformed files open for repair; a missing
or renamed file reports that source is unavailable without creating an empty file.

Save normally to let the issue view pick up your changes. Source editing does
not validate or repair the record for you. Use `e` for validated field edits,
or `M-x isled-open` to open the record read-only.

## Add, edit and close issues

Press `a` (`isled-add-issue`) for a new draft or `e` (`isled-edit-issue`) to edit
the issue at point. The editor opens in a separate split and respects
`display-buffer-alist`. Editing the same issue from another view reuses its draft.

New drafts are independent and receive an ID only after a successful save. The
header shows the ledger, issue and draft state, including unsaved edits, failed
saves and changes on disk.

### Working with fields

Edit the title, kind, tags, Statement, Evidence, Outcome and dependencies. Tags
can be separated by spaces or commas. Repeated tags are saved once. Empty
Evidence is saved as Pending; ordinary editing leaves status unchanged.

Statement grows as you type. Its extra display space is not saved as whitespace.
Saving trims whitespace around the Statement while preserving Markdown whitespace
within it. Field labels and validation messages stay outside the editable values.

| Key or action | Result |
| --- | --- |
| `C-x C-s` | Save and keep editing. |
| `C-c C-c` | Save and return to the issue in the ledger. |
| `C-c C-k` | Cancel unsaved edits after confirmation; earlier saves remain. |
| `C-TAB` / `C-S-TAB` | Move to the next or previous field or button. |
| `TAB` | Complete a value, or indent multiline text. Never inserts a tab in a single-line field. |
| `C-c ?` | Open editor help. |
| **Revert draft** | Reload the saved issue, or reset a new draft after confirmation. |

Adding Evidence or a dependency focuses the new entry. Removing one leaves point
on a neighbor, or on the section's Add button when no entries remain. Field faces
are customizable through `isled-editor-field` and `isled-editor-active-field`.

### Completion while editing

`TAB` offers existing kinds and tags, including in empty fields, and accepts new
valid names. Tag completion omits tags already entered.

Type `#` in Title, Statement, Evidence or Outcome to complete an issue by ID or
title. Selecting one inserts `#NNNN`; it does not create a dependency. Continue
typing prose after the reference as usual. Local Markdown link targets complete
relative to the ledger root.

Completion works with stock Emacs, Corfu and Company. Optional documentation
previews show up to 16 KiB of the selected local issue's Markdown; they do not
fetch web links.

### Validation and changes on disk

After `isled-editor-validation-delay` idle seconds, Isled validates the draft
without saving it or allocating an ID. Errors appear beside the relevant fields.
Use **Next error** in Help to visit them. A failed save keeps your draft, point
and scroll position, and marks the failure in the header.

Open drafts watch for file changes even after the ledger view is closed. A change
marks the draft **Changed on disk** without replacing your edits. Failed checks
also appear in the header. The watch follows `isled-auto-revert`; saving always
checks the current file version, even when automatic checks are unavailable.

If the saved issue has changed, Help offers:

- **Compare** to inspect the differences.
- **Revert** to reload the saved version.
- **Overwrite** to confirm replacing that version with your draft.

Overwrite checks again that the version you confirmed has not changed. Resolve
unsaved edits in a Markdown source buffer before saving through the structured
editor; Isled never reverts those buffers for you.

If a save reports an uncertain or partial result, inspect the saved record before
retrying. This is especially important after creating an issue: it may already
have an ID. The draft remains available while you reconcile the result.

### Closing an issue

Press `c` (`isled-close-issue`) to prepare closure. Existing draft edits are kept,
point moves to Outcome, and the header shows **Closing issue**. Status remains
**Open → Closed** until the save succeeds.

Add concrete Evidence and an Outcome, then save. `C-x C-s` closes the issue and
keeps the editor open; `C-c C-c` closes it and returns to the ledger. Closure is
terminal. Canceling the closing draft leaves the saved issue open.

Revert reloads the saved fields after confirmation, keeps the intent to close,
and returns to Outcome. After successful closure, the buffer becomes an ordinary
editor for the closed issue.

For the exact validation and save rules, see the [editor contract](../../user-docs/editor.md).

## Work state and time

Press **`w`** on an issue to keep the next step and its work sessions together.
These actions require the matching 0.35 source version until its release is
published; see [source setup](CONTRIBUTING.md#source-development-setup).

### Pick up, pause, resume

| In the Work menu | What happens |
| --- | --- |
| Queue | Mark the issue for later; no timer runs. |
| Start / resume | Mark it In progress and start timing. |
| Pause clock | End the current session; keep it In progress. |
| Start without timing | Track the state alone, stopping any running timer. |
| Not queued | Remove the current work state and stop timing; keep history. |

Each resumed session adds a span. Breaks stay out of the total. Repeating Start
while timing keeps the same span; pause first to change its activity. Use `C-u`
with Start to name an activity such as Implementation or Testing.

### Hand work over

Choose **Ready for review** when the result needs a look, or **Ask a question**
when a decision is missing. Both stop timing. The question stays with the issue
until work resumes.

Headings show **Queued**, **In progress**, **Question** or **Review**, with
nonzero completed time. The heading's help text includes the pending question.
Use `s:open r:review` to find reviews, then `S` → **Oldest first** for arrival
order. Hierarchy continues to follow dependencies.

### Read the history

**Work history** opens the question, numbered sessions, clock status and total.
The total includes a running session at the moment you request it; reopen the
report for an updated value. Headings show completed time only.

**Since** is the time the issue entered its current state. Pause and resume keep
it. Switching between Review and Question starts a new wait; editing the
question keeps it. Older records can have unknown age. Since stays out of titles.

Expand the issue to read the same spans in its Markdown Work log. Columns align
even in older tables with uneven padding; activity labels stay literal.

### Correct a forgotten timer

The clock survives editor restarts. If you forgot to pause, use a prefix with
Pause to enter the actual stop time in UTC. **Correct stop time** changes a
numbered span; Work history shows their numbers. See the
[work guide](../../user-docs/work-tracking.md) for examples and file format.

Tracking is optional. Existing issues stay Not queued with no recorded time.
Normal editing preserves tracking; closing stops timing, keeps history and
removes current state. Work state does not change dependency readiness or grant
permission to close an issue.

## Issue filtering

Press `f` to edit the current query. Results update as you type. `RET` keeps the
query; `C-g` restores the previous query and position. Incomplete or invalid input
leaves the last valid results visible until you finish it.

All terms must match. Words match case-insensitively anywhere in the complete
Markdown record, including relation reasons. Different words can match different
sections; quotes require a literal phrase.

<a id="search-examples"></a>

### Filter examples

| Query | Find |
| --- | --- |
| `s:open w:queued` | Open issues queued for work. |
| `s:open w:awaiting-owner` | Open issues needing an owner action. |
| `s:open w:queued o:oldest-first` | Queued issues in arrival order. |
| `s:open w:awaiting-owner r:review o:oldest-first` | Reviews in arrival order. |
| `s:open t:rust` | Open issues tagged `rust`. |
| `k:bug` | Bugs with either status. |
| `s:closed "disk full"` | Closed issues containing the phrase `disk full`. |
| `t:rust t:emacs startup` | Issues with both tags and the word `startup`. |
| `"t:rust"` | The literal text `t:rust`. |

These are complete queries. Replace the minibuffer text to try one; leaving
`s:open` in place keeps the search limited to open issues.

Remove the status term to include both statuses. There is no `s:all`. Remove
every term for an unfiltered view. Press `f` again to refine a query; it returns
with a trailing space ready for the next term.

Unquoted `t:`, `k:`, `s:` and `w:` prefixes select a tag, kind, status or work
state (`not-queued`, `queued`, `in-progress`, `awaiting-owner`). `r:review` and
`r:clarification` distinguish owner waits. Quote a term to search for its text.
Empty values and unfinished quotes must be completed before you can accept
the query.

The last status, work-state, reason and order terms win;
choosing a status through completion removes other status terms.

### Choose an order

Press `S` to choose **Hierarchy**, **Issue ID**, or **Oldest first**. The same
command appears in `?`. Hierarchy follows dependencies; the other two choices
show a flat list. Oldest first sorts by the current state's entry time, breaks
ties by issue ID, and puts unknown ages last.

Press `v` to switch between hierarchy and your last chosen flat order.
The header shows the active order. In a filter, `o:oldest-first` or `o:id`
selects the corresponding flat list. Refresh and navigation history retain
the choice. Emacs shows all matches; result limits belong to the CLI.

`O`, `C` and `A` change only status, keeping your tag, kind and text terms.
Refresh keeps the whole query. Duplicated views copy it and then remain independent.
Following a reference outside the results can temporarily leave the query;
`M-,` restores it, along with your folds and position.

### Completion interfaces

A syntax hint appears in the view's header while filtering. Completion offers
tags after `t:`, kinds after `k:`, statuses after `s:`, work states after `w:`,
owner reasons after `r:`, ordering after `o:`, and all structured choices
between terms. Quoted terms remain literal.

Choices come from readable cached issues matching the rest of your query. The
term at point is left out of that calculation; other copies of it still apply.
Status choices ignore existing status terms because selecting one replaces them.
Work-state choices ignore the current work-state constraint.
If nothing matches the remaining constraints, there are no suggestions.

Choose an interface with `M-x customize-option RET isled-filter-interface RET`:

| Interface | How it works |
| --- | --- |
| **Inline suggestions** (default) | Suggests values for the term at point. Uses Corfu when active, otherwise stock completion when it owns the prompt. `TAB` also completes explicitly. |
| **Separate filter picker** | `TAB` opens a completion prompt for one term. `RET` inserts a choice; `C-g` returns to the unchanged query. Uses Vertico when enabled. |
| **Minibuffer suggestions** | Shows choices while you edit the whole query. With Vertico, `TAB` inserts the selected choice and keeps later terms. Stock Emacs uses its completion window. |

For example:

```emacs-lisp
(use-package isled
  :custom
  (isled-filter-interface 'separate-filter-picker))
```

The other values are `inline-suggestions` and `minibuffer-suggestions`. All three
work without optional packages. If your completion reader does not support
minibuffer suggestions, that invocation falls back to the separate picker without
changing your saved preference. Other completion UIs keep control of their display.

#### Opening and dismissing suggestions

To open inline suggestions only when you press `TAB`:

```emacs-lisp
(setq isled-filter-inline-auto nil)
```

The default is `t`. Once suggestions are open, they continue updating. In manual
mode, dismissing them keeps them closed until another `TAB`. If choices are still
loading when you press it, they open when the reply for that input arrives.

With automatic inline or minibuffer suggestions, dismissing them keeps them
closed until you change the input or move point. The separate picker shows
“Loading choices…” while waiting and updates when choices arrive.

In the stock completion window, `M-v` selects the window and `RET` inserts a
choice. The filter stays open; `RET` in its prompt accepts the whole query.
In the separate picker, accepting a choice first closes the inner prompt.

If a popup or picker is active, `C-g` may dismiss that first. Use it again in the
outer filter prompt to cancel the filter itself.

#### Previewing a choice

With stock completion, Vertico or Corfu, highlighting a candidate previews the
results it would produce. Your typed query and available choices stay unchanged.
Dismissing suggestions returns to the typed query's results, or the last valid
view if the input is incomplete.

Preview replies cannot replace newer input. Other completion frameworks still
receive completion data, but do not get highlighted-candidate previews. Isled
leaves global completion settings unchanged.

`M-x isled-filter` opens the same prompt as `f`. Existing configurations can still
use the aliases `isled-search` and `isled-search-interface`.

## Dependency graph view

The hierarchy shows what is ready and what depends on it. By default,
prerequisites come first: for a sequence such as storage → resumable downloads →
field trial → release, storage appears before the work it unblocks. Press `d`
to read dependencies in the opposite direction.

Press `v` to switch to your last chosen flat order, initially issue ID.
Switching keeps your matching criteria, selected issue and expanded bodies.
Returning to the hierarchy restores its last direction. Press `S` to choose
any of the three orders directly.

### Reading the gutter

Every matching issue appears once. Titles stay aligned, while the gutter shows
chains, branches and joins.

| Mark | Meaning |
| --- | --- |
| `•` | An issue with no connections within the selected status set. |
| `○` | A connected issue. |
| `│` | A dependency continuing past this row. |

Connected groups stay together, ordered by their smallest issue ID. Independent
issues can appear between groups, but never interrupt one. Within a group,
dependency order comes first; newly unblocked branches follow, with narrower
branches and then issue ID breaking ties.

The first gutter column holds starts in the displayed direction and independent
issues. Connected threads continue in later columns. Consecutive circles in the
same later column form a straight chain; branches and joins add horizontal lines.
A horizontal stroke crossing a vertical one without a junction is not a join.

Connectors continue beside expanded bodies and wrapped lines. Folding changes
their height without moving their columns. If a graph is too wide, widen the
window or narrow the filter. When the gutter fills the window, Isled temporarily
truncates lines to avoid unusable wrapping.

### Filters and readiness

The graph shows only matching issues and direct connections between them. Open
never adds closed issues as context, and a hidden intermediate issue is never
replaced by an invented connection.

A circle can remain after a tag, kind or text filter hides its neighbors. Changing
Open/Closed/All can change circles to dots, because that distinction uses the
selected statuses. Reversing direction does not change the markers.

In an unfiltered Open view with prerequisites first, ready work normally appears
in column one. Closing a prerequisite lets the next unblocked issue move there.
With other filters or unavailable blockers, a visible root can still be waiting.
**Use the issue-ID color to judge readiness**, rather than its position alone.

The header shows your query and the current presentation or dependency direction.
For full-record text matching, use `f`; ordinary `C-s` has the narrower scope
explained below.

## Search and preview

`C-s` searches headings and bodies already displayed in this buffer. Once you
have opened a body, its text stays searchable after folding. Bodies that have
never been displayed are not searched; use `f` to search the complete ledger.

Search and completion previews can temporarily reveal a folded body. Moving away
or canceling restores its fold. Accepting the match opens it normally. Consult
and Vertico are optional; neither is required by Isled.

## Filter memory

A new view starts with Open issues. `O`, `C` and `A` choose Open, Closed or All
without changing the other query terms. Filter changes do not add navigation
history entries.

Open and Closed each remember a position for every window and view. All has no
separate saved destination. When you switch status:

- If the current issue remains visible, point stays with it.
- Otherwise, Isled restores the destination's saved selection, folds and position.
- If that position is gone, it selects a nearby issue, or none for an empty result.

Entering All keeps current expansions. An issue retained across another status
switch keeps its expansion alongside those restored for the destination. There
is no separate position memory for every tag query.

If refresh removes the issue at a saved position, Isled selects the next issue in
ID order, or the previous final issue when no successor exists. Point goes to its
heading. Removed issues are also dropped from the saved folds.

Filters and folds belong to the view buffer; cursor memories belong to each
window. See [independent views](#keeping-separate-views) if you need separate
browsing state.

## Automatic refresh

Views and open drafts notice ledger changes automatically. Refresh keeps your
query and browsing position. A changed file marks its draft **Changed on disk**
without replacing your edits. Press `g` to refresh manually.

If directory notifications are unavailable, the header reports a polling fallback.
On an error, the last good view stays visible and the header shows what failed;
`g` retries. Set `isled-auto-revert` to `nil` before opening a view to disable
automatic refresh.

## Known warnings

The header shows **Known warnings** when Isled has retained a finding, including
one on an issue hidden by your filter. Press `!`, click the indicator, or choose
**Known warning** in Help to visit it.

Repeat the action to move through findings in issue-ID order, then wrap to the
first. `M-,` restores your starting query, folds and position. The indicator
stays visible while scrolling and disappears when the last known finding clears.
It reports known problems, not the result of a full-ledger audit.

### Relation problems

An expanded issue shows relation warnings above its stored content. These are
generated diagnostics; they are not written into the issue. Existing issue IDs
act as links, while missing IDs cannot be followed.

Isled corrects stale copied titles automatically. Adding or removing a relation
requires your choice:

| Finding | Available actions |
| --- | --- |
| A relation exists at only one endpoint | **Complete relation** or **Remove relation**, from either endpoint. Completion asks for a reason if only the Blocking half remains. |
| A relation points to a missing issue | **Remove relation**. |

An incomplete relation still blocks readiness when its prerequisite is unresolved
or unavailable. A fresh result clears a warning once its cause is gone.

### Unreadable files

Unreadable records appear in **Ledger warnings** above the issue list, with their
error and **Open file** / **Move to trash** actions. Related issue warnings offer
the same controls.

Open file visits an ordinary editable buffer for repair. Move to trash confirms
the exact path and refuses symlinks or non-regular files. Trashing a record does
not remove its relations; remove those explicitly if needed.

After a successful action, point moves to another warning in the issue, or to
its heading when none remain. A ledger-level action moves to the next recovery
control or the start of the view. Failed actions keep the view and report the error.

See the [warning retention rules](../../user-docs/cache.md#known-warnings) for
which findings persist and when they are checked again.

## Identity header

The header shows the selected directory, visible issue count, query and `[?] Help`.
A shared parent ledger appears beside the title when space permits. Hover over the
directory to see both paths.

Narrow windows shorten the path and query; their tooltips keep the full values.
Refresh errors take priority and also expose their full text on hover. While
filtering, the header shows a syntax hint or input error.

## Help menu

Press `?` for the Transient menu. It groups navigation and history, filtering and
display, and reading and editing actions. Direction reversal appears only in the
hierarchical view.

Help stays open while you filter, fold, refresh or navigate. Keyboard focus stays
in the issue view, so you can keep moving and scrolling while consulting the menu.
Opening a file or running an outside command dismisses it.

Inside the menu, `q` or `C-g` dismisses Help; `Q` quits the view. Outside it,
`q` quits the view as usual. Help opens below the selected issue window without
reusing another window. If there is too little room to split, it reports that.

## Customization

Isled uses ordinary Emacs faces and keymaps. Browse its options with
`M-x customize-group RET isled RET`, or use the examples below in your configuration.

### Theme and identity styling

Issue headings show an ID, kind and title, for example:

```text
#0007  [maintenance] Review the backup procedure  [In progress · 18m 00s]
```

The ID's appearance carries readiness: ready inherits success colors, waiting
inherits link colors without an underline, and closed uses struck-through shadow.
Kinds inherit `font-lock-type-face`, with subdued brackets. Custom kinds appear
as written; there is no fixed color palette for them.
Work labels use the theme's normal text color through `isled-issue-work-face`.

Expanded issues sit in a bordered panel with a padded Markdown body. The title
sits in the top border. By default its background is uncolored; set
`isled-title-background` to non-nil to color it and its inner padding. Press `g`
or toggle the issue to apply that change.

The body normally takes its background from `mode-line-inactive`, while prose
and Markdown keep their normal theme faces. Set `isled-expanded-body-face` to
choose your own background or typography. Explicit settings remain in effect
through refresh, theme changes and package reloads.

#### Setting faces

Use `M-x customize-face RET isled-issue-title-face RET` for one face, or keep your
settings in `use-package`. For example:

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

`Monospace` is the generic fixed-width family name. Themes can set the same faces;
place this after the theme's `deftheme` form:

```emacs-lisp
(custom-theme-set-faces
 'my-theme
 '(isled-warning-face
   ((t (:foreground "#ff5f5f" :weight bold))))
 '(isled-expanded-body-face
   ((t (:background "#303030")))))
```

Without an explicit background, `isled-expanded-body-face` follows the active
theme. Other unspecified body attributes continue to use ordinary text and
Markdown faces.

#### Face reference

| Visual role | Face |
| --- | --- |
| Header product name, directory, count and filter | `isled-header-title-face`, `isled-header-directory-face`, `isled-header-count-face`, `isled-header-filter-face` |
| Header errors and warnings | `isled-error-face`, `isled-warning-face` |
| Issue ID base and ready, waiting or closed state | `isled-issue-id-face`, `isled-ready-issue-id-face`, `isled-waiting-issue-id-face`, `isled-closed-issue-id-face` |
| Issue title, kind and kind brackets | `isled-issue-title-face`, `isled-issue-kind-face`, `isled-issue-kind-bracket-face` |
| Work state and completed time | `isled-issue-work-face` |
| Expanded body, optional title background and ledger warning area | `isled-expanded-body-face`, `isled-panel-title-face`, `isled-panel-title-background-face`, `isled-ledger-warning-face` |
| Panel bracket and rule | `isled-body-bracket-face`, `isled-panel-rule-face` |
| Ready, waiting, closed and missing references | `isled-ready-reference-face`, `isled-waiting-reference-face`, `isled-closed-reference-face`, `isled-missing-target-reference-face` |
| Ordinary Markdown links | `isled-markdown-link-face` |
| Diagnostic controls, loading/empty text and pointer highlight | `isled-action-face`, `isled-subdued-face`, `isled-target-highlight-face` |
| Persistent help key, delimiters and text | `isled-help-key-face`, `isled-help-delimiter-face`, `isled-help-text-face` |

Markdown uses `markdown-mode` faces directly. Customize `markdown-header-face`,
`markdown-bold-face`, `markdown-italic-face`, `markdown-code-face`,
`markdown-inline-code-face`, `markdown-list-face`, `markdown-blockquote-face`
and other `markdown-*` faces as usual. Links inherit `markdown-link-face`
through `isled-markdown-link-face`.

## CLI setup and upgrades

Automatic setup uses the exact published CLI release required by your Emacs
package. See [installation](README.md#installation) for package-manager recipes
and the downloadable Emacs archive.

With `isled-program` set to nil, the first command that needs the CLI downloads
it automatically from the project's GitHub release. Emacs checks the download
before running it. Setup needs Emacs's built-in TLS and zlib support, with no compiler,
administrator access, PATH changes or separate verification tools.

Some minimal Emacs builds omit TLS or decompression support. Isled explains this
before starting a download. Use an Emacs build with those facilities,
or configure a separately installed CLI with `isled-program`.

Downloads run in the background and report progress. Use `M-x isled-cancel-setup`
to cancel. After a failure, retry the original command, press `g` in the view,
or run `M-x isled-setup-cli` to prepare the CLI separately.

A frontend update that keeps the same CLI version reuses the cached executable,
including offline. An update needing another version downloads it on first use. Earlier versions
stay available for frontend rollback; failed setup leaves them untouched.

The CLI and its matching skill live in the platform's shared user-data directory,
outside installed Emacs packages. The CLI chooses the location. Customize
`isled-cli-directory` to use another local directory; the default is nil.
See [storage locations and rollback](../../user-docs/installation.md#where-it-lives)
for the full layout. Existing caches from older frontends stay untouched.

Setup keeps a side window visible with the full executable, skill directory and
`SKILL.md` paths through `current`. Opening the ledger does not replace it.
Follow **Open installation folder** to browse the bundle. Press **`q`** in the
side window to dismiss it; **`M-x isled-show-installation`** brings it back.

Use its `current` paths in shell and agent configuration. Emacs runs its exact
versioned executable, so a standalone upgrade cannot redirect the frontend.
Run `M-x isled-setup-cli` to select the frontend's version again.

If a stored version fails its integrity check, inspect it and move only that
version aside before retrying. Isled never runs the damaged file.

To use a manually installed or Nix-managed release, set `isled-program` to its
path, or to a command name on PATH. It must report the required CLI version.
Isled reports a mismatch and leaves your executable alone. For a same-checkout
source build, also set `isled-use-development-cli` to t; this accepts that version's
explicit `-dev` identity. Unsupported platforms can use this source-build route.

## Local configuration

To load a checkout instead of installing the package, first install its
[dependencies](README.md#installation), then set your checkout path:

```emacs-lisp
(defvar my-isled-checkout (expand-file-name "~/src/isled"))

(use-package isled
  :ensure nil
  :load-path (expand-file-name "frontends/emacs" my-isled-checkout)
  :commands (isled isled-setup)
  :demand t
  :config (isled-setup))
```

A packaged installation resolves dependencies through your configured package
archives. Source loading with `:ensure nil` requires you to install them first.
See [installation](README.md#installation) for the required Transient version
and built-in package upgrades.

### Key binding

`isled-setup` binds `C-x p i` to `isled-open-project` only when that key is free.
Package autoloads run setup automatically; the source-loading example above
calls it explicitly. Repeated setup preserves your later overrides and unbindings.

#### Project shortcut

The shortcut belongs to Emacs's `project-prefix-map`; Projectile is not required.
Apply overrides after the `isled` entry file loads. To remove it:

```emacs-lisp
(with-eval-after-load 'isled
  (keymap-unset project-prefix-map "i" t))
```

To move it to `C-x p j`, replacing any existing binding there:

```emacs-lisp
(with-eval-after-load 'isled
  (keymap-unset project-prefix-map "i" t)
  (keymap-set project-prefix-map "j" #'isled-open-project))
```

Or add this to your `use-package` declaration:

```emacs-lisp
(use-package isled
  :bind (:map project-prefix-map ("j" . isled-open-project))
  :config (keymap-unset project-prefix-map "i" t))
```

#### Issue-view keys

View keys live in `isled-mode-map`. You can configure the map before opening a
view; loading or reloading the browser preserves custom bindings, remappings
and deliberate unbindings.

For example, move refresh from `g` to `r` and remap next-item navigation:

```emacs-lisp
(with-eval-after-load 'isled-browser
  (keymap-set isled-mode-map "r" #'isled-refresh)
  (keymap-unset isled-mode-map "g")
  (keymap-set isled-mode-map
              "<remap> <isled-next>" #'next-line))
```

A combined `use-package` configuration can set both the project shortcut and view
keys before you open a ledger:

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

For a checkout, keep `:ensure nil` and `:load-path` from the
[source-loading example](#local-configuration). A packaged installation does
not need them.

#### Default bindings

| Key | Command | Purpose |
| --- | --- | --- |
| `a` | `isled-add-issue` | Add an issue. |
| `e` | `isled-edit-issue` | Edit the issue at point. |
| `c` | `isled-close-issue` | Prepare closure in the editor. |
| `s` | `isled-open-source` | Open the Markdown source. |
| `!` | `isled-jump-to-warning` | Visit the next known warning. |
| `w` | `isled-work` | Work state, clocks, owner questions and history. |
| `f` | `isled-filter` | Filter issues by status, work state, tags, kind or text. |
| `S` | `isled-listing-order` | Choose hierarchy, issue ID or oldest first. |
| `v` | `isled-graph-toggle` | Toggle hierarchy and the last flat order. |
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

`n`, `p` and `o` have no package binding. Lowercase `a` and `c` add and close issues;
uppercase `A` and `C` select status. Terminals encode shifted Tab differently, so
`C-S-<iso-lefttab>` is also accepted for previous-issue movement.

Commands remain available through `M-x` or personal bindings. Beyond the table,
`isled-open` opens a record read-only and `isled-duplicate-view` creates an
independent view. Mouse targets use `isled-target-map`, with `<mouse-2>` bound to
`isled-activate-mouse`.

The header's Help hint follows your binding for `isled-help`, falling back to
`M-x isled-help` when it has no local key. The Transient menu keeps its own suffix
keys; rebinding a mode command does not change the menu's keys or legend.
