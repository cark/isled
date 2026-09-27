#!/usr/bin/env python3
"""Exercise real Emacs package managers against disposable release refs."""

import argparse
from datetime import datetime, timedelta
import json
import os
from pathlib import Path
import re
import runpy
import subprocess

from release_metadata import capture, match_one, source_revision

ROOT = Path(__file__).resolve().parent.parent


def run(*command, cwd=None, env=None):
    subprocess.run(command, cwd=cwd, env=env, check=True, timeout=600)


def fixture_repository(output, revision, pin):
    """Retain the candidate and one unreleased frontend with the same CLI pin."""
    source = output / "source"
    run("git", "init", "--quiet", str(source))
    run("git", "fetch", "--quiet", str(ROOT), revision, cwd=source)
    run("git", "checkout", "--quiet", "-b", "release", "FETCH_HEAD", cwd=source)
    run("git", "tag", "v" + pin, cwd=source)
    run("git", "checkout", "--quiet", "-b", "development", cwd=source)
    library = source / "frontends/emacs/isled.el"
    text = library.read_text(encoding="utf-8")
    version = match_one(r"^;; Version: (.+)$", text, "frontend version")
    parts = version.split(".")
    parts[-1] = str(int(parts[-1]) + 1)
    library.write_text(text.replace(";; Version: " + version,
                                    ";; Version: " + ".".join(parts), 1), encoding="utf-8")
    run("git", "add", "frontends/emacs/isled.el", cwd=source)
    # MELPA snapshots use commit dates; make the fixture's second version distinct.
    timestamp = datetime.fromisoformat(capture("git", "show", "-s", "--format=%cI", revision,
                                              cwd=source)) + timedelta(minutes=1)
    environment = dict(os.environ, GIT_AUTHOR_DATE=timestamp.isoformat(),
                       GIT_COMMITTER_DATE=timestamp.isoformat())
    run("git", "-c", "user.name=Isled packaging fixture", "-c", "user.email=fixture@example.invalid",
        "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "Unreleased frontend fixture",
        cwd=source, env=environment)
    development = capture("git", "rev-parse", "HEAD", cwd=source)
    return source, development


def check_case(args, source, manager, selector, expected_revision, pin):
    directory = args.output / (manager + "-" + selector)
    directory.mkdir()
    environment = dict(os.environ, ISLED_RECIPE_CHECK_DIR=str(directory),
                       ISLED_RECIPE_ROOT=str(ROOT), ISLED_RECIPE_SOURCE=str(source),
                       ISLED_RECIPE_SOURCE_URL=source.as_uri(),
                       ISLED_RECIPE_MANAGER=manager, ISLED_RECIPE_SELECTOR=selector,
                       ISLED_RECIPE_REVISION=expected_revision, ISLED_RECIPE_CLI_PIN=pin,
                       ISLED_CHECK_PACKAGE_DIR=str(args.dependencies),
                       ISLED_RECIPE_MELPA=str(args.melpa), ISLED_RECIPE_ELPACA=str(args.elpaca),
                       ISLED_RECIPE_STRAIGHT=str(args.straight), GIT_TERMINAL_PROMPT="0")
    try:
        with (directory / "check.log").open("w", encoding="utf-8") as log:
            subprocess.run([args.emacs, "-Q", "--batch", "-l",
                            str(ROOT / "frontends/emacs/test/package-recipes.el")],
                           env=environment, stdout=log, stderr=subprocess.STDOUT,
                           check=True, timeout=600)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        raise SystemExit(f"Failed {manager}/{selector}: {error}; see {directory / 'check.log'}") from None
    log = (directory / "check.log").read_text(encoding="utf-8")
    if re.search(r"^.*\.el:[0-9:]+ Error:|^Done \(.*\b[1-9][0-9]* failed", log, re.MULTILINE):
        raise ValueError(f"Compilation failures in {directory / 'check.log'}")
    receipt = json.loads((directory / "receipt.json").read_text(encoding="utf-8"))
    if receipt["revision"] != expected_revision or receipt["cli_pin"] != pin:
        raise ValueError(f"Wrong source or CLI pin in {manager}/{selector}")
    print(f"Passed {manager}/{selector}: CLI {pin}, source {expected_revision[:12]}", flush=True)
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", default="HEAD")
    parser.add_argument("--artifacts", type=Path, required=True)
    parser.add_argument("--dependencies", type=Path, required=True)
    parser.add_argument("--melpa", type=Path, required=True)
    parser.add_argument("--elpaca", type=Path, required=True)
    parser.add_argument("--straight", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="New directory; retains logs and fixtures")
    parser.add_argument("--emacs", default="emacs")
    parser.add_argument("--managers", nargs="+", choices=["melpa", "elpaca", "straight", "package-vc"],
                        default=["melpa", "elpaca", "straight", "package-vc"])
    parser.add_argument("--selectors", nargs="+", choices=["branch", "tag", "commit", "development"],
                        default=["branch", "tag", "commit", "development"])
    args = parser.parse_args()
    for name in ("artifacts", "dependencies", "melpa", "elpaca", "straight", "output"):
        setattr(args, name, getattr(args, name).resolve())
    revision = source_revision(ROOT, args.revision)
    staging = runpy.run_path(str(ROOT / "scripts/stage-release.py"))
    manifest = staging["verify"](args.artifacts)
    pin = match_one(r'\(defconst isled-required-cli-version "([^"]+)"',
                    (ROOT / "frontends/emacs/isled.el").read_text(encoding="utf-8"), "CLI pin")
    if pin != manifest["version"]:
        raise ValueError("Frontend CLI pin does not map to the verified staged artifacts")
    args.output.mkdir(parents=True, exist_ok=False)
    source, development = fixture_repository(args.output, revision, pin)
    receipts = []
    for manager in args.managers:
        for selector in args.selectors:
            if manager == "melpa" and selector in {"tag", "commit"}:
                continue  # Regular MELPA intentionally follows the release branch.
            expected = development if selector == "development" else revision
            receipts.append(check_case(args, source, manager, selector, expected, pin))
    result = {"source_revision": revision, "cli_version": pin,
              "artifact_source_revision": manifest["revision"], "cases": receipts,
              "tools": {name: capture("git", "rev-parse", "HEAD", cwd=getattr(args, name))
                        for name in ("melpa", "elpaca", "straight")}}
    (args.output / "results.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
