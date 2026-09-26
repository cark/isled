#!/usr/bin/env python3
"""Focused headless checks for the interactive Emacs preview manager."""

from __future__ import annotations

import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock


SCRIPT = Path(__file__).with_name("emacs-preview.py")
SPEC = importlib.util.spec_from_file_location("emacs_preview", SCRIPT)
assert SPEC and SPEC.loader
PREVIEW = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PREVIEW)
REPO = SCRIPT.parent.parent


class PreviewTests(unittest.TestCase):
    def test_generated_bootstrap_has_valid_top_level_forms(self) -> None:
        emacs = PREVIEW.resolve_program(os.environ.get("ISLED_EMACS", "emacs"))
        with tempfile.TemporaryDirectory(prefix="isled-preview-lisp-") as directory:
            path = Path(directory) / "bootstrap.el"
            path.write_text(PREVIEW.bootstrap_text())
            form = """
(with-temp-buffer
  (insert-file-contents (getenv \"ISLED_PREVIEW_BOOTSTRAP\"))
  (emacs-lisp-mode)
  (check-parens)
  (goto-char (point-min))
  (condition-case nil
      (while t (read (current-buffer)))
    (end-of-file nil)))
"""
            environment = os.environ.copy()
            environment["ISLED_PREVIEW_BOOTSTRAP"] = str(path)
            subprocess.run([emacs, "-Q", "--batch", "--eval", form],
                           env=environment, capture_output=True, check=True)

    def test_exact_revision_and_frontend_materialization(self) -> None:
        exact = PREVIEW.exact_revision(REPO, "@", "jj")
        with tempfile.TemporaryDirectory(prefix="isled-preview-test-") as directory:
            destination = Path(directory) / "frontend"
            files = PREVIEW.materialize_frontend(REPO, exact, destination, "jj")
            self.assertIn("frontends/emacs/isled.el", files)
            expected = subprocess.run(
                ["jj", "file", "show", "-r", exact,
                 "frontends/emacs/isled.el"], cwd=REPO,
                capture_output=True, check=True).stdout
            self.assertEqual((destination / "isled.el").read_bytes(), expected)

    def test_wrong_process_identity_is_never_live(self) -> None:
        process = subprocess.Popen(["sleep", "2"])
        try:
            identity = PREVIEW.process_identity(process.pid)
            self.assertTrue(PREVIEW.identity_live(identity))
            identity["proc_start_time"] = str(int(identity["proc_start_time"]) + 1)
            self.assertFalse(PREVIEW.identity_live(identity))
        finally:
            process.terminate()
            process.wait(timeout=2)

    def test_list_ignores_malformed_manifests(self) -> None:
        with tempfile.TemporaryDirectory(prefix="isled-preview-list-") as directory:
            root = Path(directory)
            bad = root / "bad"
            bad.mkdir()
            (bad / "manifest.json").write_text("not json")
            self.assertEqual([], PREVIEW.manifests(root))

    def test_manifest_write_is_atomic_json(self) -> None:
        with tempfile.TemporaryDirectory(prefix="isled-preview-json-") as directory:
            path = Path(directory) / "manifest.json"
            PREVIEW.write_json(path, {"schema": 1, "status": "ready"})
            self.assertEqual("ready", json.loads(path.read_text())["status"])

    def test_log_capture_keeps_only_bounded_tail(self) -> None:
        content = b"prefix" + b"x" * 20 + b"tail"
        self.assertEqual(b"x" * 6 + b"tail",
                         PREVIEW.bounded_capture(io.BytesIO(content), 10))

    def test_private_environment_removes_shared_ipc(self) -> None:
        with tempfile.TemporaryDirectory(prefix="isled-preview-env-") as directory:
            with mock.patch.dict(os.environ, {
                    "DBUS_SESSION_BUS_ADDRESS": "owner-bus",
                    "EMACS_SOCKET_NAME": "owner-emacs",
                    "SSH_AUTH_SOCK": "owner-agent"}):
                environment = PREVIEW.private_environment(Path(directory))
            self.assertNotIn("DBUS_SESSION_BUS_ADDRESS", environment)
            self.assertNotIn("EMACS_SOCKET_NAME", environment)
            self.assertNotIn("SSH_AUTH_SOCK", environment)

    def test_sandbox_hides_host_processes(self) -> None:
        command = PREVIEW.sandbox_command(
            "bwrap", Path("/private/run"), Path("/private/socket"), None,
            ["emacs"])
        self.assertIn("--unshare-pid", command)
        self.assertEqual(command[command.index("--proc") + 1], "/proc")
        device = command.index("--dev-bind")
        self.assertEqual(command[device + 1:device + 3], ["/dev/null", "/dev/null"])

    def test_close_cleans_a_preview_already_closed_by_its_user(self) -> None:
        with tempfile.TemporaryDirectory(prefix="isled-preview-close-") as directory:
            run = Path(directory) / "preview-id"
            (run / "ledger").mkdir(parents=True)
            socket = Path(tempfile.mkdtemp(prefix="isled-preview-socket-", dir="/tmp"))
            path = run / "manifest.json"
            manifest = {
                "schema": PREVIEW.SCHEMA, "id": run.name,
                "run_directory": str(run), "status": "ready",
                "supervisor_process": {}, "emacs_process": {},
                "programs": {"emacsclient": "/unused/emacsclient"},
                "socket": str(socket / run.name),
                "socket_directory": str(socket),
            }
            PREVIEW.write_json(path, manifest)
            self.assertTrue(PREVIEW.close_one(path, manifest, 0.01))
            self.assertFalse((run / "ledger").exists())
            self.assertFalse(socket.exists())
            self.assertEqual("closed", json.loads(path.read_text())["status"])

    def test_cleanup_rejects_an_unowned_socket_path_before_deleting(self) -> None:
        with tempfile.TemporaryDirectory(prefix="isled-preview-owned-") as directory:
            run = Path(directory) / "preview-id"
            (run / "ledger").mkdir(parents=True)
            path = run / "manifest.json"
            manifest = {
                "schema": PREVIEW.SCHEMA, "id": run.name,
                "run_directory": str(run),
                "socket_directory": str(Path(directory) / "not-owned"),
            }
            self.assertFalse(PREVIEW.cleanup_preview(path, manifest))
            self.assertTrue((run / "ledger").is_dir())

    def test_close_all_includes_a_stopped_ready_preview(self) -> None:
        record = (Path("one/manifest.json"),
                  {"status": "ready", "supervisor_process": {},
                   "emacs_process": {}})
        args = SimpleNamespace(state_root=Path("unused"), all=True,
                               id=None, timeout=1)
        with (mock.patch.object(PREVIEW, "manifests", return_value=[record]),
              mock.patch.object(PREVIEW, "close_one", return_value=True) as close):
            self.assertEqual(0, PREVIEW.close_previews(args))
            close.assert_called_once()

    def test_close_all_attempts_every_live_preview(self) -> None:
        records = [(Path("one/manifest.json"), {"supervisor_process": {"pid": 1}}),
                   (Path("two/manifest.json"), {"supervisor_process": {"pid": 2}})]
        args = SimpleNamespace(state_root=Path("unused"), all=True,
                               id=None, timeout=1)
        with (mock.patch.object(PREVIEW, "manifests", return_value=records),
              mock.patch.object(PREVIEW, "identity_live", return_value=True),
              mock.patch.object(PREVIEW, "close_one",
                                side_effect=(False, True)) as close):
            self.assertEqual(1, PREVIEW.close_previews(args))
            self.assertEqual(2, close.call_count)


if __name__ == "__main__":
    unittest.main()
