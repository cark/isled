# Structured Markdown record format

This is the current storage grammar. Use semantic CLI mutations for ordinary
changes. Legacy layouts are not silently converted by ordinary commands.

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

## Existing ledgers

The former `## Disposition` heading is not accepted by the current parser.
Existing ledgers require an explicit, backed-up heading migration before use;
ordinary commands do not convert them automatically. Keep authored prose
unchanged, including historical uses of the word. Historical one-time migration
tools are not part of the supported CLI.

## Grammar

- The existing strict level-one `# NNNN — Title` heading and canonical filename
  identity remain unchanged.
- `## Metadata`, `## Statement`, `## Evidence`, and `## Outcome` are
  mandatory, unique, and ordered. Prose may use headings at level three or
  below. The only additional level-two section is optional `## Work log`,
  between Statement and Evidence.
- Metadata is a Markdown list. `Status`, `Kind`, and `Created` are mandatory,
  unique, and ordered. Optional `Work state` follows Created; its nested
  Reason, Question and Since belong to that entry. `Tags` is one optional comma-and-space-separated line;
  tag order is preserved and an empty collection omits the line. Optional
  unique `Waiting on` and `Blocking` entries follow tags and contain nested
  relation lists. Each relation stores canonical `#NNNN — Title` text so the
  raw record is understandable without opening another file. Every `Waiting
  on` relation has one immediately nested, non-empty, single-line `Reason`;
  `Blocking` relations have no reason because the authoritative reason lives
  on the outgoing edge.
- Wait relations are intentionally mirrored. If A waits on B, A contains B in
  `Waiting on` and B contains A in `Blocking`. Reading relation-aware data
  validates the direct reciprocal entry and copied title. Changing a title
  updates that issue and the copied title in each directly related neighbor.
  Graph traversal remains lazy and operation-specific rather than making an
  ordinary record read recursively load a fixed number of hops.
- Closure preserves both mirrored entries. A dependency is a durable logical
  fact which blocks only while its target is open; a closed target satisfies
  the relation without deleting it. Closure is terminal, so no edge-state or
  later reactivation mechanism is required. True deletion semantics remain
  deferred until deletion is a concrete feature.
- Stored status, kind, tags, dates, and IDs retain their current canonical
  value grammar. Semantic frontends may display friendlier labels.
- Statement is non-empty Markdown. Evidence is a non-empty Markdown list whose
  entries retain the current non-empty single-line mutation boundary.
  `- Pending.` remains the generated no-evidence marker.
- Outcome is one non-empty Markdown paragraph, not a list. Existing wrapped
  paragraphs retain their physical line breaks; semantic CLI
  mutations continue to accept one non-empty line. `Pending.` remains the
  generated no-outcome marker.
- Permissive compact issue references are recognized only in Statement,
  Evidence, and Outcome. Canonical relation targets in Metadata remain
  structural but receive typed snapshot annotations so frontends can present
  them without parsing Markdown.
- Generated records use the exact blank-line structure shown and
  end with one newline. Free-form prose and an unchanged Work log retain their bytes during edits
  outside those fields.

## Optional work tracking

An absent Work state means Not queued; an absent Work log means no recorded time.
Existing records remain valid without either field. For the supported actions,
see [work state and time](work-tracking.md).

```markdown
- **Work state:** awaiting-owner
  - **Reason:** clarification
  - **Question:** Should this also run offline?
  - **Since:** 2026-10-06 10:30:00
```

Work state accepts `not-queued`, `queued`, `in-progress` and `awaiting-owner`.
Generated Not queued records omit the entry. Awaiting owner requires exactly one
nested Reason, `review` or `clarification`. Clarification also requires one
non-empty, single-line Question. Review has no Question. Other states have
neither owner-wait child. Queued, In progress and Awaiting owner may have one
Since child, after Reason and Question when present. It uses canonical UTC
`YYYY-MM-DD HH:MM:SS`. Missing Since means unknown age, including on older
tracked records. Not queued cannot have Since. Closed issues have no current
Work state.

Since marks the current uninterrupted state and owner-wait reason. Work actions
set it on genuine transitions; repeating an action or editing a question retains
it, even when unknown. Leaving and returning, or switching Review/Clarification,
sets a new timestamp. It is independent of the work-log clock.

When present, Work log contains exactly this three-column Markdown table, with
at least one span:

```markdown
## Work log

| Started (UTC)       | Stopped (UTC)       | Activity       |
|---------------------|---------------------|----------------|
| 2026-10-06 09:00:00 | 2026-10-06 09:30:00 | Implementation |
| 2026-10-06 10:00:00 |                     |                |
```

Column padding may vary. Generated tables widen Activity to fit the longest
label and align the header, separator and rows, including empty cells.
Unchanged logs keep their existing padding during unrelated edits.
Each separator cell contains at least three hyphens.
Start and stop use UTC `YYYY-MM-DD HH:MM:SS`, without fractional seconds or a
zone suffix. Activity may be empty; it cannot contain a pipe, newline, NUL or
surrounding whitespace. Cell padding is ignored when reading.

Spans are chronological and cannot overlap. A stop may equal its start or the
next span's start. Only the last span may have an empty stop, and that running
span requires In progress. Totals are calculated rather than stored in the file.
Work metadata and activities are structural data, outside prose-reference
recognition. Older tools cannot read records containing these new fields.
