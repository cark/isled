#!/usr/bin/env python3
"""Focused lifecycle tests for private-graphical-emacs.py."""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest


ROOT = Path(__file__).resolve().parent.parent
RUNNER = ROOT / "scripts/private-graphical-emacs.py"


FAKE_EMACS = r'''#!/usr/bin/env python3
import os
from pathlib import Path
import signal
import sys
import time

script = Path(os.environ["PI_GRAPHICAL_SCRIPT"])
if "--batch" in sys.argv:
    if "BROKEN_LISP" in script.read_text():
        print("invalid Lisp", file=sys.stderr)
        raise SystemExit(9)
    raise SystemExit(0)

events = Path(os.environ["FAKE_EVENTS"])
with events.open("a") as output:
    output.write("emacs-start\n")
behavior = os.environ.get("FAKE_EMACS_BEHAVIOR", "success")
result = Path(os.environ["PI_RESULT"])
if behavior == "success":
    result.write_text("(:passed t)")
    raise SystemExit(0)
if behavior == "no-result":
    raise SystemExit(0)
if behavior == "failed-result":
    result.write_text("(:failed t)")
    raise SystemExit(0)
if behavior == "nonzero":
    result.write_text("(:failed assertion)")
    raise SystemExit(7)
if behavior == "signal":
    os.kill(os.getpid(), signal.SIGTERM)
if behavior == "load-error":
    print("simulated load error", file=sys.stderr)
    raise SystemExit(70)
if behavior == "spam":
    sys.stdout.write("o" * 1100000)
    sys.stderr.write("e" * 1100000)
    result.write_text("(:failed noisy-child)")
    raise SystemExit(8)
if behavior == "hang":
    def stop(_number, _frame):
        with events.open("a") as output:
            output.write("emacs-term\n")
        raise SystemExit(0)
    signal.signal(signal.SIGTERM, stop)
    while True:
        time.sleep(1)
raise SystemExit(99)
'''


FAKE_XVFB = r'''#!/usr/bin/env python3
import os
from pathlib import Path
import signal
import socket
import sys
import time

events = Path(os.environ["FAKE_EVENTS"])
behavior = os.environ.get("FAKE_XVFB_BEHAVIOR", "ready")
if behavior == "startup-failure":
    print("simulated X startup failure", file=sys.stderr)
    raise SystemExit(3)
if behavior == "partial-display":
    print("220", end="", flush=True)
    while True:
        time.sleep(1)
display = None
directory = Path("/tmp/.X11-unix")
directory.mkdir(exist_ok=True)
for candidate in range(220, 1000):
    path = directory / f"X{candidate}"
    if not path.exists():
        display = candidate
        break
if display is None:
    raise SystemExit(4)
print(display, flush=True)
if behavior == "readiness-delay":
    time.sleep(0.2)
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(str(path))
server.listen()
with events.open("a") as output:
    output.write("x-ready\n")
def stop(_number, _frame):
    with events.open("a") as output:
        output.write("x-term\n")
    server.close()
    path.unlink(missing_ok=True)
    raise SystemExit(0)
if behavior == "ignore-term":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
else:
    signal.signal(signal.SIGTERM, stop)
while True:
    time.sleep(1)
'''


class RunnerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = Path(tempfile.mkdtemp(prefix="pi-runner-test-"))
        self.bin = self.temporary / "bin"
        self.bin.mkdir()
        self.emacs = self.executable("fake-emacs", FAKE_EMACS)
        self.xvfb = self.executable("fake-xvfb", FAKE_XVFB)
        self.script = self.temporary / "check.el"
        self.script.write_text("(message \"fixture\")\n")
        self.events = self.temporary / "events"
        self.display_paths = []

    def tearDown(self) -> None:
        for path in self.display_paths:
            path.unlink(missing_ok=True)
        shutil.rmtree(self.temporary, ignore_errors=True)

    def executable(self, name: str, content: str) -> Path:
        path = self.bin / name
        path.write_text(textwrap.dedent(content))
        path.chmod(0o755)
        return path

    def invoke(self, *, emacs_behavior="success", xvfb_behavior="ready",
               timeout=2.0, artifacts_name="evidence", extra=(),
               emacs_program=None, xvfb_program=None):
        artifacts = self.temporary / artifacts_name
        environment = os.environ.copy()
        environment.update(
            FAKE_EVENTS=str(self.events),
            FAKE_EMACS_BEHAVIOR=emacs_behavior,
            FAKE_XVFB_BEHAVIOR=xvfb_behavior,
        )
        command = [
            sys.executable, str(RUNNER), "--script", str(self.script),
            "--emacs", str(emacs_program or self.emacs),
            "--xvfb", str(xvfb_program or self.xvfb),
            "--artifacts", str(artifacts), "--startup-timeout", "1",
            "--timeout", str(timeout), "--cleanup-timeout", ".3", *extra,
        ]
        completed = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=8)
        summary = json.loads(completed.stdout.strip().splitlines()[-1]) if completed.stdout.strip() else {}
        metadata = json.loads((artifacts / "run.json").read_text()) if artifacts.exists() else None
        if metadata and metadata.get("xvfb", {}).get("display"):
            display = metadata["xvfb"]["display"].removeprefix(":")
            self.display_paths.append(Path(f"/tmp/.X11-unix/X{display}"))
        return completed, summary, metadata, artifacts

    def test_success_requires_result_and_cleans_artifacts(self):
        completed, summary, metadata, artifacts = self.invoke()
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertTrue(summary["success"])
        self.assertEqual(summary["result"], "(:passed t)")
        self.assertIsInstance(summary["emacs_pid"], int)
        self.assertIsInstance(summary["xvfb_pid"], int)
        self.assertTrue(summary["xvfb_reaped"])
        self.assertLessEqual(summary["emacs_finished_at"], summary["xvfb_cleanup_requested_at"])
        self.assertFalse(artifacts.exists())
        self.assertIsNone(metadata)
        self.assertEqual(self.events.read_text().splitlines(), ["x-ready", "emacs-start", "x-term"])

    def test_display_readiness_is_checked_after_displayfd(self):
        started = time.monotonic()
        completed, _summary, _metadata, _artifacts = self.invoke(xvfb_behavior="readiness-delay")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertGreaterEqual(time.monotonic() - started, 0.15)

    def test_invalid_lisp_fails_before_x_and_is_retained(self):
        self.script.write_text("BROKEN_LISP\n")
        completed, summary, metadata, artifacts = self.invoke()
        self.assertEqual(completed.returncode, 1)
        self.assertTrue(summary["retained"])
        self.assertTrue(artifacts.exists())
        self.assertEqual(metadata["preflight"]["exit_status"], 9)
        self.assertFalse(self.events.exists())

    @unittest.skipUnless(shutil.which("emacs"), "Emacs is unavailable")
    def test_real_emacs_reader_rejects_invalid_lisp_before_x(self):
        self.script.write_text('(message "unterminated)\n')
        completed, _summary, metadata, _artifacts = self.invoke(
            emacs_program=shutil.which("emacs")
        )
        self.assertEqual(completed.returncode, 1)
        self.assertNotEqual(metadata["preflight"]["exit_status"], 0)
        self.assertFalse(self.events.exists())

    @unittest.skipUnless(shutil.which("emacs") and shutil.which("Xvfb"),
                         "Emacs or Xvfb is unavailable")
    def test_real_startup_load_error_exits_without_debugger(self):
        self.script.write_text('(error "expected startup failure")\n')
        completed, _summary, metadata, artifacts = self.invoke(
            emacs_program=shutil.which("emacs"), xvfb_program=shutil.which("Xvfb")
        )
        self.assertEqual(completed.returncode, 1)
        self.assertTrue(artifacts.exists())
        self.assertEqual(metadata["emacs"]["exit_status"], 70)
        self.assertIn(":runner-load-error", metadata["result"]["content"])
        self.assertTrue(metadata["xvfb"]["cleanup"]["reaped"])

    def test_missing_prerequisite_is_retained(self):
        completed, _summary, metadata, artifacts = self.invoke(extra=("--require", "absent-pi-tool"))
        self.assertEqual(completed.returncode, 1)
        self.assertTrue(artifacts.exists())
        self.assertIn("executable is unavailable", metadata["runner_error"])

    def test_private_environment_cannot_be_overridden(self):
        completed, _summary, metadata, _artifacts = self.invoke(extra=("--env", "DISPLAY=:0"))
        self.assertEqual(completed.returncode, 1)
        self.assertIn("private environment cannot be overridden", metadata["runner_error"])

    def test_x_startup_failure_is_reported_and_reaped(self):
        completed, _summary, metadata, _artifacts = self.invoke(xvfb_behavior="startup-failure")
        self.assertEqual(completed.returncode, 1)
        self.assertIn("exited before publishing", metadata["runner_error"])
        self.assertTrue(metadata["xvfb"]["cleanup"]["reaped"])

    def test_partial_display_output_obeys_startup_timeout(self):
        started = time.monotonic()
        completed, _summary, metadata, _artifacts = self.invoke(xvfb_behavior="partial-display")
        self.assertEqual(completed.returncode, 1)
        self.assertLess(time.monotonic() - started, 3)
        self.assertIn("did not publish", metadata["runner_error"])
        self.assertTrue(metadata["xvfb"]["cleanup"]["reaped"])

    def test_exit_and_result_failures_are_retained(self):
        for index, behavior in enumerate(
                ("no-result", "failed-result", "nonzero", "signal", "load-error")):
            with self.subTest(behavior=behavior):
                completed, _summary, metadata, artifacts = self.invoke(
                    emacs_behavior=behavior, artifacts_name=f"evidence-{index}"
                )
                self.assertEqual(completed.returncode, 1)
                self.assertTrue(artifacts.exists())
                if behavior == "no-result":
                    self.assertFalse(metadata["result"]["present"])
                elif behavior == "failed-result":
                    self.assertEqual(metadata["emacs"]["exit_status"], 0)
                    self.assertFalse(metadata["result"]["success_marker_matched"])
                else:
                    self.assertNotEqual(metadata["emacs"]["exit_status"], 0)

    def test_child_logs_are_drained_but_bounded(self):
        completed, _summary, metadata, artifacts = self.invoke(emacs_behavior="spam")
        self.assertEqual(completed.returncode, 1)
        for name in ("stdout", "stderr"):
            log = artifacts / f"emacs.{name}.log"
            self.assertEqual(log.stat().st_size, 1024 * 1024)
            self.assertGreater(metadata["logs"][f"emacs_{name}"]["bytes_discarded"], 0)
            self.assertTrue(metadata["logs"][f"emacs_{name}"]["drained"])

    def test_timeout_reaps_emacs_before_x_and_remains_failure(self):
        completed, _summary, metadata, _artifacts = self.invoke(emacs_behavior="hang", timeout=.15)
        self.assertEqual(completed.returncode, 1)
        self.assertTrue(metadata["emacs"]["timeout"])
        self.assertTrue(metadata["emacs"]["cleanup"]["reaped"])
        events = self.events.read_text().splitlines()
        self.assertLess(events.index("emacs-term"), events.index("x-term"))

    def test_x_kill_escalation_is_a_cleanup_failure(self):
        completed, _summary, metadata, _artifacts = self.invoke(xvfb_behavior="ignore-term")
        self.assertEqual(completed.returncode, 1)
        self.assertEqual(metadata["xvfb"]["cleanup"]["signals"], ["SIGTERM", "SIGKILL"])
        self.assertTrue(metadata["xvfb"]["cleanup"]["reaped"])


if __name__ == "__main__":
    unittest.main()
