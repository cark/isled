"""Release identity, asset names and SHA-256 metadata shared by staging tools."""

import hashlib
import json
import re
import subprocess

TARGETS = {
    "x86_64-unknown-linux-musl": {"system": "Linux", "machine": "x86_64", "minimum_os": "Linux 5.4", "executable": "isled"},
    "aarch64-apple-darwin": {"system": "Darwin", "machine": "arm64", "minimum_os": "macOS 15.0", "executable": "isled"},
    "x86_64-pc-windows-msvc": {"system": "Windows", "machine": "amd64", "minimum_os": "Windows 10", "executable": "isled.exe"},
}
REPOSITORY = "cark/isled"


def capture(*args, cwd=None):
    return subprocess.check_output(args, cwd=cwd, text=True, encoding="utf-8").strip()


def match_one(pattern, source, label):
    matches = re.findall(pattern, source, re.MULTILINE)
    if len(matches) != 1:
        raise ValueError(f"Expected one {label}, found {len(matches)}")
    return matches[0]


def release_version(root):
    def read(name):
        return (root / name).read_text(encoding="utf-8")
    version = match_one(r'^version = "([0-9]+\.[0-9]+\.[0-9]+)"$', read("Cargo.toml"), "Cargo version")
    versions = {
        "Cargo.lock": match_one(r'name = "isled"\nversion = "([^"]+)"', read("Cargo.lock"), "lock version"),
        "flake.nix": match_one(r'pname = "isled";\s+version = "([^"]+)"', read("flake.nix"), "Nix version"),
        "isled.el": match_one(r'^;; Version: (.+)$', read("frontends/emacs/isled.el"), "Emacs version"),
        "CLI pin": match_one(r'\(defconst isled-required-cli-version "([^"]+)"', read("frontends/emacs/isled.el"), "CLI pin"),
    }
    for name, declared in versions.items():
        if declared != version:
            raise ValueError(f"Release version mismatch: Cargo={version}, {name}={declared}")
    return version


def source_revision(root, revision):
    revision = capture("git", "rev-parse", "--verify", revision + "^{commit}", cwd=root)
    subprocess.run(["git", "diff", "--exit-code", "--quiet", revision, "--"], cwd=root, check=True)
    if capture("git", "ls-files", "--others", "--exclude-standard", cwd=root):
        raise ValueError("Untracked source files: snapshot or commit the candidate before staging")
    return revision


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def asset(path):
    return {"name": path.name, "size": path.stat().st_size, "sha256": sha256(path)}


def verify_asset(directory, descriptor):
    name = descriptor["name"]
    if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", name):
        raise ValueError(f"Unsafe asset name: {name!r}")
    path = directory / name
    if path.is_symlink() or not path.is_file() or asset(path) != descriptor:
        raise ValueError(f"Missing or mismatched asset: {name}")
    return path


def archive_name(version, target):
    extension = ".zip" if target == "x86_64-pc-windows-msvc" else ".tar.gz"
    return f"isled-{version}-{target}{extension}"


def manifest_name(version):
    return f"isled-{version}-manifest.json"


def checksums_name(version):
    return f"isled-{version}-SHA256SUMS"


def write_json(path, document):
    path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))
