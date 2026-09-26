#!/usr/bin/env python3
"""Check tracked publication content for private state and broken local doc links."""

from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote, urlsplit

from repository_files import repository_root, tracked_paths


PRIVATE_PARTS = {".issues", ".dogfood", ".direnv", ".agent-shell", ".codex",
                 ".jj", ".git", ".check-packages", "__pycache__", "target"}
PRIVATE_FILES = {".worker-handoff.md", "agent-docs/current-work.md", "agent-docs/work-board.md"}
LOCAL_PATH = re.compile(r"(?<![A-Za-z0-9_%])/(?:home|Users)/[A-Za-z0-9_.-]+/|/nix/store/[a-z0-9]{20,}-|[A-Za-z]:[\\/]Users[\\/][A-Za-z0-9_.-]+[\\/]")
LINK = re.compile(r"\[[^\]\n]*\]\(<?([^\s)>]+)>?(?:\s+\"[^\"]*\")?\)")


def prose_lines(text):
    """Exclude fenced examples from Markdown link/heading interpretation."""
    fence = None
    for number, line in enumerate(text.splitlines(), 1):
        marker = re.match(r"^\s*(`{3,}|~{3,})", line)
        if marker:
            token = marker.group(1)
            if fence is None:
                fence = token
            elif token[0] == fence[0] and len(token) >= len(fence):
                fence = None
            continue
        if fence is None:
            yield number, line


def anchors(text):
    result, duplicates = set(), {}
    for _, line in prose_lines(text):
        result.update(re.findall(r'\bid=["\']([^"\']+)["\']', line))
        if re.match(r"^#{1,6}\s", line):
            heading = re.sub(r"^#+\s+|\s+#+$", "", line).lower()
            slug = re.sub(r"[^\w\- ]", "", heading).replace(" ", "-")
            count = duplicates.get(slug, 0)
            duplicates[slug] = count + 1
            result.add(f"{slug}-{count}" if count else slug)
    return result


def check(root, paths):
    """Return findings for the explicitly tracked file set, without following external links."""
    findings = []
    tracked = {p.as_posix() for p in paths}
    text_files = {}
    for path in paths:
        name, full = path.as_posix(), root / path
        if (PRIVATE_PARTS.intersection(path.parts) or name in PRIVATE_FILES
                or path.parts[0] == "research" or path.suffix in {".pyc", ".elc"}
                or name.startswith("frontends/emacs/dist/")):
            findings.append(f"{name}: private/generated path is tracked")
        if full.is_symlink():
            destination = full.resolve()
            if not destination.is_relative_to(root) or not destination.exists():
                findings.append(f"{name}: symlink requires a missing or external local resource")
            else:
                relative = destination.relative_to(root).as_posix()
                if not (relative in tracked or any(p.startswith(relative + "/") for p in tracked)):
                    findings.append(f"{name}: symlink requires an untracked resource")
            continue
        if not full.exists():
            continue  # A pending tracked deletion is not publication content.
        raw = full.read_bytes()
        if b"\0" in raw:
            continue
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            findings.append(f"{name}: non-UTF-8 text needs publication review")
            continue
        for number, line in enumerate(text.splitlines(), 1):
            # This one header-identity fixture intentionally uses a synthetic home.
            if name == "frontends/emacs/test/isled-header-test.el":
                line = line.replace("/home/" + "me/work/app/", "/example/app/")
            if LOCAL_PATH.search(line):
                findings.append(f"{name}:{number}: concrete workstation path")
        if path.suffix == ".md" and not name.startswith("frontends/emacs/test/fixtures/"):
            text_files[name] = text

    heading_sets = {name: anchors(text) for name, text in text_files.items()}
    for name, text in text_files.items():
        for number, line in prose_lines(text):
            for target in LINK.findall(line):
                parsed = urlsplit(target)
                if parsed.scheme in {"http", "https", "mailto"}:
                    continue
                if parsed.scheme or parsed.netloc or Path(unquote(parsed.path)).is_absolute():
                    findings.append(f"{name}:{number}: nonportable local link {target}")
                    continue
                destination = ((root / name).parent / unquote(parsed.path)).resolve() if parsed.path else root / name
                if not destination.is_relative_to(root):
                    findings.append(f"{name}:{number}: local link escapes checkout: {target}")
                    continue
                relative = destination.relative_to(root).as_posix()
                included = (relative in tracked or any(p.startswith(relative + "/") for p in tracked))
                if not destination.exists() or not included:
                    findings.append(f"{name}:{number}: missing/untracked local link {target}")
                elif parsed.fragment and relative in text_files and unquote(parsed.fragment) not in heading_sets[relative]:
                    findings.append(f"{name}:{number}: missing heading {target}")
    return findings


def main():
    root = repository_root().resolve()
    paths = tracked_paths(root)
    findings = check(root, paths)
    for finding in findings:
        print(finding, file=sys.stderr)
    print(f"Checked {len(paths)} tracked paths; {len(findings)} repository-boundary findings.")
    return bool(findings)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"repository check: {error}", file=sys.stderr)
        sys.exit(2)
