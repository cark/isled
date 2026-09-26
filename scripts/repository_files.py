"""Tracked-file selection for portable contributor checks."""

from pathlib import Path
import subprocess


def git(root, *arguments):
    return subprocess.check_output(["git", "-C", str(root), *arguments])


def repository_root():
    return Path(git(Path(__file__).resolve().parent, "rev-parse", "--show-toplevel")
                .decode().strip())


def tracked_paths(root):
    return [Path(name) for name in git(root, "ls-files", "-z").decode().split("\0") if name]


def revision_paths(root, revision):
    resolved = git(root, "rev-parse", "--verify", "--end-of-options",
                   revision + "^{commit}").decode().strip()
    names = git(root, "diff-tree", "--root", "--no-commit-id", "--name-only",
                "--diff-filter=ACMRT", "-r", "-z", resolved).decode().split("\0")
    return resolved, [Path(name) for name in names if name]


def content(root, path, revision=None):
    if revision:
        return git(root, "show", f"{revision}:{path.as_posix()}")
    return (root / path).read_bytes()
