#!/usr/bin/env python3
"""Validate explicit input groups and publish a revision-bound artifact receipt."""
from concurrent.futures import ThreadPoolExecutor
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time

from release_evidence import Evidence, write_json
from release_inputs import file_hash, inputs


def exact_tree(root, revision):
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise RuntimeError("Candidate must be a full exact commit ID")
    value = subprocess.check_output(["jj", "--no-pager", "log", "-r", revision, "--no-graph", "-T", "commit_id"], cwd=root, text=True)
    delta = subprocess.check_output(["jj", "--no-pager", "diff", "--from", revision, "--to", "@", "--summary"], cwd=root, text=True)
    if value.strip() != revision or delta.strip():
        raise RuntimeError("Checkout differs from the exact candidate")


def artifact(store, revision):
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise RuntimeError("Candidate must be a full exact commit ID")
    return verify_directory(store / "validated" / revision, revision)


def verify_directory(directory, revision):
    try:
        receipt = json.loads((directory / "validation.json").read_text())
        binary = directory / "bin/isled"
        if (receipt["schema"] != 1 or receipt["revision"] != revision
                or receipt["success"] is not True or not os.access(binary, os.X_OK)
                or file_hash(binary) != receipt["artifact_sha256"]):
            raise ValueError("artifact does not match its receipt")
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise RuntimeError(f"No verified artifact for {revision}; run validate first: {error}") from error
    return binary


def validate(root, store, revision, check_nix):
    exact_tree(root, revision)
    if not os.environ.get("ISLED_PACKAGE_LINT_ROOT"):
        raise RuntimeError("Run validation inside the pinned development environment")
    keys = inputs(root, check_nix)
    evidence = Evidence(root, store, keys)
    started = time.monotonic()
    ready = threading.Event()
    cli = []

    def rust_track():
        try:
            cli.append(evidence.stage("debug", [["cargo", "test", "--locked", "--no-run", "--message-format=json"]], artifact=True))
        finally:
            ready.set()
        evidence.stage("rust", [["cargo", "fmt", "--check"], ["cargo", "check", "--locked"],
                                ["cargo", "test", "--locked"], ["cargo", "clippy", "--locked", "--all-targets", "--", "-D", "warnings"]])

    def emacs_track():
        evidence.stage("emacs-static", [["make", "-C", "frontends/emacs", "check", "ISLED_CHECK_PHASE=static"]])
        ready.wait()
        if not cli:
            raise RuntimeError("Candidate CLI preparation failed; frontend tests cannot run")
        evidence.stage("emacs-tests", [["make", "-C", "frontends/emacs", "check", "ISLED_CHECK_PHASE=tests", f"ISLED_CHECK_PROGRAM={cli[0]}"]])

    def helper_track():
        evidence.stage("helpers", [["shellcheck", "scripts/dogfood-release.sh", "scripts/test-dogfood-release.sh"],
                                   ["bash", "scripts/test-dogfood-release.sh"],
                                   ["python3", "-B", "scripts/test-release-validation.py"]])

    try:
        with ThreadPoolExecutor(max_workers=3) as pool:
            futures = [pool.submit(track) for track in (rust_track, emacs_track, helper_track)]
            # All tracks finish before reporting aggregate validation failure.
            errors = []
            for future in futures:
                try:
                    future.result()
                except Exception as error:
                    errors.append(str(error))
            if errors:
                raise RuntimeError("; ".join(errors))
        if check_nix:
            source = subprocess.check_output(["scripts/nix-source.sh"], cwd=root, text=True).strip()
            if not source or not Path(source).is_absolute():
                raise RuntimeError("Invalid filtered Nix source")
            evidence.stage("nix", [["nix", "flake", "check", f"path:{source}"]])
        else:
            print("Nix package check skipped (use --check-nix when due).", flush=True)
        binary = evidence.stage("optimized", [["cargo", "build", "--release", "--locked", "--config", "profile.release.incremental=true", "--message-format=json"]], artifact=True)
        # These inexpensive revision-specific checks never borrow old evidence.
        subprocess.run(["git", "show", "--format=", "--check", revision], cwd=root, check=True)
        subprocess.run(["scripts/check-coding-standards.sh", "--revision", revision], cwd=root, check=True)
        exact_tree(root, revision)
        if inputs(root, check_nix) != keys:
            raise RuntimeError("Validation inputs changed during the run; no receipt published")
        evidence.commit()
        receipt = dict(schema=1, revision=revision, success=True, inputs=keys,
                       artifact_sha256=file_hash(binary), stages=evidence.results,
                       seconds=time.monotonic() - started, nix_requested=check_nix)
        directory = store / "validated" / revision
        directory.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=".validation-", dir=directory.parent) as temp:
            prepared = Path(temp)
            (prepared / "bin").mkdir()
            shutil.copy2(binary, prepared / "bin/isled")
            write_json(prepared / "validation.json", receipt)
            if directory.exists():
                # Same exact revision may be validated again with an additional Nix gate.
                (prepared / "bin/isled").replace(directory / "bin/isled")
                write_json(directory / "validation.json", receipt)
            else:
                prepared.rename(directory)
        print(f"validated\t{revision}\t{receipt['seconds']:.3f}s", flush=True)
    finally:
        write_json(store / "timings" / f"{revision}.json", dict(stages=evidence.results, seconds=time.monotonic() - started))
        # Retain passing stages after failures only if all inputs remain readable
        # and unchanged. Losing a tool must not hide the original failure/timing.
        try:
            stable = inputs(root, check_nix) == keys
        except (OSError, RuntimeError):
            stable = False
        if stable:
            evidence.commit()


def main():
    command, root, store, revision, *options = sys.argv[1:]
    root, store = Path(root), Path(store)
    if command == "verify" and not options:
        print(verify_directory(root, revision))
        return
    if command == "artifact" and not options:
        print(artifact(store, revision))
        return
    if command != "validate" or options not in ([], ["--check-nix"]):
        raise RuntimeError("Invalid validation arguments")
    store.mkdir(parents=True, exist_ok=True)
    with (store / ".validation-lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        validate(root, store, revision, bool(options))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print(f"validation error: {error}", file=sys.stderr)
        sys.exit(2)
