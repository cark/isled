#!/usr/bin/env python3
"""Build an installable source tar from the main library's package headers."""

import argparse
import io
import json
from pathlib import Path
import re
import tarfile


def package_metadata(frontend):
    source = (frontend / "isled.el").read_text(encoding="utf-8")
    def header(name):
        match = re.search(r"^;; " + name + r": (.+)$", source, re.MULTILINE)
        if not match:
            raise ValueError(f"Missing isled.el header: {name}")
        return match.group(1)
    version = header("Version")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("Expected a MAJOR.MINOR.PATCH package version")
    summary = re.search(r"^;;; isled.el --- (.*?)  -\*-", source).group(1)
    metadata = (';; -*- no-byte-compile: t; -*-\n'
                f'(define-package "isled" {json.dumps(version)}\n'
                f'  {json.dumps(summary)}\n'
                f"  '{header('Package-Requires')}\n"
                f"  :url {json.dumps(header('URL'))}\n"
                f"  :keywords '({' '.join(json.dumps(word) for word in re.split(r'[, ]+', header('Keywords')))}))\n")
    return version, metadata.encode("utf-8")


def build_archive(root, destination=None):
    frontend = root / "frontends/emacs"
    version, metadata = package_metadata(frontend)
    name = "isled-" + version
    destination = destination or frontend / "dist" / (name + ".tar")
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(".tar.tmp")
    # The main library owns declarations. Never package a stale generated file.
    sources = {path.name: path for path in sorted(frontend.glob("isled*.el"))
               if path.name != "isled-pkg.el"}
    for doc in ("README.md", "user-guide.md", "CONTRIBUTING.md",
                "images/hierarchy.gif", "images/filtering.gif", "images/editing.gif",
                "images/work-tracking.gif"):
        sources[doc] = frontend / doc
    sources["LICENSE"] = root / "LICENSE"
    try:
        with tarfile.open(temporary, "w", format=tarfile.USTAR_FORMAT) as archive:
            for relative in sorted([*sources, "isled-pkg.el"]):
                content = metadata if relative == "isled-pkg.el" else sources[relative].read_bytes()
                entry = tarfile.TarInfo(f"{name}/{relative}")
                entry.size, entry.mode, entry.mtime = len(content), 0o644, 0
                archive.addfile(entry, io.BytesIO(content))
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="Destination tar file")
    args = parser.parse_args()
    print(build_archive(Path(__file__).resolve().parent.parent, args.output))


if __name__ == "__main__":
    main()
