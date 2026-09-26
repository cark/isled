# Dependency issue view

This page owns presentation, selection and performance rationale. The
[frontend guide](../frontends/emacs/README.md#dependency-graph-view) and
[wire contract](../user-docs/frontend.md#dependency-layout) own current behavior.

## Accepted presentation

Use one Emacs issue browser with optional hierarchical presentation, enabled by
default. Use `v` to switch between hierarchy and a flat ID-ordered
list while keeping ordinary filtering in both. This makes dependency structure
optional without separate queries or saved alternate-view state. Keep the obsolete
Find workflow removed. The switch preserves query, selection and expanded bodies;
returning to hierarchy reuses its last direction.
Use existing wait relations, not a new parent/child issue model. Display each
issue once, with aligned titles and a graph gutter showing branches and joins.
Keep existing readiness colors and issue-body expansion. This exposes which
issues depend on which, while a long chain consumes height rather than repeated
indentation. A DAG can share prerequisites; duplicating subtrees would obscure
identity and unnecessarily multiply rows.

Support prerequisites first and dependents first as presentation directions;
default to prerequisites first so the Open view puts actionable work at the
start of its threads. Reversing direction puts final objectives first and shows
what they require. Column placement follows that direction; it has no separate
starts/ends setting. Neither direction changes relation meaning. Retain the
selected issue when reversing direction if it remains included. Dependency order constrains
row order; the graph cannot promise arbitrary flat-list sorting at the same time.

Use a native text dot (`•`) for an issue with no incoming or outgoing edges in
the status-selected graph before tag, kind or text filtering, and a circle (`○`)
for every connected issue.
This distinguishes independent work from a thread's root, including when several
roots converge. Relations excluded by status do not affect the marker. Additional
filters retain
a circle and show counts when they hide direct neighbors; a filtered root is
not necessarily ready. Switching status may therefore change the marker. Reserve
the first graph column for
starts in the displayed direction, including independent issues. A connected
thread leaves that column for higher columns and stays there through its end;
ending a thread does not move its issue back to column one. Adjacent circles in
column one therefore never imply an edge. Roots are determined from the selected
visible graph, subject to the strict selection rules below.

Consecutive circles in an active higher lane express a straight chain without
an extra connector-only row between headings. Add routing rows only where a
horizontal connection is needed for a branch, join or lane change. Rounded corners
and directional junctions express the actual direct edges; lane reuse must not
create apparent connections. This notation replaces
the reviewed candidate's routing row after every heading as too much vertical
spacing. SVG circles and stems were explored but set aside to avoid synchronizing
image geometry with text scaling, line heights and wrapping.

### Junction clarity revision

Implemented by the shared drawing
steps described in the [wire contract](../user-docs/frontend.md#dependency-layout).

Forbid four-way junctions (`┼`). Separate a merge followed by a split onto
distinct routing rows, using corners and T junctions so readers can follow one
operation at a time. The occasional extra routing line is preferable to an
ambiguous intersection; its frequency on representative ledgers is not yet
measured. For the demo, both 0002 and 0004 feed both 0005 and 0008:

```text
○              0001 Contract
╰──┬──╮
   │  ○        0002 Rust layout
   ○  │        0004 Emacs gutter
   ╰──┤
      ├──╮
      │  ○     0008 Performance
      ○  │     0005 Integration
```

Shared routing segments are allowed only when they preserve exactly the actual
direct dependencies. Joining then splitting must never imply a dependency that
does not exist. Routing junctions are not additional issue nodes. Within a
connected group, lane placement and topologically valid row ordering may favor
clear routing over ID order, as when the demo places 0008 before 0005. Group
placement by smallest ID remains unchanged.

The implementation groups sources only when their complete destination sets
are identical. This conservative rule makes the shared segment's meaning exact
without searching for arbitrary overlapping subgraphs. Rust assigns the extra
routing steps and tracks; Emacs separates their merge and split strokes into
horizontal lines. Newly ready narrow branches precede broader branches to
reduce overlapping routes, with ID order breaking ties.
Drawing placement uses the direct-edge plan's width as a routing allowance:
prefer rightward splits within it, then reuse free columns before widening.
This preserves the demo's clear junctions without making repeated diamonds
or shared layers drift continually to the right.

Avoid crossings where practical. For unavoidable non-joining crossings, interrupt
the vertical stroke and retain the horizontal stroke, replacing the double-line
`╪` convention. This is distinct from a junction and does not connect the routes;
arbitrary DAGs are not promised a crossing-free layout.

### Bodies, ordering and readiness

Keep vertical dependency connectors continuous beside expanded bodies, including
wrapped lines. Body panels sit to the right of the graph gutter. Opening or
folding an issue changes vertical spacing without changing logical lane assignments
or issue order. Emacs owns the display geometry and reuses the retained Rust plan
rather than requesting a new layout for body expansion.

Keep each connected component of the selected visible graph contiguous,
following branches as far as dependency order allows. Place components by their
smallest issue ID, treating each independent issue as a singleton component.
This stays close to ID order without inserting unrelated issues inside threads;
adjacent independents naturally collect between groups. Do not force independents
to the top or bottom. Shared prerequisites or dependents tie threads into the
same group, so perfect branch locality inside a group remains best effort.

Column one means a root of the displayed graph, not a substitute for readiness.
In an unfiltered Open view its roots are ready, and closing prerequisites moves
the next actionable issues into column one. All/Closed views, additional filters and unavailable
blockers can break that equivalence; existing readiness colors remain authoritative.

Very wide DAGs may
look ugly in the first version. Wide gutters are an accepted visual limitation;
a compact layout or special wide-graph fallback is not a prerequisite for the
initial view. Keep every selected issue and direct relation represented rather
than dropping information to force a narrow gutter. This lets the simple,
measured layout serve ordinary graphs without delaying the feature for exceptional
shapes. Bounded loading, transport and responsiveness requirements still apply;
accepting awkward appearance does not establish acceptable rendering cost.

## Accepted selection

Open / Closed / All are strict: an Open view never includes closed issues as
context. Draw a direct edge only when both endpoints are included. Never replace
a hidden intermediate issue with an invented direct dependency. Readiness still
comes from the actual ledger, independently of the visible edges. Closed
prerequisites no longer block work, so excluding them from the Open graph
meaningfully exposes remaining work.

Tag, kind and full-text filters remove nonmatching issues after strict status
selection. Draw only direct edges between the remaining issues. If additional
filters hide a visible issue's direct neighbors, keep its circle; reserve dots
for independence within the status selection. Do not annotate headings with
filtered-connection notes because they clutter the view. Rust's counts retain
the marker distinction, exclude neighbors outside the status selection and never
infer transitive relationships. This preserves truthful filtering without making
a cut thread look independent or reintroducing closed context.

Rust owns matching, omitted-connection counts and layout over the complete
selected graph. Emacs receives compact results, retaining bounded body loading.
Full-text matching may still scan candidate records in Rust. The ordinary filter
prompt, completion, cancellation and navigation history serve both presentations;
toggling hierarchy or reversing direction preserves the complete query. Flat
requests omit graph data. Keep the separate Find workflow and saved alternate
query/state removed.

## Accepted performance approach

Use Rust for graph preparation while preserving the
5,000-issue loading and rendering work. The integration follows these boundaries;
performance claims require measurements of both Rust and Emacs:

- Obtain compact nodes and edges from the existing Rust cache; compute ordering
  and a deterministic lane plan in Rust through asynchronous requests. Emacs
  renders the retained plan. The current [bounded protocol](../user-docs/frontend.md)
  keeps ordinary summaries free of edges and adds an explicit opt-in layout;
  fetching complete snapshots or every body to discover edges would undo the
  established loading boundary.
- Reuse the [bounded loading model](../frontends/emacs/CONTRIBUTING.md#bounded-loading):
  one heading per issue, retained bodies by identity, and nearby expanded-body
  loading and presentation. Do not recompute the graph during scrolling or
  ordinary redisplay. Changes to graph membership/edges and direction can require
  layout work; prose-only edits should not. Change detection must include edges,
  since a relation can change without changing an issue's readiness.
- Keep graph extraction and traversal proportional to nodes and edges, using
  adjacency indexes rather than repeated whole-ledger searches. This does not
  establish a linear bound for lane placement or rendered text: long edge spans
  and many simultaneous lanes add costs. Prefer simple deterministic placement
  before expensive visual optimization; a Rust implementation alone does not
  make an inefficient algorithm or Emacs redisplay cheap.
- Measure the single view on the same current compiled candidate, including
  unfiltered and filtered selections. Measure
  Rust extraction/layout, payload and Emacs decoding, initial insertion,
  scrolling, body expansion, refresh, direction switching, allocation and GC
  separately. Existing external requests without a graph still avoid layout work.

The maintained [large-ledger fixture](../tests/large_ledger.rs) has 5,000 issues
and 4,000 edges in 1,000 disjoint five-issue chains. Retain it for regression
comparison, but add long chains, shared prerequisites, broad branches and joins,
and long-spanning edges when evaluating the graph. Node count alone is inadequate.
Separate transfer, decoding, rendering, scrolling and allocation costs in
[the retained graph benchmarks](../tests/large_ledger.rs). Historical timings
are not a current baseline or proof of another platform's behavior.

## Rust first pass and caching direction

Rust owns graph layout independently of Emacs. The inspectable
[text preview](../src/graph_layout/preview.rs) allows reviewing branches and joins
without a graphical session.

The recommended boundary is a window-independent Rust layout plan: ordered
issue IDs, node lanes, branches, joins and continuing lanes. Emacs turns that
plan into glyphs and faces and handles continuation beside expanded/wrapped
bodies. It should not rediscover dependency paths while painting the gutter.
Rust does not need Emacs window dimensions or body text to choose logical lanes.

Prepare the whole selected graph in Rust, regardless of which bodies Emacs has
loaded. The wire interface sends all selected compact headings but only
requested bodies. Compact graph rows carry node lanes, direct target row indices
and each target's earliest source. Emacs indexes continuing lane intervals once,
then paints only nearby rows without retaining a nodes-times-lanes glyph matrix.
Emacs must not reconstruct missing graph structure from body requests.

The Rust first pass implemented and measured a bounded persistent layout cache
to test reuse across short-lived requests. The comparison found that loading
and validating the saved plan was slower than computing
the layout again, including on the difficult synthetic graphs.

These results favor omitting persistent Rust layout caching from the integrated
version. Emacs retains the displayed logical
plan for scrolling, redisplay and body expansion. Rust prepares a new plan when
needed, including for a fresh view or changed membership, edges or direction;
prose-only edits do not invalidate the retained layout. Rust still obtains the
complete selected graph rather than relying on the bodies loaded by Emacs.
The existing metadata cache and its freshness/diagnostic rules remain applicable.

Keep persistent Rust layout caching as a possible future optimization, rather than an assumed requirement. Revisit it if a later algorithm
or representative workload makes reuse cheaper than recomputation. This replaces
the earlier proposed production caching direction; there is no need to integrate
the experimental store now.

## Accepted frontend compatibility boundary

Extend the existing schema-3 bounded frontend protocol additively. Existing
flat-view requests retain their behavior, and graph layout data is returned only
when explicitly requested. Graph view requires the updated CLI and Emacs
frontend; provide no graph fallback for older CLIs. This lets the updated CLI
continue serving existing flat-view clients during rollout without maintaining
alternative graph implementations. No issue-file migration is required. The
[compatibility contract](parity-contract.md#dependency-graph-extension)
records this boundary; exact fields belong in the bounded protocol documentation.

## Integration responsibilities

The presentation, ordering and compatibility choices are settled.
Very wide gutters are an accepted initial visual limitation; ordinary window
overflow handling belongs to the Emacs renderer. Rust prepares row/lane
relationships, while Emacs owns actual window widths, wrapping and redisplay.
The frontend retains the logical plan and composes gutters with existing body
panel prefixes. Concrete glyph strings are retained only near displaying windows;
offscreen rows reserve the same width with constant-size spacing. This avoids
allocating a full glyph matrix, including on very wide DAGs. Characters are built
in vectors before conversion to strings so wide Unicode gutters do not repeatedly
resize multibyte strings. If the gutter itself exceeds a window's width, ordinary
line truncation prevents unusable wrapping without changing the graph plan.
The [retained benchmark](../tests/support/emacs_graph_benchmark.rs) exercises
ordinary and difficult 5,000-issue graphs. Wide gutters retain a rendering cost;
measure it separately from typical graph and flat-list costs.
