# Work state and time

See what is queued, what is being worked on, and what needs an answer or review.
If useful, keep the time spent on each issue too.

Tracking is optional. An ordinary issue is **Not queued**, with no recorded time.
There is one worker and at most one running timer per issue; different issues
can be worked on in parallel.

Use 0.35.0 or newer for work tracking and arrival-order queries. Keep the CLI
and frontend together; older tools cannot read records with these fields.

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
| Queue | Queued | Stopped. |
| Start / resume | In progress | Starts a new span, or keeps the current running span. |
| Start with `--no-clock` | In progress | Stopped; records no new span. |
| Pause | In progress | Stops the current span. |
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

For a decision you need before continuing:

```console
isled work await 42 --reason clarification --question 'Should this also run offline?'
```

Clarification needs a non-empty question on one line. Review needs no question.
Starting work again clears the owner-wait details. The completed spans stay in
the log.

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

Repeating Queue keeps the issue's place. Pausing and resuming also keep Since.
Changing Review to Clarification starts a new wait; changing only the question
keeps the wait. Since measures the stay in a state; the work log measures time
spent working.

Ordinary listing keeps ID order. Omit `--limit` for all matches; zero returns
none. The limit applies after every filter and text match. State filters use
`not-queued`, `queued`, `in-progress` and `awaiting-owner`, and combine with
readiness, status, kind and tags.

## In Emacs

Press **`w`** on the issue for queueing, timers, owner waits and history.
**Start without timing** records only the state. Use `C-u` with Start to name
an activity.

Headings show **Queued**, **In progress**, **Question** or **Review**, plus
nonzero completed time. **Work history** shows the pending question, Since,
numbered spans and the total, including any running span at the moment you open
it. It is a report, not a live stopwatch; reopen it for an updated total.

Filter with `s:open w:queued` or `s:open r:review`. Press **`S`** and choose
**Oldest first** to see the complete matching queue in arrival order. You can
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

`isled work show 42 --json` returns schema 2:

| Field | Meaning |
| --- | --- |
| `id`, `state` | Issue identity and current work state. |
| `reason`, `question`, `since` | Owner-wait details and UTC state-entry time; absent values are null. |
| `recorded_seconds` | Completed work time. |
| `running_since` | Running span's UTC start, or null. |
| `total_seconds` | Completed time plus the running span at report time. |
| `spans` | Ordered entries with `started`, nullable `stopped` and `activity`. |

Use `--at` to choose the report time explicitly. Snapshot/frontend schema 5 and
editor schema 4 carry the same work data. Browsing summaries omit spans;
complete issues and editor records include them.

Their totals include completed time only, with a separate running start.
Elapsed clock time alone does not change content hashes. Complete drafts expose
work as read-only data: use work actions for transitions and corrections.
