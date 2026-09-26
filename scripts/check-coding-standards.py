#!/usr/bin/env python3
"""Report source size as an organization-review signal, never a cohesion verdict."""

import argparse
import subprocess
import sys

from repository_files import content, repository_root, revision_paths, tracked_paths


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", help="check files changed in this Git commit (including an initial commit)")
    args = parser.parse_args()
    root = repository_root()
    revision, paths = (revision_paths(root, args.revision) if args.revision
                       else (None, tracked_paths(root)))
    review = False
    for path in sorted(paths):
        if path.suffix not in {".rs", ".el", ".py", ".sh", ".md"}:
            continue
        if revision is None and not (root / path).exists():
            continue  # Tracked deletion in the working tree.
        count = sum(bool(line.strip()) for line in content(root, path, revision).splitlines())
        if path.suffix == ".md":
            category = "documentation"
        elif count >= 1000:
            category, review = "review-required", True
        else:
            category = "below-size-threshold"
        print(f"{category}\t{count}\t{path.as_posix()}")
    print("Size check only; cohesion not assessed. Source at 1,000 nonblank lines requires review.", file=sys.stderr)
    return 3 if review else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"coding-standards: {error}", file=sys.stderr)
        sys.exit(2)
