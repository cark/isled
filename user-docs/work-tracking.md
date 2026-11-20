# Work state and time

See what is being planned, what is prepared or queued, and what needs an answer
or review.
If useful, keep the time spent on each issue too.

Tracking is optional. An ordinary issue is **Not queued**, with no recorded time.
There is one worker and at most one running timer per issue; different issues
can be worked on in parallel.

Planning and Prepared require the 0.36.0 CLI and matching frontend. Older tools
cannot read records using the new states. Before downgrading, use the new CLI to
select an older supported state, such as Queued or Not queued. No conversion is
needed on upgrade.

## Inspect the ledger workflow

Custom states require the 0.39.0 CLI and matching frontend. Upgrade the tools
that share the ledger before entering a custom state.

Run `isled workflow show` to see the ledger’s workflow in TOML. Add `--json`
for structured output. An ordinary ledger uses the built-in definitions.

To create an editable copy, run `isled workflow init`. It writes
`.issues/workflow.toml` once and preserves existing edits. When present, the
file supplies the complete set of definitions reported by `workflow show`.
Keep the existing definitions you want and add your own. For example, a team
that integrates reviewed changes can give integration its own timer:

```toml
[states.integration]
label = "Integration"
clock = "manual"
```

```console
isled work set 42 integration
isled work resume 42
isled work pause 42
isled list --work-state integration --oldest-first
```

Entering a manual state leaves the clock stopped until someone starts work.
Use `auto` to start a span on entry or `off` for an untimed state.
Changing state or reason ends the previous span. Pause and resume keep the
issue’s place in its queue.

A state can also offer reasons. If you define reasons, select one on entry:

```toml
[states.integration.reasons.check]
label = "Final check"

[states.integration.reasons.decision]
label = "Decision needed"
prompt = "What needs deciding?"
```

Use `isled work set 42 integration --reason check`. For `decision`, also pass
`--question 'Which release should receive this fix?'`. Emacs asks for the text
using your prompt. Review and Question in the default workflow use this same
mechanism. A reason inherits its state's clock policy.

Start each ID with a lowercase letter. Use lowercase letters, digits and single
hyphens between words. Isled reserves `not-queued` for issues without a state.
Keep labels and prompts on one line, without pipes or surrounding spaces.

Use the same IDs in records, commands and filters. You can rename a
label without editing issues. Before retiring an ID, move issues out of its
queue. Existing records and time history remain readable after removal.

The following examples use the default workflow.

## Prepare an issue

```console
isled work plan 42
isled work prepare 42
```

**Planning** means discussing and developing the approach. **Prepared** means
the approach is settled enough to implement. Neither starts a timer; entering
either stops an active timer and keeps its history.

Keep the issue in Planning while discussing questions with the owner.

Queueing replaces the preparation stage. Skip stages or revisit them as needed.
Prepared does not mean prerequisites are complete or that implementation has
been authorized. Those decisions belong to your workflow.

## A small workflow

```console
isled work queue 42
isled work start 42 --activity Implementation
isled work pause 42
isled work start 42 --activity Testing
isled work await 42 --reason review
isled work show 42
```

Start a session, pause for a break, then resume. The log keeps both spans and
adds their time. Waiting and breaks stay out of the total.

| Action | Work state | Timer |
| --- | --- | --- |
| Plan | Planning | Stopped. |
| Mark prepared | Prepared | Stopped. |
| Queue | Queued | Stopped. |
| Start | In progress | Starts a span or keeps the current one running. |
| Resume | Unchanged | Starts timing if the state allows it. |
| Start with `--no-clock` | In progress | Stopped; records no new span. |
| Pause | Unchanged | Stops the current span. |
| Await review or clarification | Awaiting owner | Stopped. |
| Unqueue | Not queued | Stopped. |

Open/Closed remains the issue's lifecycle. Prerequisites determine readiness.
Work state records where the work stands; it grants no assignment or permission
to close an issue.

Repeating Start while the timer is running keeps the existing span. Pause first
to change its activity. Activity is an optional short label, such as
Implementation or Testing. `isled work unqueue 42` returns to Not queued while
keeping the history.

## Leave a question or request review

For review:

```console
isled work await 42 --reason review
```

For a decision you need before continuing implementation:

```console
isled work await 42 --reason clarification --question 'Should this also run offline?'
```

Clarification needs a non-empty question on one line. Review needs no question.
Ordinary planning questions stay in Planning. After an answer or review,
choose `work plan` to continue planning, `work prepare` when the approach is
settled, or `work start` to implement. These actions clear the owner-wait details
and keep completed spans.

## Arrival order

Use queues to choose the next task or review:

```console
isled list --ready --work-state queued --oldest-first --limit 1
isled list --work-reason review --oldest-first
isled search --work-reason clarification --oldest-first --limit 5 offline
```

**Since** records when an issue entered its current state. Oldest first sorts by
that time, then by issue ID. Older records with no Since come last, in ID order;
their age stays unknown until a real transition.

Repeating Plan, Mark prepared or Queue keeps the issue's place. Pausing and
resuming also keep Since.
Changing Review to Clarification starts a new wait; changing only the question
keeps the wait. Since measures the stay in a state; the work log measures time
spent working.

Ordinary listing keeps ID order. Omit `--limit` for all matches; zero returns
none. The limit applies after every filter and text match. Default state filters use
`not-queued`, `planning`, `prepared`, `queued`, `in-progress` and `awaiting-owner`.
They combine with readiness, status, kind and tags.

## In Emacs

Press **`w`** on the issue for preparation, queueing, timers, owner waits and history.
Choose **Set work state** (`w w`) to see this ledger’s states and reasons.
Use **Resume clock** (`w t`) to start timing in the current state.
**Start without timing** records only the state. Use `C-u` with Start to name
an activity.

Headings show **Planning**, **Prepared**, **Queued**, **In progress**, **Question**
or **Review**, with elapsed work time. While a timer runs, visible headings update
about once a second, including seconds after an hour: **In progress · 1h 02m 09s**.
The total includes earlier sessions. Stopping returns to the compact completed-time
display; Start without timing does not tick.

**Work history** shows the pending question, Since, numbered spans and the total,
including any running span at the moment you open it. Reopen it for an updated
total.

Filter with `s:open w:planning`, `s:open w:prepared`, `s:open w:queued` or
`s:open r:review`. Press **`S`** and choose **Oldest first** to see the complete matching queue in arrival order. You can
also use `o:oldest-first` or `o:id` in the query. **Hierarchy** follows
prerequisites; `v` switches between it and your last chosen flat order.
Emacs shows all matches; limits belong to the CLI.

A pending question also appears in the heading's help text. Normal editing
preserves tracking data. See the [Emacs work guide](../frontends/emacs/user-guide.md#work-state-and-time)
for the menu and timer corrections.

## A clock left running

Closing Emacs or ending a CLI command does not stop the timer. If you forgot to
pause, supply the actual stop time:

```console
isled work pause 42 --at '2026-10-06 09:30:00'
isled work show 42
isled work correct 42 2 --stop '2026-10-06 10:15:00'
```

Times are **UTC**, in `YYYY-MM-DD HH:MM:SS` format. Spans are numbered from 1.
Correct changes the stop of that span, including a running one. A stop cannot
precede its start or overlap the next span.

In Emacs, use `C-u` with Pause to enter the actual stop. **Correct stop time**
asks for a span number and UTC time; find the number in Work history.

Closing an issue stops timing, removes the current work state and keeps the
history. Closed issues allow explicit stop corrections, with a historical-edit
warning. Closure still requires its own authorization, Evidence and Outcome.

## Files and agent data

The [record format](record-format.md#optional-work-tracking) keeps state in
Metadata and spans in an optional Work log table. Activity labels may be empty;
otherwise they use one line without pipes or surrounding whitespace.

`isled work show 42 --json` returns schema 3:

| Field | Meaning |
| --- | --- |
| `id`, `state` | Issue identity and current work state. |
| `reason`, `question`, `since` | Selected reason, its prompt response, and the UTC entry time. Missing values are null. |
| `recorded_seconds` | Completed work time. |
| `running_since` | Running span's UTC start, or null. |
| `total_seconds` | Completed time plus the running span at report time. |
| `spans` | Ordered entries with `started`, nullable `stopped` and `activity`. |

Use `--at` to choose the report time explicitly. Snapshot/frontend schema 6 and
editor schema 5 carry the same work data. Browsing summaries omit spans;
complete issues and editor records include them.

Their totals include completed time only, with a separate running start.
Elapsed clock time alone does not change content hashes. Complete drafts expose
work as read-only data: use work actions for transitions and corrections.
