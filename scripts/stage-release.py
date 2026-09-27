#!/usr/bin/env python3
"""Build native release parts, assemble and verify a set, or upload a draft."""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

from release_archive import pack_cli, unpack_cli
from release_metadata import (REPOSITORY, TARGETS, archive_name, asset, capture,
                              checksums_name, manifest_name, read_json, release_version,
                              source_revision, verify_asset, write_json)
from release_platform import build_environment, inspect_binary
from release_installation import check_installation

ROOT = Path(__file__).resolve().parent.parent


def run(*args, env=None, cwd=ROOT):
    print("+ " + " ".join(map(str, args)), flush=True)
    subprocess.run(list(map(str, args)), cwd=cwd, env=env, check=True)


def smoke_cli(program, version):
    with tempfile.TemporaryDirectory(prefix="isled release ") as temporary:
        root = Path(temporary)
        if capture(str(program), "--root", str(root / "absent"), "--version", cwd=root) != f"isled {version}":
            raise ValueError("Extracted executable has the wrong release identity")
        if list(root.iterdir()):
            raise ValueError("Version reporting changed the filesystem")
        check_installation(program, root / "shared storage é", version,
                           dict(os.environ, PATH=str(root / "empty-path")))
        run(program, "init", cwd=root)
        run(program, "add", "Prepare installation", "Exercise the packaged executable.", "--kind", "maintenance", cwd=root)
        run(program, "add", "Ship installation", "Depends on the preparation.", "--kind", "maintenance", cwd=root)
        run(program, "wait", "add", "2", "1", "Preparation precedes shipping.", cwd=root)
        run(program, "wait", "tree", "2", "--json", cwd=root)
        run(program, "check", cwd=root)


def build(args):
    version = release_version(ROOT)
    revision = source_revision(ROOT, args.revision)
    target = args.target
    env = build_environment(target, ROOT)
    args.output.mkdir(parents=True, exist_ok=False)
    report = {"schema_version": 1, "version": version, "revision": revision, "target": target,
              "rustc": capture("rustc", "-vV"), "cargo": capture("cargo", "--version"),
              "build_settings": {key: env[key] for key in ("RUSTFLAGS", "MACOSX_DEPLOYMENT_TARGET",
                    "CC_x86_64_unknown_linux_musl", "CFLAGS_x86_64_unknown_linux_musl",
                    "CFLAGS_aarch64_apple_darwin") if key in env}}
    run("cargo", "test", "--locked", "--release", "--features", "release-binary", "--no-fail-fast", env=env)
    run("cargo", "build", "--locked", "--release", "--features", "release-binary", "--bin", "isled", env=env)
    program = ROOT / "target" / target / "release" / TARGETS[target]["executable"]
    report["platform"] = inspect_binary(program, target)
    report["files"] = pack_cli(args.output, version, target, program, ROOT / "LICENSE", ROOT / "skills/isled")
    with tempfile.TemporaryDirectory(prefix="isled extracted ") as temporary:
        program = unpack_cli(args.output, report["files"], version, target, Path(temporary))
        smoke_cli(program, version)
        env["ISLED_CHECK_PROGRAM"] = str(program)
        env.pop("ISLED_CHECK_PHASE", None)
        run("emacs", "-Q", "--batch", "-l", "frontends/emacs/test/run-check.el", env=env)
    # A receipt is written only after all native checks pass.
    if source_revision(ROOT, revision) != revision:
        raise ValueError("Source changed during staging")
    report["checks"] = ["release Rust suite", "complete bundle SHA-256", "standalone installation and current paths", "extracted CLI smoke", "Emacs static and ERT against extracted CLI"]
    write_json(args.output / f"isled-{version}-{target}.build.json", report)
    print(f"Native part ready: {args.output}")


def assemble(args):
    version = release_version(ROOT)
    revision = source_revision(ROOT, args.revision)
    # Validate every part before creating the destination.
    reports = []
    for target in TARGETS:
        name = f"isled-{version}-{target}.build.json"
        matches = list(args.parts.rglob(name))
        if len(matches) != 1:
            raise ValueError(f"Expected one native receipt for {target}, found {len(matches)}")
        path = matches[0]
        report = read_json(path)
        if (report["schema_version"], report["version"], report["revision"], report["target"]) != (1, version, revision, target) or not report["checks"]:
            raise ValueError(f"Mismatched native receipt: {path}")
        verify_asset(path.parent, report["files"]["archive"])
        reports.append((path, report))
    args.output.mkdir(parents=True, exist_ok=False)
    binaries = {}
    for path, report in reports:
        target = report["target"]
        shutil.copy2(path, args.output / path.name)
        shutil.copy2(path.parent / report["files"]["archive"]["name"], args.output)
        binaries[target] = {**report["files"], "minimum_os": TARGETS[target]["minimum_os"], "build_report": asset(args.output / path.name)}
    package = args.output / f"isled-{version}.tar"
    run(sys.executable, "-B", "scripts/package-emacs.py", "--output", package)
    manifest = {"schema_version": 2, "version": version, "tag": f"v{version}", "revision": revision,
                "repository": REPOSITORY, "binaries": binaries, "emacs": asset(package)}
    write_json(args.output / manifest_name(version), manifest)
    files = sorted(path for path in args.output.iterdir() if path.is_file())
    sums = "".join(f"{asset(path)['sha256']}  {path.name}\n" for path in files)
    (args.output / checksums_name(version)).write_text(sums, encoding="utf-8")
    verify(args.output)
    print(f"Complete staged set: {args.output}")


def verify(directory):
    manifests = list(directory.glob("isled-*-manifest.json"))
    if len(manifests) != 1:
        raise ValueError("Expected exactly one release manifest")
    manifest = read_json(manifests[0])
    version = manifest["version"]
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) or not re.fullmatch(r"[0-9a-f]{40}", manifest["revision"]):
        raise ValueError("Invalid release version or source revision")
    if manifest["schema_version"] != 2 or manifest["tag"] != "v" + version or manifest["repository"] != REPOSITORY:
        raise ValueError("Invalid release manifest identity")
    if manifests[0].name != manifest_name(version) or set(manifest["binaries"]) != set(TARGETS):
        raise ValueError("Incomplete or misnamed release manifest")
    expected = [verify_asset(directory, manifest["emacs"]), manifests[0]]
    if manifest["emacs"]["name"] != f"isled-{version}.tar":
        raise ValueError("Unexpected Emacs package name")
    for target, binary in manifest["binaries"].items():
        expected.append(verify_asset(directory, binary["archive"]))
        report_path = verify_asset(directory, binary["build_report"])
        expected.append(report_path)
        report = read_json(report_path)
        if (report["revision"], report["version"], report["target"], report["files"]) != (manifest["revision"], version, target, {key: binary[key] for key in ("archive", "executable", "bundle")}):
            raise ValueError("Build report does not match the manifest")
        with tempfile.TemporaryDirectory(prefix="isled verify ") as temporary:
            unpack_cli(directory, binary, version, target, Path(temporary))
    sums = "".join(f"{asset(path)['sha256']}  {path.name}\n" for path in sorted(expected))
    if (directory / checksums_name(version)).read_text(encoding="utf-8") != sums:
        raise ValueError("Missing, invalid or mismatched SHA256SUMS")
    if {path.name for path in directory.iterdir()} != {path.name for path in expected} | {checksums_name(version)}:
        raise ValueError("Unexpected files in staged set")
    print(f"Verified {version} at {manifest['revision']}; no executable was run")
    return manifest


def find_release(tag):
    # GitHub's /releases/tags endpoint omits drafts without an existing Git tag.
    ids = capture("gh", "api", f"repos/{REPOSITORY}/releases", "--paginate", "--jq",
                  f'.[] | select(.tag_name == "{tag}") | .id').splitlines()
    if not ids:
        return None
    if len(ids) != 1 or not ids[0].isdigit():
        raise ValueError(f"Ambiguous release identity for {tag}")
    return json.loads(capture("gh", "api", f"repos/{REPOSITORY}/releases/{ids[0]}"))


def draft(args):
    manifest = verify(args.directory)
    # An existing draft is replaced only explicitly; published releases are refused.
    tag = manifest["tag"]
    existing = find_release(tag)
    if existing and (not existing["draft"] or not args.replace_draft):
        raise ValueError(f"{tag} already exists; only an unpublished draft with --replace-draft can be replaced")
    tags = capture("gh", "api", f"repos/{REPOSITORY}/tags", "--paginate", "--jq", ".[].name").splitlines()
    if tag in tags:
        raise ValueError(f"{tag} already has a Git tag; inspect its frozen identity before proceeding")
    revision = capture("gh", "api", f"repos/{REPOSITORY}/commits/{manifest['revision']}", "--jq", ".sha")
    if revision != manifest["revision"]:
        raise ValueError("Candidate revision is not available on GitHub")
    files = sorted(args.directory.iterdir())
    options = ["--repo", REPOSITORY, "--draft=true", "--target", revision,
               "--title", f"Isled {manifest['version']}", "--notes-file", args.notes]
    if existing:
        if {entry["name"] for entry in existing["assets"]} - {path.name for path in files}:
            raise ValueError("Draft contains unexpected assets; inspect them before replacement")
        run("gh", "release", "upload", tag, "--repo", REPOSITORY, "--clobber", *files)
        run("gh", "release", "edit", tag, *options)
    else:
        run("gh", "release", "create", tag, *options, *files)
    result = find_release(tag)
    if result is None:
        raise ValueError("Uploaded draft was not found")
    if not result["draft"] or result["target_commitish"] != revision:
        raise ValueError("Expected an unpublished draft of the exact candidate")
    expected = {(path.name, path.stat().st_size, "sha256:" + asset(path)["sha256"])
                for path in args.directory.iterdir()}
    uploaded = {(entry["name"], entry["size"], entry["digest"]) for entry in result["assets"]}
    if uploaded != expected:
        raise ValueError("Uploaded draft asset identities differ from the staged set")
    print(result["html_url"])
    print("Draft verified. Final candidate rebuild, acceptance and publication remain separate.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    builder = sub.add_parser("build", help="Build and validate one native target (Rust, Emacs and dependencies required)")
    builder.add_argument("--target", choices=TARGETS, required=True)
    builder.add_argument("--revision", default="HEAD")
    builder.add_argument("--output", type=Path, required=True, help="New output directory")
    assembler = sub.add_parser("assemble", help="Assemble three accepted parts from the same revision")
    assembler.add_argument("--revision", default="HEAD")
    assembler.add_argument("--parts", type=Path, required=True)
    assembler.add_argument("--output", type=Path, required=True, help="New output directory")
    verifier = sub.add_parser("verify", help="Check the complete set without executing binaries")
    verifier.add_argument("directory", type=Path)
    drafter = sub.add_parser("draft", help="Upload a verified set as an unpublished GitHub draft")
    drafter.add_argument("directory", type=Path)
    drafter.add_argument("--notes", type=Path, required=True)
    drafter.add_argument("--replace-draft", action="store_true", help="Explicitly replace a matching unpublished draft; never a published release or tag")
    args = parser.parse_args()
    for name in ("output", "parts", "directory", "notes"):
        if hasattr(args, name):
            setattr(args, name, getattr(args, name).resolve())
    if args.command == "verify":
        verify(args.directory)
    else:
        {"build": build, "assemble": assemble, "draft": draft}[args.command](args)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
