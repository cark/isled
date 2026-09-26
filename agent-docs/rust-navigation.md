# Optional Rust semantic tools

Text search and compiler diagnostics suffice for ordinary contributions.
For symbol references, inferred types or code-action proposals, maintainers may
use the optional pinned agent-lsp/Rust Analyzer integration. It does not connect
to an Emacs session or change product runtime requirements.

The [flake](../flake.nix) pins the tool source, and
[the launcher](../scripts/start-agent-lsp.sh) enters the filtered development shell.
Opt-in client configuration can launch it with:

```toml
[mcp_servers.agent_lsp_rust]
command = "bash"
args = ["./scripts/start-agent-lsp.sh"]
startup_timeout_sec = 120
tool_timeout_sec = 120
enabled_tools = [
  "start_lsp", "get_server_capabilities", "open_document",
  "list_symbols", "find_symbol", "go_to_symbol", "get_symbol_source",
  "inspect_symbol", "go_to_definition", "go_to_implementation",
  "go_to_type_definition", "find_references", "find_callers",
  "get_diagnostics", "suggest_fixes", "prepare_rename",
  "did_change_watched_files",
]
```

Keep personal client configuration untracked. The client must launch from the
intended checkout; a copied config does not retarget an already-running bridge.
Restart only an owned bridge when its pin changes. Do not restart an unrelated
editor or language server to test this integration.

Start the server for the explicit workspace and Rust language, then open documents
with their current text. The pinned bridge's missing-text path can send an empty
buffer; reopen affected files after external changes. A startup `content modified`
response or empty result warrants a bounded retry and diagnosis, not a conclusion
that a symbol is absent. Fall back to source inspection when needed and state gaps.

Use semantic tools for concrete impact questions, with focused symbols/ranges and
refreshed contents. Returned code actions are proposals requiring normal review,
compilation and applicable behavior checks; extraction quality is not guaranteed.
The allowlist omits direct editing and publication tools. Follow
[refactoring requirements](refactoring.md) for any resulting changes.

The opt-in smoke check uses a separate bounded stdio session and never edits source
or contacts an editor:

```console
scripts/dev.sh -c python3 scripts/check-agent-lsp.py
```

The [script guide](../scripts/README.md#source-boundary) owns packaging commands and
input boundaries. Tool-specific checks apply when changing this integration, not
on every product edit.
