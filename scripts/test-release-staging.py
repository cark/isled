#!/usr/bin/env python3
"""Exercise archive integrity and candidate identity without running fixture binaries."""

import argparse
import importlib.util
import io
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

from release_archive import pack_cli, unpack_cli
from release_metadata import TARGETS, asset, read_json, release_version, source_revision, write_json
from release_upgrade import prepare

SCRIPTS = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("stage_release", SCRIPTS / "stage-release.py")
staging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(staging)


class ReleaseStaging(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="isled release tests ")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.root = self.base / "source"
        self.root.mkdir()
        self.write("Cargo.toml", '[package]\nname = "isled"\nversion = "1.2.3"\n')
        self.write("Cargo.lock", 'name = "isled"\nversion = "1.2.3"\n')
        self.write("flake.nix", 'pname = "isled";\nversion = "1.2.3";\n')
        self.write("frontends/emacs/isled.el", ';;; isled.el --- Fixture  -*- lexical-binding: t; -*-\n'
                   ';; Version: 1.2.3\n;; Package-Requires: ((emacs "30.1"))\n'
                   ';; URL: https://github.com/example/fixture\n;; Keywords: tools\n'
                   '(defconst isled-required-cli-version "1.2.3")\n')
        for name in ("README.md", "user-guide.md", "CONTRIBUTING.md", "images/hierarchy.gif", "images/filtering.gif"):
            self.write("frontends/emacs/" + name, "fixture\n")
        self.write("LICENSE", "fixture license\n")
        self.write("scripts/package-emacs.py", (SCRIPTS / "package-emacs.py").read_text())
        self.git("init", "--quiet")
        self.git("add", ".")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                 "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "fixture")
        self.revision = self.git("rev-parse", "HEAD").strip()
        self.program = self.base / "fixture-binary"
        self.program.write_bytes(b"never execute this fixture\n")
        self.parts = self.base / "parts"
        self.parts.mkdir()
        self.previous_root = staging.ROOT
        staging.ROOT = self.root
        self.addCleanup(setattr, staging, "ROOT", self.previous_root)

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(text.encode("utf-8"))

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.root), *args], text=True, stderr=subprocess.STDOUT)

    def part(self, target):
        files = pack_cli(self.parts, "1.2.3", target, self.program, self.root / "LICENSE")
        write_json(self.parts / f"isled-1.2.3-{target}.build.json",
                   {"schema_version": 1, "version": "1.2.3", "revision": self.revision,
                    "target": target, "files": files, "checks": ["fixture only"]})
        return files

    def assemble(self):
        output = self.base / "candidate"
        staging.assemble(argparse.Namespace(revision=self.revision, parts=self.parts, output=output))
        return output

    def test_archives_roundtrip_and_are_reproducible(self):
        for target in TARGETS:
            with self.subTest(target=target):
                files = self.part(target)
                archive = self.parts / files["archive"]["name"]
                original = archive.read_bytes()
                self.assertEqual(self.part(target), files)
                self.assertEqual(archive.read_bytes(), original)
                program = unpack_cli(self.parts, files, "1.2.3", target, self.base / target)
                self.assertEqual(program.read_bytes(), self.program.read_bytes())
                self.assertEqual(archive.suffix == ".zip", target.endswith("windows-msvc"))

    def test_corruption_fails_before_writing_an_executable(self):
        for target in TARGETS:
            with self.subTest(target=target):
                files = self.part(target)
                archive = self.parts / files["archive"]["name"]
                archive.write_bytes(archive.read_bytes() + b"corrupt")
                destination = self.base / target
                with self.assertRaisesRegex(ValueError, "mismatched asset"):
                    unpack_cli(self.parts, files, "1.2.3", target, destination)
                self.assertFalse(destination.exists())
                files = self.part(target)
                files["executable"]["sha256"] = "0" * 64
                with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                    unpack_cli(self.parts, files, "1.2.3", target, destination)
                self.assertFalse(destination.exists())

    def test_extra_archive_members_are_rejected_even_with_matching_checksum(self):
        for target in TARGETS:
            files = self.part(target)
            path = self.parts / files["archive"]["name"]
            if path.suffix == ".zip":
                with zipfile.ZipFile(path, "a") as archive:
                    archive.writestr("../../escape", b"bad")
            else:
                original = path.read_bytes()
                with tarfile.open(fileobj=io.BytesIO(original), mode="r:gz") as source:
                    with tarfile.open(path, "w:gz") as archive:
                        for entry in source.getmembers():
                            archive.addfile(entry, source.extractfile(entry))
                        link = tarfile.TarInfo("../../escape")
                        link.type, link.linkname = tarfile.SYMTYPE, "/tmp/outside"
                        archive.addfile(link)
            files["archive"] = asset(path)
            with self.assertRaisesRegex(ValueError, "archive contents"):
                unpack_cli(self.parts, files, "1.2.3", target, self.base / target)

    def test_assembly_rejects_missing_and_mixed_revision_parts(self):
        target = next(iter(TARGETS))
        self.part(target)
        with self.assertRaisesRegex(ValueError, "Expected one native receipt"):
            self.assemble()
        for target in TARGETS:
            self.part(target)
        receipt = self.parts / f"isled-1.2.3-{target}.build.json"
        report = read_json(receipt)
        report["revision"] = "0" * 40
        write_json(receipt, report)
        with self.assertRaisesRegex(ValueError, "Mismatched native receipt"):
            self.assemble()
        self.assertFalse((self.base / "candidate").exists())

    def test_complete_set_verifies_and_detects_metadata_damage(self):
        for target in TARGETS:
            self.part(target)
        output = self.assemble()
        self.assertEqual(staging.verify(output)["revision"], self.revision)
        sums = output / "isled-1.2.3-SHA256SUMS"
        sums.write_text("", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "SHA256SUMS"):
            staging.verify(output)

    def test_version_drift_and_dirty_source_are_rejected(self):
        self.assertEqual(release_version(self.root), "1.2.3")
        self.assertEqual(source_revision(self.root, self.revision), self.revision)
        self.write("flake.nix", 'pname = "isled";\nversion = "1.2.4";\n')
        with self.assertRaisesRegex(ValueError, "version mismatch"):
            release_version(self.root)
        with self.assertRaises(subprocess.CalledProcessError):
            source_revision(self.root, self.revision)
        self.write("flake.nix", 'pname = "isled";\nversion = "1.2.3";\n')
        self.write("untracked-source", "must snapshot\n")
        with self.assertRaisesRegex(ValueError, "Untracked"):
            source_revision(self.root, self.revision)

    def test_upgrade_fixture_is_reproducible_and_preserves_source(self):
        first = prepare(self.root, self.base / 'upgrade-a', self.revision)
        second = prepare(self.root, self.base / 'upgrade-b', self.revision)
        self.assertEqual(release_version(first), '1.2.4')
        self.assertEqual(release_version(self.root), '1.2.3')
        first_revision = source_revision(first, 'HEAD')
        self.assertEqual(first_revision, source_revision(second, 'HEAD'))
        self.assertNotEqual(first_revision, self.revision)
        changed = subprocess.check_output(['git', '-C', str(first), 'diff', '--name-only',
                                           self.revision, first_revision], text=True).splitlines()
        self.assertEqual(set(changed), {'Cargo.toml', 'Cargo.lock', 'flake.nix', 'frontends/emacs/isled.el'})
        self.assertEqual(source_revision(self.root, 'HEAD'), self.revision)

    def test_draft_refuses_existing_release_and_corrupt_input_before_upload(self):
        for target in TARGETS:
            self.part(target)
        output = self.assemble()
        args = argparse.Namespace(directory=output, notes=self.root / "LICENSE", replace_draft=False)
        for published, replace in [(False, False), (True, False), (True, True)]:
            args.replace_draft = replace
            with patch.object(staging, "find_release", return_value={"draft": not published}), patch.object(staging, "run") as upload:
                with self.assertRaisesRegex(ValueError, "already exists"):
                    staging.draft(args)
                upload.assert_not_called()
        (output / "isled-1.2.3-SHA256SUMS").write_text("bad", encoding="utf-8")
        with patch.object(staging, "capture") as remote, patch.object(staging, "run") as upload:
            with self.assertRaisesRegex(ValueError, "SHA256SUMS"):
                staging.draft(args)
            remote.assert_not_called()
            upload.assert_not_called()

    def test_draft_lookup_uses_release_id_before_a_tag_exists(self):
        draft = {"id": 17, "tag_name": "v1.2.3", "draft": True}
        with patch.object(staging, "capture", side_effect=["17", json.dumps(draft)]) as remote:
            self.assertEqual(staging.find_release("v1.2.3"), draft)
            self.assertEqual(remote.call_args.args, ("gh", "api", "repos/cark/isled/releases/17"))


if __name__ == "__main__":
    unittest.main()
