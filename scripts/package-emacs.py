#!/usr/bin/env python3
"""Build the Emacs source archive, including the project's license."""

from pathlib import Path
import re
import tarfile


def main():
    root = Path(__file__).resolve().parent.parent
    frontend = root / "frontends/emacs"
    metadata = (frontend / "isled-pkg.el").read_text()
    match = re.search(r'\(define-package "isled" "([0-9.]+)"', metadata)
    if not match:
        raise ValueError("Cannot read Emacs package version")
    name = "isled-" + match.group(1)
    destination = frontend / "dist" / (name + ".tar")
    destination.parent.mkdir(exist_ok=True)
    temporary = destination.with_suffix(".tar.tmp")
    try:
        with tarfile.open(temporary, "w", format=tarfile.USTAR_FORMAT) as archive:
            for path in [*sorted(frontend.glob("isled*.el")), frontend / "README.md", root / "LICENSE"]:
                archive.add(path, arcname=f"{name}/{path.name}", recursive=False)
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)
    print(destination)


if __name__ == "__main__":
    main()
