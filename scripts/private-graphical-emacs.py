#!/usr/bin/env python3
"""Run one Emacs Lisp check on an owned private X display."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import selectors
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time


PRIVATE_ENVIRONMENT_KEYS = (
    "DBUS_SESSION_BUS_ADDRESS",
    "DISPLAY",
    "EMACS_SOCKET_NAME",
    "INSIDE_EMACS",
    "SESSION_MANAGER",
    "WAYLAND_DISPLAY",
    "XAUTHORITY",
)
PRIVATE_PATH_KEYS = {
    "HOME",
    "TMPDIR",
    "XDG_CACHE_HOME",
    "XDG_CONFIG_HOME",
    "XDG_DATA_HOME",
    "XDG_RUNTIME_DIR",
    "XDG_STATE_HOME",
}
LOG_LIMIT = 1024 * 1024


def timestamp() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def write_metadata(path: Path, metadata: dict) -> None:
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


class BoundedCapture:
    """Drain a child pipe while retaining at most a fixed byte count."""

    def __init__(self, stream, path: Path, prefix: bytes = b"") -> None:
        self.stream = stream
        self.path = path
        self.kept = 0
        self.discarded = 0
        self.thread = threading.Thread(target=self._copy, args=(prefix,), daemon=True)
        self.thread.start()

    def _copy(self, prefix: bytes) -> None:
        with self.path.open("wb") as output:
            for chunk in (prefix,):
                self._write(output, chunk)
            while True:
                chunk = self.stream.read(65536)
                if not chunk:
                    break
                self._write(output, chunk)

    def _write(self, output, chunk: bytes) -> None:
        available = max(0, LOG_LIMIT - self.kept)
        retained = chunk[:available]
        if retained:
            output.write(retained)
            self.kept += len(retained)
        self.discarded += len(chunk) - len(retained)

    def finish(self) -> dict:
        self.thread.join(timeout=2)
        return {
            "bytes_retained": self.kept,
            "bytes_discarded": self.discarded,
            "drained": not self.thread.is_alive(),
        }


def process_identity(process: subprocess.Popen) -> dict:
    identity = {"pid": process.pid}
    try:
        identity["proc_start_time"] = Path(f"/proc/{process.pid}/stat").read_text().split()[21]
    except (FileNotFoundError, PermissionError, ProcessLookupError):
        identity["proc_start_time"] = None
    return identity


def identity_matches(process: subprocess.Popen, identity: dict) -> bool:
    if process.pid != identity["pid"]:
        return False
    if process.poll() is not None:
        return True
    expected = identity.get("proc_start_time")
    if expected is None:
        return False
    try:
        return Path(f"/proc/{process.pid}/stat").read_text().split()[21] == expected
    except (FileNotFoundError, PermissionError, ProcessLookupError):
        return False


def stop_owned(process: subprocess.Popen, identity: dict, timeout: float) -> dict:
    """Stop and reap one verified direct child within two bounded waits."""
    outcome = {"requested_at": timestamp(), "signals": [], "reaped": False}
    if process.poll() is not None:
        outcome.update(exit_status=process.returncode, reaped=True, finished_at=timestamp())
        return outcome
    if not identity_matches(process, identity):
        outcome.update(error="owned process identity could not be verified", finished_at=timestamp())
        return outcome
    process.send_signal(signal.SIGTERM)
    outcome["signals"].append("SIGTERM")
    try:
        status = process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        if not identity_matches(process, identity):
            outcome.update(error="process identity changed before SIGKILL", finished_at=timestamp())
            return outcome
        process.send_signal(signal.SIGKILL)
        outcome["signals"].append("SIGKILL")
        try:
            status = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            outcome.update(error="owned process could not be reaped after SIGKILL", finished_at=timestamp())
            return outcome
    outcome.update(exit_status=status, reaped=True, finished_at=timestamp())
    return outcome


def parse_environment(values: list[str]) -> dict[str, str]:
    result = {}
    for value in values:
        name, separator, content = value.partition("=")
        if not separator or not name or not name.replace("_", "A").isalnum():
            raise ValueError(f"invalid environment assignment: {value!r}")
        result[name] = content
    return result


def resolve_program(value: str) -> str:
    if os.sep in value:
        path = Path(value).expanduser().resolve()
        if not path.is_file() or not os.access(path, os.X_OK):
            raise ValueError(f"executable is unavailable: {path}")
        return str(path)
    found = shutil.which(value)
    if found is None:
        raise ValueError(f"executable is unavailable on PATH: {value}")
    return found


def wait_for_display(process: subprocess.Popen, timeout: float, log_path: Path) -> tuple[str, bytes]:
    assert process.stdout is not None
    descriptor = process.stdout.fileno()
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    output = bytearray()
    deadline = time.monotonic() + timeout
    os.set_blocking(descriptor, False)
    try:
        while b"\n" not in output:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not selector.select(remaining):
                raise RuntimeError(f"Xvfb did not publish a display within {timeout:g} seconds")
            chunk = os.read(descriptor, min(65536, LOG_LIMIT + 1 - len(output)))
            if not chunk:
                status = process.poll()
                raise RuntimeError(
                    "Xvfb closed display output before publishing a display"
                    if status is None
                    else f"Xvfb exited before publishing a display: {status}"
                )
            output.extend(chunk)
            if len(output) > LOG_LIMIT:
                raise RuntimeError(f"Xvfb display output exceeded {LOG_LIMIT} bytes")
    finally:
        selector.close()
        os.set_blocking(descriptor, True)
        log_path.write_bytes(output[:LOG_LIMIT])
    line = bytes(output).split(b"\n", 1)[0]
    display = line.decode(errors="replace").strip()
    if not display.isdigit():
        raise RuntimeError(f"Xvfb published an invalid display number: {display!r}")
    return display, bytes(output)


def wait_for_x_socket(process: subprocess.Popen, display: str, timeout: float) -> None:
    path = f"/tmp/.X11-unix/X{display}"
    deadline = time.monotonic() + timeout
    last_error = None
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"Xvfb exited during readiness check: {process.returncode}")
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            client.settimeout(0.2)
            client.connect(path)
            return
        except OSError as error:
            last_error = error
        finally:
            client.close()
        time.sleep(0.02)
    raise RuntimeError(f"X display :{display} was not ready within {timeout:g} seconds: {last_error}")


def lisp_preflight(program: str, script: Path, environment: dict[str, str], timeout: float,
                   stdout_path: Path, stderr_path: Path) -> dict:
    form = r"""
(let ((file (getenv "PI_GRAPHICAL_SCRIPT")))
  (with-temp-buffer
    (insert-file-contents file)
    (emacs-lisp-mode)
    (check-parens)
    (goto-char (point-min))
    (condition-case nil
        (while t (read (current-buffer)))
      (end-of-file nil))))
""".strip()
    command = [program, "-Q", "--batch", "--eval", form]
    process = subprocess.Popen(
        command,
        cwd=script.parent,
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    identity = process_identity(process)
    assert process.stdout is not None and process.stderr is not None
    stdout = BoundedCapture(process.stdout, stdout_path)
    stderr = BoundedCapture(process.stderr, stderr_path)
    timed_out = False
    cleanup = None
    try:
        status = process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        cleanup = stop_owned(process, identity, timeout)
        status = process.returncode
    outcome = {
        "command": command,
        **identity,
        "exit_status": status,
        "timeout": timed_out,
        "stdout": stdout.finish(),
        "stderr": stderr.finish(),
    }
    if cleanup is not None:
        outcome["cleanup"] = cleanup
    return outcome


def load_form() -> str:
    return r"""
(condition-case failure
    (load (getenv "PI_GRAPHICAL_SCRIPT") nil nil t)
  (error
   (condition-case nil
       (with-temp-file (getenv "PI_RESULT")
         (prin1 (list :runner-load-error failure) (current-buffer)))
     (error nil))
   (message "Private graphical script load failed: %S" failure)
   (kill-emacs 70)))
""".strip()


def run(args: argparse.Namespace) -> tuple[int, dict, Path]:
    artifacts = args.artifacts.resolve() if args.artifacts else Path(
        tempfile.mkdtemp(prefix="isled-graphical-", dir=args.artifacts_root)
    )
    if args.artifacts:
        if artifacts.exists():
            raise ValueError(f"refusing existing artifacts directory: {artifacts}")
        artifacts.mkdir(mode=0o700, parents=True)
    metadata_path = artifacts / "run.json"
    metadata = {"started_at": timestamp(), "artifacts": str(artifacts), "success": False}
    failed = False
    xvfb = emacs = None
    xvfb_identity = emacs_identity = None
    captures: dict[str, BoundedCapture] = {}
    environment = os.environ.copy()
    for key in PRIVATE_ENVIRONMENT_KEYS:
        environment.pop(key, None)
    for name in ("home", "cache", "config", "data", "runtime", "state", "tmp", "input"):
        path = artifacts / name
        path.mkdir(mode=0o700)
    environment.update(
        HOME=str(artifacts / "home"),
        XDG_CACHE_HOME=str(artifacts / "cache"),
        XDG_CONFIG_HOME=str(artifacts / "config"),
        XDG_DATA_HOME=str(artifacts / "data"),
        XDG_RUNTIME_DIR=str(artifacts / "runtime"),
        XDG_STATE_HOME=str(artifacts / "state"),
        TMPDIR=str(artifacts / "tmp"),
    )
    try:
        if args.timeout <= 0 or args.startup_timeout <= 0 or args.cleanup_timeout <= 0:
            raise ValueError("timeouts must be positive")
        emacs_program = resolve_program(args.emacs)
        xvfb_program = resolve_program(args.xvfb)
        required_programs = {}
        for required in args.require:
            required_programs[required] = resolve_program(required)
        reserved_environment = set(PRIVATE_ENVIRONMENT_KEYS) | PRIVATE_PATH_KEYS | {
            "PI_GRAPHICAL_SCRIPT",
        }
        if (not args.result_env.replace("_", "A").isalnum()
                or args.result_env in reserved_environment):
            raise ValueError(f"invalid result environment variable: {args.result_env!r}")
        source_script = args.script.resolve()
        if not source_script.is_file():
            raise ValueError(f"Lisp script is unavailable: {source_script}")
        load_paths = [path.resolve() for path in args.load_path]
        missing_load_paths = [str(path) for path in load_paths if not path.is_dir()]
        if missing_load_paths:
            raise ValueError(f"load path is unavailable: {', '.join(missing_load_paths)}")
        local_script = artifacts / "input" / source_script.name
        shutil.copyfile(source_script, local_script)
        result_path = artifacts / args.result_file
        if result_path.parent != artifacts or result_path.name in {"", ".", ".."}:
            raise ValueError("--result-file must be a single relative filename")
        additions = parse_environment(args.env)
        reserved = reserved_environment | {args.result_env}
        overridden = sorted(reserved.intersection(additions))
        if overridden:
            raise ValueError(f"private environment cannot be overridden: {', '.join(overridden)}")
        environment.update(additions)
        environment["PI_GRAPHICAL_SCRIPT"] = str(local_script)
        environment[args.result_env] = str(result_path)
        metadata.update(
            script_source=str(source_script),
            script_copy=str(local_script),
            result_file=str(result_path),
            prerequisites={
                "emacs": emacs_program,
                "xvfb": xvfb_program,
                "additional": required_programs,
            },
            private_environment={key: environment.get(key) for key in (
                "HOME", "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME",
                "XDG_RUNTIME_DIR", "XDG_STATE_HOME", "TMPDIR",
            )},
        )
        write_metadata(metadata_path, metadata)
        preflight = lisp_preflight(
            emacs_program, local_script, environment, args.startup_timeout,
            artifacts / "preflight.stdout.log", artifacts / "preflight.stderr.log",
        )
        metadata["preflight"] = preflight
        if preflight["timeout"]:
            raise RuntimeError("Lisp syntax preflight timed out")
        if preflight["exit_status"] != 0:
            raise RuntimeError(f"Lisp syntax preflight exited {preflight['exit_status']}")
        xvfb_command = [
            xvfb_program, "-displayfd", "1", "-screen", "0", args.screen,
            "-nolisten", "tcp",
        ]
        metadata["xvfb"] = {"command": xvfb_command, "started_at": timestamp()}
        xvfb = subprocess.Popen(
            xvfb_command,
            cwd=artifacts,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        xvfb_identity = process_identity(xvfb)
        metadata["xvfb"].update(xvfb_identity)
        assert xvfb.stderr is not None
        captures["xvfb_stderr"] = BoundedCapture(xvfb.stderr, artifacts / "xvfb.stderr.log")
        write_metadata(metadata_path, metadata)
        display, display_line = wait_for_display(
            xvfb, args.startup_timeout, artifacts / "xvfb.stdout.log"
        )
        assert xvfb.stdout is not None
        captures["xvfb_stdout"] = BoundedCapture(
            xvfb.stdout, artifacts / "xvfb.stdout.log", prefix=display_line
        )
        wait_for_x_socket(xvfb, display, args.startup_timeout)
        environment["DISPLAY"] = f":{display}"
        metadata["xvfb"].update(display=environment["DISPLAY"], ready_at=timestamp())
        emacs_command = [emacs_program, "-Q", "--display", environment["DISPLAY"]]
        for path in load_paths:
            emacs_command.extend(("-L", str(path)))
        emacs_command.extend(("--eval", load_form()))
        metadata["emacs"] = {
            "command": emacs_command,
            "command_shell": shlex.join(emacs_command),
            "started_at": timestamp(),
        }
        emacs = subprocess.Popen(
            emacs_command,
            cwd=artifacts,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        emacs_identity = process_identity(emacs)
        metadata["emacs"].update(emacs_identity)
        assert emacs.stdout is not None and emacs.stderr is not None
        captures["emacs_stdout"] = BoundedCapture(emacs.stdout, artifacts / "emacs.stdout.log")
        captures["emacs_stderr"] = BoundedCapture(emacs.stderr, artifacts / "emacs.stderr.log")
        write_metadata(metadata_path, metadata)
        try:
            status = emacs.wait(timeout=args.timeout)
        except subprocess.TimeoutExpired:
            metadata["emacs"]["timeout"] = True
            metadata["emacs"]["cleanup"] = stop_owned(emacs, emacs_identity, args.cleanup_timeout)
            if not metadata["emacs"]["cleanup"]["reaped"]:
                raise RuntimeError("timed-out Emacs could not be reaped")
            status = emacs.returncode
            failed = True
        metadata["emacs"].update(exit_status=status, finished_at=timestamp())
        if status != 0:
            failed = True
        if not result_path.is_file():
            metadata["result"] = {"present": False}
            failed = True
        else:
            size = result_path.stat().st_size
            with result_path.open("rb") as result_stream:
                content = result_stream.read(LOG_LIMIT)
            metadata["result"] = {
                "present": True,
                "bytes": size,
                "content": content.decode(errors="replace"),
                "bytes_discarded": max(0, size - len(content)),
                "success_marker": args.success_marker,
                "success_marker_matched": args.success_marker.encode() in content,
            }
            if not content or not metadata["result"]["success_marker_matched"]:
                failed = True
        if xvfb.poll() is not None:
            metadata["xvfb"]["unexpected_exit_status"] = xvfb.returncode
            failed = True
    except (Exception, KeyboardInterrupt) as error:
        failed = True
        metadata["runner_error"] = f"{type(error).__name__}: {error}"
    finally:
        if emacs is not None and emacs.poll() is None:
            assert emacs_identity is not None
            cleanup = stop_owned(emacs, emacs_identity, args.cleanup_timeout)
            metadata.setdefault("emacs", {})["cleanup"] = cleanup
            failed = True
        emacs_reaped = emacs is None or emacs.poll() is not None
        if not emacs_reaped:
            metadata["cleanup_error"] = "Xvfb left running because Emacs was not reaped"
            failed = True
        elif xvfb is not None:
            assert xvfb_identity is not None
            if xvfb.poll() is None:
                cleanup = stop_owned(xvfb, xvfb_identity, args.cleanup_timeout)
                metadata.setdefault("xvfb", {})["cleanup"] = cleanup
                if (not cleanup["reaped"] or "SIGKILL" in cleanup["signals"]
                        or cleanup.get("exit_status") != 0):
                    failed = True
            else:
                metadata.setdefault("xvfb", {})["cleanup"] = {
                    "reaped": True,
                    "exit_status": xvfb.returncode,
                    "already_exited": True,
                }
        for name, capture in captures.items():
            outcome = capture.finish()
            metadata.setdefault("logs", {})[name] = outcome
            if not outcome["drained"]:
                failed = True
                metadata["cleanup_error"] = f"{name} log pipe did not drain"
        metadata["finished_at"] = timestamp()
        metadata["success"] = not failed
        try:
            write_metadata(metadata_path, metadata)
        except OSError as error:
            metadata["metadata_error"] = f"{type(error).__name__}: {error}"
            metadata["success"] = False
    return (0 if metadata["success"] else 1), metadata, artifacts


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--script", required=True, type=Path)
    result.add_argument("--load-path", action="append", default=[], type=Path)
    result.add_argument("--env", action="append", default=[], metavar="NAME=VALUE")
    result.add_argument("--require", action="append", default=[], metavar="PROGRAM")
    result.add_argument("--result-env", default="PI_RESULT")
    result.add_argument("--result-file", default="result")
    result.add_argument("--success-marker", default=":passed t")
    result.add_argument("--emacs", default="emacs")
    result.add_argument("--xvfb", default="Xvfb")
    result.add_argument("--screen", default="1280x1024x24")
    result.add_argument("--startup-timeout", type=float, default=10.0)
    result.add_argument("--timeout", type=float, default=45.0)
    result.add_argument("--cleanup-timeout", type=float, default=5.0)
    result.add_argument("--artifacts", type=Path)
    result.add_argument("--artifacts-root", type=Path)
    result.add_argument("--keep-success", action="store_true")
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        status, metadata, artifacts = run(args)
    except Exception as error:
        print(f"private graphical runner setup failed: {type(error).__name__}: {error}", file=sys.stderr)
        return 2
    summary = {
        "success": metadata.get("success", False),
        "artifacts": str(artifacts),
        "retained": status != 0 or args.keep_success,
        "emacs_pid": metadata.get("emacs", {}).get("pid"),
        "emacs_exit_status": metadata.get("emacs", {}).get("exit_status"),
        "emacs_finished_at": metadata.get("emacs", {}).get("finished_at"),
        "xvfb_pid": metadata.get("xvfb", {}).get("pid"),
        "xvfb_exit_status": metadata.get("xvfb", {}).get("cleanup", {}).get("exit_status"),
        "xvfb_reaped": metadata.get("xvfb", {}).get("cleanup", {}).get("reaped"),
        "xvfb_cleanup_requested_at": metadata.get("xvfb", {}).get("cleanup", {}).get(
            "requested_at"
        ),
        "result": metadata.get("result", {}).get("content"),
        "runner_error": metadata.get("runner_error"),
    }
    print(json.dumps(summary, sort_keys=True))
    if status == 0 and not args.keep_success:
        shutil.rmtree(artifacts)
    return status


if __name__ == "__main__":
    raise SystemExit(main())
