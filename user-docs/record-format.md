# Structured Markdown record format

Issues stay readable as Markdown. Use the CLI or Emacs editor for ordinary
changes; this page is the reference for reading or recovering the files.

A basic issue needs no work state or timer. Tracking adds optional metadata and
a [Work log](#optional-work-tracking), leaving the same Statement, Evidence
and Outcome sections.

```markdown
# 0002 — Add search to the project overview

## Metadata

- **Status:** open
- **Kind:** task
- **Created:** 2026-09-04
- **Tags:** rust, frontend
- **Waiting on:**
  - #0001 — Add a project overview
    - **Reason:** The overview must exist before it can be searched.
- **Blocking:**
  - #0003 — Document project search

## Statement

The issue statement, with ordinary Markdown.

### Optional statement subsection

Prose headings begin at level three.

## Evidence

- First evidence item.
- Second evidence item.

## Outcome

Pending.
```

## Grammar

The heading is `# NNNN — Title`, with a matching canonical filename identity.
IDs and filenames stay stable when the title changes.

The required level-two sections are **Metadata**, **Statement**, **Evidence**
and **Outcome**, unique and in that order. The optional **Work log** goes
between Statement and Evidence. Prose subsections start at level three.

### Metadata

Metadata is a Markdown list, ordered as follows:

| Entry | Rule |
| --- | --- |
| Status, Kind, Created | Required, unique and ordered. |
| Work state | Optional, after Created; Reason, Question and Since are its children. |
| Tags | Optional comma-and-space-separated line; keeps tag order, omitted when empty. |
| Waiting on, Blocking | Optional unique entries with nested relation lists, after tags. |

Relation targets use `#NNNN — Title`, so you can read the raw file without
opening another record. Every Waiting on target has one immediately nested,
non-empty, single-line Reason. Blocking has no reason: the authoritative one
belongs to the outgoing Waiting on edge.

Relations are mirrored. If A waits on B, A lists B under Waiting on and B lists
A under Blocking. Inspection checks the needed reciprocal entries and titles;
a title change updates the issue and its direct neighbors.

Closure keeps both entries. A closed prerequisite satisfies the dependency
without erasing its history. Closure is permanent.

Status, kind, tags, dates and IDs use their canonical value grammar. Frontends
may display friendlier labels.

### Statement, Evidence and Outcome

Statement is non-empty Markdown. Evidence is a non-empty Markdown list;
semantic edits accept non-empty single-line entries. `- Pending.` marks the
absence of concrete evidence.

Outcome is one non-empty Markdown paragraph. Existing wrapped paragraphs keep
their physical line breaks; semantic CLI edits accept one non-empty line.
`Pending.` marks an unset outcome.

Compact prose references are recognized in Statement, Evidence and Outcome.
Metadata relation targets receive typed snapshot annotations, so frontends need
not parse their Markdown.

Generated records use the blank lines shown and end with one newline. Edits
outside authored prose or an unchanged Work log preserve those fields' bytes.

## Optional work tracking

No Work state means **Not queued**. No Work log means no recorded time. Existing
records remain valid without either. Use the [work commands](work-tracking.md)
for transitions, timers and corrections.

```markdown
- **Work state:** awaiting-owner
  - **Reason:** clarification
  - **Question:** Should this also run offline?
  - **Since:** 2026-10-06 10:30:00
```

| State | Children |
| --- | --- |
| `not-queued` | None; generated records omit the Work state entry. |
| `queued`, `in-progress` | Optional Since. |
| `awaiting-owner` with `review` | Required Reason; optional Since; no Question. |
| `awaiting-owner` with `clarification` | Required Reason and non-empty single-line Question; optional Since. |

Since follows Reason and Question when present. It uses UTC
`YYYY-MM-DD HH:MM:SS`; missing Since means unknown age. Closed issues have no
current Work state. Not queued cannot have Since.

Since changes on a real state or owner-wait-reason transition. Repeating an
action or editing the question keeps it, including an unknown value. Leaving
and returning starts a new stay. It is independent of the work timer.

### Work log

When present, Work log contains this three-column table with at least one span:

```markdown
## Work log

| Started (UTC)       | Stopped (UTC)       | Activity       |
|---------------------|---------------------|----------------|
| 2026-10-06 09:00:00 | 2026-10-06 09:30:00 | Implementation |
| 2026-10-06 10:00:00 |                     |                |
```

Column padding may vary. Generated tables widen Activity to fit the longest
label and align all rows, including empty cells. Unchanged logs keep their
padding during unrelated edits. Each separator cell needs at least three hyphens.

Start and stop use UTC `YYYY-MM-DD HH:MM:SS`, with no fractions or zone suffix.
Activity can be empty; otherwise it cannot contain a pipe, newline, NUL or
surrounding whitespace. Cell padding is ignored when reading.

Spans are chronological and cannot overlap. A stop may equal its start or the
next span's start. Only the last span can have an empty stop, and that running
span requires In progress. Totals are calculated, not stored.

Work metadata and activities are structural data, not prose references.
Older tools cannot read records with these fields; update the CLI and frontend
together.

## Existing ledgers

The former `## Disposition` heading is not accepted by the current parser.
Existing ledgers require an explicit, backed-up heading migration before use;
ordinary commands do not convert them automatically. Keep authored prose
unchanged, including historical uses of the word. Historical one-time migration
tools are not part of the supported CLI.
