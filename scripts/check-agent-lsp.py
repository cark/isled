"""Opt-in stdio MCP smoke check against this project's Rust source; no edits."""

import json
import os
from pathlib import Path
import queue
import signal
import subprocess
import threading
import time


def main():
    root = Path(__file__).resolve().parent.parent
    messages = queue.Queue()
    process = subprocess.Popen(
        ["bash", str(root / "scripts/start-agent-lsp.sh")],
        cwd=root, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        text=True, start_new_session=True,
    )

    def receive():
        for line in process.stdout:
            messages.put(json.loads(line))
        messages.put(None)

    threading.Thread(target=receive, daemon=True).start()
    request_id = 0

    def request(method, params):
        nonlocal request_id
        request_id += 1
        process.stdin.write(json.dumps({
            "jsonrpc": "2.0", "id": request_id, "method": method, "params": params,
        }) + "\n")
        process.stdin.flush()
        deadline = time.monotonic() + 120
        while True:
            try:
                response = messages.get(timeout=max(0, deadline - time.monotonic()))
            except queue.Empty as error:
                raise TimeoutError(f"MCP request timed out: {method} {params}") from error
            if response is None:
                raise RuntimeError("MCP server exited before replying")
            if response.get("id") == request_id:
                assert "error" not in response, response
                return response["result"]

    def call(name, arguments, initializing=False):
        started = time.monotonic()
        for attempt in range(5):
            result = request("tools/call", {"name": name, "arguments": arguments})
            if not (result.get("isError") and "content modified" in str(result)):
                break
            if attempt < 4:
                time.sleep(1)
        text = "\n".join(item.get("text", "") for item in result.get("content", []))
        if result.get("isError"):
            if initializing and "content modified" in text:
                return ""
            raise AssertionError(result)
        print(f"{name}: {time.monotonic() - started:.3f}s, {len(text)} chars", flush=True)
        return text

    try:
        request("initialize", {
            "protocolVersion": "2024-11-05", "capabilities": {},
            "clientInfo": {"name": "isled-smoke", "version": "1"},
        })
        process.stdin.write('{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
        process.stdin.flush()
        tools = request("tools/list", {})["tools"]
        print(f"Server advertises {len(tools)} tools", flush=True)
        call("start_lsp", {"root_dir": str(root), "language_id": "rust", "ready_timeout_seconds": 60})
        path = root / "src/filesystem/lock.rs"
        source = path.read_bytes()
        lines = source.decode().splitlines()
        line = next(i for i, text in enumerate(lines, 1) if "pub fn acquire_lock(" in text)
        column = lines[line - 1].index("acquire_lock") + 1
        position = {"file_path": str(path), "language_id": "rust", "line": line, "column": column}
        call("open_document", {"file_path": str(path), "language_id": "rust", "text": source.decode()})
        assert "acquire_lock" in call("list_symbols", {"file_path": str(path), "language_id": "rust", "format": "outline"})
        deadline = time.monotonic() + 60
        while "StoreLock" not in call("inspect_symbol", position, initializing=True):
            if time.monotonic() >= deadline:
                raise AssertionError("Rust Analyzer hover never became ready")
            time.sleep(1)
        action_line = next(i for i, text in enumerate(lines, 1) if "let cache = self.cache_dir()?;" in text)
        action_column = lines[action_line - 1].index("cache") + 1
        actions = call("suggest_fixes", {
            "file_path": str(path), "language_id": "rust",
            "start_line": action_line, "start_column": action_column,
            "end_line": action_line, "end_column": action_column,
        })
        # The bridge appends a prose hint after the JSON action array.
        proposals, _ = json.JSONDecoder().raw_decode(actions)
        explicit_types = [
            action for action in proposals
            if action["title"] == "Insert explicit type `PathBuf`"
        ]
        assert explicit_types, actions
        edits = [
            edit
            for change in explicit_types[0].get("edit", {}).get("documentChanges", [])
            for edit in change.get("edits", [])
        ]
        assert any(edit["newText"] == ": PathBuf" for edit in edits), explicit_types
        print("Code-action edit verified: Insert explicit type PathBuf", flush=True)
        reference_path = root / "src/filesystem/initialize.rs"
        reference_source = reference_path.read_bytes()
        reference_lines = reference_source.decode().splitlines()
        call("open_document", {"file_path": str(reference_path), "language_id": "rust", "text": reference_source.decode()})
        reference_line = next(i for i, text in enumerate(reference_lines, 1) if "pub fn initialize_ledger(" in text)
        references = call("find_references", {
            **position, "file_path": str(reference_path), "line": reference_line,
            "column": reference_lines[reference_line - 1].index("initialize_ledger") + 1,
            "include_declaration": False,
        })
        assert "commands/init.rs" in references, references
        assert reference_path.read_bytes() == reference_source, "Smoke check changed source"
        assert path.read_bytes() == source, "Smoke check changed source"
        print("Agent LSP semantic smoke passed", flush=True)
    finally:
        process.stdin.close()
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()


if __name__ == "__main__":
    main()
