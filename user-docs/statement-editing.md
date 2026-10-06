# Editing statements

The Statement explains the concern and what needs to change. Add a paragraph,
replace a sentence, or supply the whole text through the CLI. Other sections
keep their own commands, such as `evidence add` and `outcome set`.

## Create with several paragraphs

Create an issue with its complete Statement in one operation:

```sh
isled add 'Issue title' --kind feature --stdin <<'EOF'
Explain the concern.

### Details

- First detail.
EOF
```

Use either a statement argument or `--stdin`. Creation validates before locking
or allocating an ID. Invalid input creates no record and consumes no ID.
Level-two headings are reserved even when supplied as a single-line argument.

## Append a paragraph

```sh
isled statement append 54 --stdin <<'EOF'
A new paragraph with "quotes", $variables, and `backticks` kept literally.

- Markdown lists work too.
EOF
```

Append adds a paragraph separator before the new text. A quoted heredoc keeps
shell variables, quotes and backticks literal.

## Replace the whole Statement

Set uses the supplied text as the complete Statement:

```sh
isled statement set 69 --stdin <<'EOF'
The complete new Statement.

### Details

- First detail.
EOF
```

Set and append accept a single-line TEXT argument or `--stdin`, never both.

## Change a passage

Replace reads the exact old passage, a separator line (default
`---replacement---`), and the new passage:

```sh
isled statement replace 54 --stdin <<'EOF'
The old sentence.
---replacement---
The improved sentence.
EOF
```

## Deleting and selecting repeated text

Delete by leaving the replacement empty; there is no separate delete command:

```sh
isled statement replace 54 --stdin <<'EOF'
Unwanted text
---replacement---
EOF
```

Matching is literal, case-sensitive, non-overlapping, and confined to Statement.
Exactly one match is required by default. For repeated text, use either
`--occurrence N` (one-based, from the beginning) or `--all`, never both.
No match, ambiguity, or an out-of-range occurrence leaves the issue unchanged.

For contextual edits, include the surrounding text in both passages: the entire
old passage is replaced. Replacement text is not searched again.

## Input framing and safety

Input is UTF-8 with LF line endings and is read to EOF before taking the store
lock.

The separator must occur exactly once as a complete line; use
`--separator 'another-marker'` when it occurs in either passage. The marker
must be non-empty and contain no line breaks. One LF immediately before the
separator and one final LF are framing and are removed, not matched or stored.

Creation, set and append also remove one final LF. Additional newlines remain literal.
Only a terminal stdin produces guidance on stderr; pipes receive no prompts.

The resulting Statement must satisfy the existing record grammar: non-empty,
no leading/trailing blank line, and no level-two (`## `) headings. Use level-three
headings for subsections. Invalid results, including deleting the whole
Statement, leave every file unchanged. Bytes outside Statement are preserved.
This final validation applies equally to argument-based `set` and `append`,
not just stdin commands. A rejected edit never emits a closed-history update
warning because nothing was published.
Editing closed history reports a warning; a byte-identical
replacement performs no write and emits no closed-history warning.
