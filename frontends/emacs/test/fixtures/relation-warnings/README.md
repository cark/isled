# Relation recovery demo

These are deliberately inconsistent baseline records, not a live ledger.
Keep this baseline unchanged during interactive tests. Work on the retained,
ignored copy at `.dogfood/relation-warning-demo/.issues/` instead of rebuilding
examples by hand. It is safe to repair or trash files in that copy.

From the repository root, reset the six known demo records:

```console
mkdir -p .dogfood/relation-warning-demo/.issues
cp frontends/emacs/test/fixtures/relation-warnings/0*.md .dogfood/relation-warning-demo/.issues/
cp frontends/emacs/test/fixtures/relation-warnings/next-id .dogfood/relation-warning-demo/.issues/.next-id
isled --root .dogfood/relation-warning-demo cache refresh
```

Reset overwrites those disposable records (including restoring trashed ones);
it does not delete additional files. Never point these commands at a real ledger.
Refresh the existing Emacs demo buffer after resetting. Cache refresh corrects
the stale copied title immediately; all other inconsistencies remain for testing.

- 0001/0002: missing Blocking mirror; completion keeps the dependent blocked.
- 0003: missing 0009 and unreadable 0004; removing one warning leaves the other.
- 0004: malformed Status; Open file supports manual correction; trash confirms,
  leaving removal of its relation as a separate action.
- 0005/0006: missing Waiting on half; completion asks for a reason.

After actions, point should stay with the affected issue, on a remaining warning
or its heading. Its screen position is best effort: ordinary buffer bounds and
point visibility take precedence. Retry after notification-driven refresh, too.
