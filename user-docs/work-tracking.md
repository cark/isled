# Work state and time

Use work tracking when an issue moves between a queue, a worker and its owner.
It is optional. Ordinary issues need no extra fields: their work state is
**Not queued**, with no recorded time.

Work state answers who needs to act next. Open/Closed still describes the issue's
lifecycle, and dependency readiness still describes its prerequisites. Queuing
an issue or starting its clock does not assign a worker or authorize closure.

## A small workflow

```console
isled work queue 42
isled work start 42 --activity Implementation
isled work pause 42
isled work start 42 --activity Review
isled work await 42 --reason review
isled work show 42
```

Queueing starts no clock. Start selects **In progress** and starts timing;
Pause stops timing while leaving the issue In progress. Starting again adds
another span, so breaks and waiting time stay out of the total. Different issues
can run in parallel, with one worker and one running clock per issue.

For state tracking alone, use `isled work start 42 --no-clock`. This also stops
an already running clock. `isled work unqueue 42` stops timing and returns the
issue to Not queued. Queueing a running issue stops its clock too.

If you need an answer, keep the question with the current state:

```console
isled work await 42 --reason clarification --question 'Should this also run offline?'
```

Awaiting owner stops timing. Review needs no question; Clarification requires a
non-empty question on one line. Start again once work resumes; it clears the old
owner-wait details. Repeating Start while its clock is running keeps the existing
span. To change its activity, pause first.

Use `isled list --work-state queued` to find queued issues, or combine work state
with other filters: `isled list --ready --work-state not-queued`. Search accepts
the same work-state filter. The spellings are `not-queued`, `queued`, `in-progress`
and `awaiting-owner`.

## In Emacs

Press **`w`** on an issue for the Work menu. It offers the same queue, start,
pause, owner-wait and history actions, including **Start without timing**.
Use `C-u` with Start to supply an activity. Headings show **Queued**, **In
progress**, **Question** or **Review**, plus nonzero completed time. **Work
history** shows clock status, the full spans and the elapsed total at the time
you open it, including the running span.

Filter with `w:queued`, `w:in-progress` or another state. Combine it with status,
for example `s:open w:awaiting-owner`. A pending question appears in Work history
and in the heading's help text. Normal editing preserves all tracking data.

## A clock left running

Closing Emacs or ending a CLI invocation does not stop the clock. Isled cannot
know when you stopped working. Record the actual stop time explicitly:

```console
isled work pause 42 --at '2026-10-06 09:30:00'
isled work show 42
isled work correct 42 2 --stop '2026-10-06 10:15:00'
```

Times are **UTC**, in `YYYY-MM-DD HH:MM:SS` format. Work history numbers spans
from 1; Correct changes the stop of that numbered span, including a running one.
It rejects a stop before its start or after the next span's start.
In Emacs, `C-u` with Pause asks for the actual stop; Correct stop time asks for
the span number and UTC time.

Closing an issue stops its clock, keeps the complete history and removes its
current work state. Closed issues still allow explicit stop-time corrections,
with the usual historical-edit warning. Closure requires its own authorization,
evidence and outcome.

## Files and agent data

The [record format](record-format.md#optional-work-tracking) stores current state
in Metadata and spans in an optional Work log table. Activity labels may be empty;
when present they use one line without pipes or surrounding whitespace.

`isled work show 42 --json` returns schema 1 with `id`, `state`, `reason`,
`question`, `recorded_seconds`, `running_since`, `spans` and `total_seconds`.
Each span contains `started`, nullable `stopped` and `activity`.
`recorded_seconds` counts completed spans; `total_seconds` also counts the
running span at the report time. `--at` selects that report time explicitly.

Snapshot/frontend schema 4 and editor schema 3 carry the same stable work data.
Browsing summaries omit spans; complete issues and editor records include them.
Their totals contain completed time only, with a separate running start, so
clock passage alone does not invalidate content hashes. Work is read-only in
complete editor drafts: use work actions for transitions and corrections.

Existing records need no conversion. Once you use these fields, every tool that
reads or edits those records must understand the new format. Update the CLI and
Emacs frontend together; older versions cannot read work-tracked records.
