#!/usr/bin/env python3
"""Release evidence boundaries with disposable files and controlled subprocesses."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
from unittest.mock import patch

import release_inputs
from release_validation import artifact, validate
from release_evidence import cargo_executable


class ValidationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.store = self.root / "store"
        self.revision = "1" * 40
        for name in ["src/main.rs", "tests/example.rs", "Cargo.toml", "Cargo.lock",
                     "frontends/emacs/isled.el", "frontends/emacs/test/check.el", "scripts/helper.sh", "README.md",
                     "skills/isled/SKILL.md", "skills/isled/references/mutations.md", "skills/isled/references/recovery.md"]:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("original\n")
        self.calls = []
        self.fail = None
        self.change_during_run = False
        self.frontend_started = threading.Event()
        self.helpers_started = threading.Event()
        self.patches = [patch.object(release_inputs, "tools", return_value={"tools": "fixture"}),
                        patch.object(release_inputs, "environment", return_value={}),
                        patch("release_validation.exact_tree"),
                        patch.dict(os.environ, {"ISLED_PACKAGE_LINT_ROOT": "fixture"}),
                        patch("subprocess.run", side_effect=self.run_command),
                        patch("subprocess.check_output", return_value="/filtered-source\n")]
        for item in self.patches:
            item.start()
            self.addCleanup(item.stop)

    def run_command(self, command, **kwargs):
        self.calls.append(command)
        text = " ".join(command)
        if command[0] == "shellcheck":
            self.helpers_started.set()
        if self.fail and (self.fail == text or self.fail in command):
            return subprocess.CompletedProcess(command, 1)
        if "ISLED_CHECK_PHASE=static" in text:
            self.frontend_started.set()
        if command[:2] == ["cargo", "test"] and "--no-run" in command:
            self.assertTrue(self.frontend_started.wait(2), "static checks did not overlap CLI build")
            self.assertTrue(self.helpers_started.wait(2), "helper checks did not overlap CLI build")
            target = self.root / "target/debug/isled"
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(b"debug")
            target.chmod(0o755)
            self.report_artifact(target, kwargs["stdout"])
        if "ISLED_CHECK_PHASE=tests" in text:
            path = next(x.split("=", 1)[1] for x in command if x.startswith("ISLED_CHECK_PROGRAM="))
            self.assertEqual(Path(path).read_bytes(), b"debug")
        if command[:2] == ["cargo", "build"]:
            target = self.root / "target/release/isled"
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(b"optimized")
            target.chmod(0o755)
            self.report_artifact(target, kwargs["stdout"])
        if self.change_during_run and command[:2] == ["cargo", "build"]:
            (self.root / "src/main.rs").write_text("concurrent edit")
        return subprocess.CompletedProcess(command, 0)

    def report_artifact(self, target, stream):
        stream.write(json.dumps(dict(reason="compiler-artifact", target=dict(name="isled", kind=["bin"]), profile=dict(test=False), executable=str(target))) + "\n")

    def perform(self, revision=None, nix=False):
        validate(self.root, self.store, revision or self.revision, nix)
        return json.loads((self.store / "validated" / (revision or self.revision) / "validation.json").read_text())

    def test_reuse_and_input_groups(self):
        first = self.perform()
        self.assertTrue(all(not s["reused"] for s in first["stages"].values()))
        self.calls.clear()
        (self.root / "README.md").write_text("documentation change")
        second = self.perform("2" * 40)
        self.assertTrue(all(s["reused"] for s in second["stages"].values()))
        self.assertFalse(any(c[0] in ("cargo", "make") for c in self.calls))
        (self.root / "tests/example.rs").write_text("test-only change")
        third = self.perform("3" * 40)
        self.assertTrue(third["stages"]["optimized"]["reused"])
        self.assertTrue(third["stages"]["emacs-static"]["reused"])
        self.assertFalse(third["stages"]["rust"]["reused"])
        self.assertFalse(third["stages"]["emacs-tests"]["reused"])
        (self.root / "frontends/emacs/isled.el").write_text("frontend change")
        fourth = self.perform("4" * 40)
        self.assertTrue(fourth["stages"]["rust"]["reused"])
        self.assertTrue(fourth["stages"]["optimized"]["reused"])
        self.assertFalse(fourth["stages"]["emacs-static"]["reused"])
        (self.root / "src/main.rs").write_text("production change")
        fifth = self.perform("5" * 40)
        self.assertFalse(fifth["stages"]["optimized"]["reused"])
        self.assertTrue(fifth["stages"]["emacs-static"]["reused"])

    def test_failure_never_publishes_candidate(self):
        for failure in ["shellcheck", "--no-run", "cargo test --locked", "ISLED_CHECK_PHASE=static", "ISLED_CHECK_PHASE=tests", "nix flake check path:/filtered-source", "cargo build --release --locked --config profile.release.incremental=true --message-format=json"]:
            with self.subTest(failure=failure):
                self.store = self.root / ("failure-" + str(len(self.calls)))
                self.fail = failure
                with self.assertRaises(RuntimeError):
                    self.perform(nix=True)
                self.assertFalse((self.store / "validated" / self.revision).exists())

    def test_changed_inputs_do_not_publish_evidence(self):
        self.change_during_run = True
        with self.assertRaisesRegex(RuntimeError, "inputs changed"):
            self.perform()
        self.assertFalse((self.store / "validated" / self.revision).exists())
        self.assertFalse(list((self.store / "evidence").rglob("*.json")))

    def test_corrupt_artifact_is_rejected_and_build_cache_recovers(self):
        self.perform()
        binary = artifact(self.store, self.revision)
        binary.write_bytes(b"corrupted")
        with self.assertRaises(RuntimeError):
            artifact(self.store, self.revision)
        retained = next((self.store / "artifacts/optimized").glob("*/isled"))
        retained.write_bytes(b"corrupt cache")
        result = self.perform(self.revision)
        self.assertFalse(result["stages"]["optimized"]["reused"])
        self.assertEqual(artifact(self.store, self.revision).read_bytes(), b"optimized")

    def test_failed_run_retains_passing_stages(self):
        self.fail = "cargo test --locked"
        with self.assertRaises(RuntimeError):
            self.perform()
        self.fail = None
        result = self.perform()
        self.assertTrue(result["stages"]["debug"]["reused"])
        self.assertTrue(result["stages"]["emacs-tests"]["reused"])
        self.assertFalse(result["stages"]["rust"]["reused"])

    def test_skill_is_retained_and_changes_reuse_build_evidence(self):
        self.perform()
        skill = artifact(self.store, self.revision).parent.parent / "skill"
        (self.root / "skills/isled/SKILL.md").write_text("new instructions")
        self.assertEqual((skill / "SKILL.md").read_text(), "original\n")
        changed = self.perform("2" * 40)
        self.assertTrue(all(stage["reused"] for stage in changed["stages"].values()))
        next_skill = artifact(self.store, "2" * 40).parent.parent / "skill"
        self.assertEqual((next_skill / "SKILL.md").read_text(), "new instructions")

    def test_corrupt_or_incomplete_skill_is_rejected(self):
        self.perform()
        reference = artifact(self.store, self.revision).parent.parent / "skill/references/mutations.md"
        reference.write_text("corrupted")
        with self.assertRaisesRegex(RuntimeError, "skill does not match"):
            artifact(self.store, self.revision)
        reference.unlink()
        with self.assertRaisesRegex(RuntimeError, "Skill payload is incomplete"):
            artifact(self.store, self.revision)

    def test_cargo_output_selects_actual_binary(self):
        target = self.root / "custom-output/isled"
        target.parent.mkdir()
        target.write_text("executable")
        target.chmod(0o755)
        log = self.root / "cargo.log"
        with log.open("w") as stream:
            self.report_artifact(target, stream)
            stream.write(json.dumps(dict(reason="compiler-artifact", target=dict(name="isled", kind=["bin"]), profile=dict(test=True), executable="wrong-test-binary")) + "\n")
        self.assertEqual(cargo_executable(log), target)
        log.write_text("missing artifact")
        with self.assertRaises(RuntimeError):
            cargo_executable(log)

    def test_environment_and_checker_changes_invalidate(self):
        baseline = release_inputs.inputs(self.root)
        with patch.object(release_inputs, "environment", return_value={"RUSTFLAGS": "changed"}):
            changed = release_inputs.inputs(self.root)
        self.assertNotEqual(baseline["optimized"], changed["optimized"])
        (self.root / "scripts/release_evidence.py").write_text("checker changed")
        changed = release_inputs.inputs(self.root)
        self.assertTrue(all(baseline[k] != changed[k] for k in baseline))


if __name__ == "__main__":
    unittest.main()
