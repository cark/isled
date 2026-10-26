# Dependency drawing cases

`dependency-cases.json` defines graph inputs using prerequisite → dependent
pairs. It covers chains, roots, branches, joins, complete and partial sharing,
redundant direct edges, unrelated groups of different widths, and the
government/cabinet example.

Rust compares the current planner with `dependency-drawings.json` in both
directions. Emacs decodes those same payloads and an independent glyph reader
checks the final characters against every direct edge. Focused sketches protect
branch ownership; semantic validity alone does not establish readability.

After an intentional layout change, regenerate and review the fixture diff:

```sh
ISLED_UPDATE_DRAWINGS=1 cargo test --locked drawing_case_library --lib
```

The ERT suite also has a deliberately interleaved chain-crossing stress case.
That case tests painting; disconnected components remain contiguous in the real
planner. The ordinary frontend validation command runs all these checks.
