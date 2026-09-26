#!/usr/bin/env python3
"""Start, inspect, and close isolated interactive isled previews."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path, PurePosixPath
import re
import secrets
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time


SCHEMA = 1
LOG_LIMIT = 1024 * 1024
PRIVATE_KEYS = ("DBUS_SESSION_BUS_ADDRESS", "EMACS_SOCKET_NAME", "GPG_AGENT_INFO",
                "INSIDE_EMACS", "SESSION_MANAGER", "SSH_AUTH_SOCK",
                "WAYLAND_DISPLAY")


def now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def resolve_program(value: str) -> str:
    path = Path(value).expanduser()
    if os.sep in value:
        path = path.resolve()
        if path.is_file() and os.access(path, os.X_OK):
            return str(path)
    else:
        found = shutil.which(value)
        if found:
            return found
    raise ValueError(f"executable is unavailable: {value}")


def run_checked(command: list[str], *, cwd: Path, timeout: float = 30,
                input_text: str | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(command, cwd=cwd, input=input_text, text=True,
                          capture_output=True, timeout=timeout, check=True)


def exact_revision(repo: Path, revision: str, jj: str) -> str:
    result = run_checked(
        [jj, "log", "-r", revision, "--no-graph", "-T", "commit_id ++ \"\\n\""],
        cwd=repo)
    lines = [line for line in result.stdout.splitlines() if line]
    if len(lines) != 1 or not re.fullmatch(r"[0-9a-f]{40,64}", lines[0]):
        raise ValueError(f"revision must resolve to one exact commit: {revision!r}")
    return lines[0]


def materialize_frontend(repo: Path, revision: str, destination: Path,
                         jj: str) -> list[str]:
    listing = run_checked(
        [jj, "file", "list", "-r", revision, "frontends/emacs"], cwd=repo)
    files = []
    for line in listing.stdout.splitlines():
        if not line.endswith(".el"):
            continue
        relative = PurePosixPath(line).relative_to("frontends/emacs")
        if len(relative.parts) == 1:
            files.append(line)
    if "frontends/emacs/isled.el" not in files:
        raise ValueError("candidate does not contain the Emacs frontend")
    destination.mkdir(mode=0o700, parents=True)
    for name in files:
        relative = PurePosixPath(name).relative_to("frontends/emacs")
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError(f"unsafe candidate path: {name}")
        target = destination.joinpath(*relative.parts)
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        content = subprocess.run([jj, "file", "show", "-r", revision, name],
                                 cwd=repo, capture_output=True, check=True).stdout
        target.write_bytes(content)
    return files


def process_identity(pid: int) -> dict:
    result = {"pid": pid, "proc_start_time": None}
    try:
        result["proc_start_time"] = Path(f"/proc/{pid}/stat").read_text().split()[21]
    except (FileNotFoundError, PermissionError, ProcessLookupError):
        pass
    return result


def identity_live(identity: dict) -> bool:
    pid, expected = identity.get("pid"), identity.get("proc_start_time")
    if not isinstance(pid, int) or not expected:
        return False
    try:
        return Path(f"/proc/{pid}/stat").read_text().split()[21] == expected
    except (FileNotFoundError, PermissionError, ProcessLookupError):
        return False


def preview_live(manifest: dict) -> bool:
    """Return whether either recorded preview process still has its identity."""
    return (identity_live(manifest.get("supervisor_process", {}))
            or identity_live(manifest.get("emacs_process", {})))


def kill_owned_emacs(identity: dict, requested_signal: signal.Signals) -> bool:
    if not identity_live(identity):
        return False
    try:
        os.killpg(identity["pid"], requested_signal)
        return True
    except ProcessLookupError:
        return False


def write_json(path: Path, value: dict) -> None:
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def bounded_capture(stream, limit: int) -> bytearray:
    captured = bytearray()
    while chunk := stream.read(65536):
        captured.extend(chunk)
        if len(captured) > limit:
            del captured[:len(captured) - limit]
    return captured


def supervise(args: argparse.Namespace) -> int:
    child = subprocess.Popen(args.command, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, start_new_session=True)
    write_json(args.pid_file, process_identity(child.pid))

    def terminate(_signal, _frame) -> None:
        if child.poll() is None:
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass

    signal.signal(signal.SIGTERM, terminate)
    assert child.stdout and child.stderr
    stdout = bytearray()
    stderr = bytearray()

    def capture(stream, destination) -> None:
        destination.extend(bounded_capture(stream, LOG_LIMIT))

    threads = [threading.Thread(target=capture, args=(child.stdout, stdout)),
               threading.Thread(target=capture, args=(child.stderr, stderr))]
    for thread in threads:
        thread.start()
    returncode = child.wait()
    for thread in threads:
        thread.join()
    args.stdout_log.write_bytes(stdout)
    args.stderr_log.write_bytes(stderr)
    return returncode


def default_state_root() -> Path:
    base = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state"))
    return base / "isled" / "previews"


def private_environment(run: Path) -> dict[str, str]:
    environment = os.environ.copy()
    for key in PRIVATE_KEYS:
        environment.pop(key, None)
    paths = {
        "HOME": run / "home", "TMPDIR": run / "tmp",
        "XDG_CACHE_HOME": run / "cache", "XDG_CONFIG_HOME": run / "config",
        "XDG_DATA_HOME": run / "data", "XDG_RUNTIME_DIR": run / "runtime",
        "XDG_STATE_HOME": run / "state",
    }
    for path in paths.values():
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
    environment.update({key: str(path) for key, path in paths.items()})
    return environment


def create_ledger(program: str, ledger: Path, manifest: dict, cwd: Path) -> None:
    ledger.mkdir(mode=0o700)
    commands = [[program, "--root", str(ledger), "init"]]
    run_checked(commands[0], cwd=cwd)
    examples = [
        ("Preview typography and spacing", "feature",
         "A short paragraph with **bold**, *emphasis*, and `code`.\n\n"
         "### Details\n\n- First item\n- Second item\n"),
        ("Inspect a longer issue body", "bug",
         "This longer record makes folding, wrapping, and scrolling visible.\n\n"
         "```rust\nfn preview() { println!(\"isolated\"); }\n```\n\n"
         "A final paragraph keeps the body representative.\n"),
        ("Compare closed presentation", "chore", "Closed example."),
    ]
    for title, kind, body in examples:
        command = [program, "--root", str(ledger), "add", title,
                   "--kind", kind, "--stdin"]
        run_checked(command, cwd=cwd, input_text=body)
        commands.append(command)
    for command in (
            [program, "--root", str(ledger), "evidence", "add", "0003",
             "Fixture resolution evidence."],
            [program, "--root", str(ledger), "close", "0003",
             "--outcome", "Closed for fixture presentation."],
    ):
        run_checked(command, cwd=cwd)
        commands.append(command)
    manifest["ledger_commands"] = commands


def bootstrap_text() -> str:
    return r''';;; isolated isled preview bootstrap -*- lexical-binding: t; -*-
(require 'json)
(defvar isled-preview-view-buffer nil)
(defvar isled-preview-original-initializer nil)
(defvar isled-preview-readiness-timer nil)
(defun isled-preview-fail (failure)
  (when (timerp isled-preview-readiness-timer)
    (cancel-timer isled-preview-readiness-timer))
  (with-temp-file (getenv "ISLED_PREVIEW_READY")
    (insert (json-encode `((ready . :json-false)
                           (error . ,(error-message-string failure))))))
  (kill-emacs 70))
(defun isled-preview-loaded-files ()
  (delq nil
        (mapcar
         (lambda (entry)
           (when (seq-some
                  (lambda (item)
                    (and (consp item) (eq (car item) 'provide)
                         (string-prefix-p
                          "isled" (symbol-name (cdr item)))))
                  (cdr entry))
             (car entry)))
         load-history)))
(defun isled-preview-write-ready ()
  (condition-case failure
      (with-current-buffer isled-preview-view-buffer
        (when (timerp isled-preview-readiness-timer)
          (cancel-timer isled-preview-readiness-timer)
          (setq isled-preview-readiness-timer nil))
        (when isled--auto-revert-error
          (error "Frontend refresh failed: %s" isled--auto-revert-error))
        (let ((issue-count (and isled-data-view
                                (length (isled-snapshot-issues
                                         isled-data-view)))))
        (unless (and (derived-mode-p 'isled-mode)
                     isled-data-view
                     (equal issue-count 2))
          (error "Frontend view was not usable after refresh: %S"
                 (list :issues issue-count :rendered isled--header-count
                       :visible (and (get-buffer-window (current-buffer) t) t))))
        (let* ((source (file-truename (getenv "ISLED_PREVIEW_SOURCE")))
               (files (isled-preview-loaded-files))
               (wrong (seq-remove
                       (lambda (file) (and file
                                     (string-prefix-p source (file-truename file))))
                       files))
               (dependencies
                (mapcar (lambda (library)
                          (cons library
                                (if (featurep library)
                                    (or (locate-library (symbol-name library))
                                        :json-false)
                                  :json-false)))
                        '(markdown-mode transient))))
          (when (and (equal (getenv "ISLED_PREVIEW_PROFILE") "personal")
                     (not (and (bound-and-true-p isled-preview-personal-early-init-complete)
                               (bound-and-true-p isled-preview-personal-init-complete))))
            (error "Personal init did not complete (early=%S init=%S)"
                   (or (bound-and-true-p isled-preview-personal-early-init-complete)
                       (bound-and-true-p isled-preview-personal-early-init-error))
                   (or (bound-and-true-p isled-preview-personal-init-complete)
                       (bound-and-true-p isled-preview-personal-init-error))))
          (when wrong (error "Frontend did not load from candidate: %S" wrong))
          (redisplay t)
          (with-temp-file (getenv "ISLED_PREVIEW_READY")
            (insert (json-encode
                     `((ready . t) (candidate . ,(getenv "ISLED_PREVIEW_CANDIDATE"))
                       (profile . ,(getenv "ISLED_PREVIEW_PROFILE"))
                       (user_init_file . ,(or user-init-file :json-false))
                       (user_emacs_directory . ,user-emacs-directory)
                       (dependencies . ,dependencies)
                       (initial_view . ((issue_count . ,issue-count)
                                        (rendered_issue_count . ,isled--header-count)
                                        (refresh_completed . t)))
                       (loaded_files . ,(vconcat files)))))))))
    (error (isled-preview-fail failure))))
(defun isled-preview-watch-errors ()
  (condition-case failure
      (with-current-buffer isled-preview-view-buffer
        (when isled--auto-revert-error
          (error "Frontend view failed: %s" isled--auto-revert-error)))
    (error (isled-preview-fail failure))))
(defun isled-preview-after-initial-view ()
  (condition-case failure
      (progn
        (when isled-preview-original-initializer
          (funcall isled-preview-original-initializer))
        (isled-loading-request 'refresh nil #'isled-preview-write-ready))
    (error (isled-preview-fail failure))))
(condition-case failure
    (progn
(setq server-socket-dir (getenv "ISLED_PREVIEW_SOCKET_DIR")
      server-name (getenv "ISLED_PREVIEW_ID")
      isled-program (getenv "ISLED_PREVIEW_PROGRAM")
      frame-title-format (getenv "ISLED_PREVIEW_TITLE"))
(modify-frame-parameters nil `((name . ,(getenv "ISLED_PREVIEW_TITLE"))
                               (title . ,(getenv "ISLED_PREVIEW_TITLE"))))
(require 'server)
(server-start)
(require 'isled)
(setq isled-preview-view-buffer (isled (getenv "ISLED_PREVIEW_LEDGER")))
(with-current-buffer isled-preview-view-buffer
  (setq isled-preview-original-initializer isled-loading-initializer
        isled-loading-initializer #'isled-preview-after-initial-view))
(setq isled-preview-readiness-timer
      (run-at-time 0.05 0.05 #'isled-preview-watch-errors))
)
  (error
   (isled-preview-fail failure)))
'''


def personal_init_text() -> tuple[str, str]:
    """Return wrapper files that make personal init completion observable."""
    early = r'''(condition-case failure
    (let* ((user-emacs-directory
            (file-name-as-directory (getenv "ISLED_PREVIEW_CONFIG_DIR")))
           (file (expand-file-name "early-init" user-emacs-directory)))
      (when (or (file-exists-p (concat file ".el"))
                (file-exists-p (concat file ".elc")))
        (load file nil nil))
      (add-to-list 'load-path (getenv "ISLED_PREVIEW_SOURCE"))
      (require 'isled)
      (setq isled-preview-personal-early-init-complete t))
  (error (setq isled-preview-personal-early-init-error
               (error-message-string failure))))
'''
    init = r'''(setq user-emacs-directory
      (file-name-as-directory (getenv "ISLED_PREVIEW_CONFIG_DIR")))
(condition-case failure
    (progn
      (load (expand-file-name "init" user-emacs-directory) nil nil)
      (setq load-path
            (cons (getenv "ISLED_PREVIEW_SOURCE")
                  (delete (getenv "ISLED_PREVIEW_SOURCE") load-path)))
      (setq user-init-file
            (or (and (file-exists-p (expand-file-name "init.el" user-emacs-directory))
                     (expand-file-name "init.el" user-emacs-directory))
                (expand-file-name "init.elc" user-emacs-directory))
            isled-preview-personal-init-complete t))
  (error (setq isled-preview-personal-init-error
               (error-message-string failure))))
'''
    return early, init


def sandbox_command(bwrap: str, run: Path, socket_dir: Path,
                    config: Path | None, command: list[str]) -> list[str]:
    wrapped = [bwrap, "--ro-bind", "/", "/",
               "--dev-bind", "/dev/null", "/dev/null",
               "--bind", str(run), str(run),
               "--bind", str(socket_dir), str(socket_dir),
               "--unshare-net", "--unshare-pid", "--proc", "/proc"]
    if config:
        destination = run / "home" / ".emacs.d"
        destination.mkdir(mode=0o700)
        wrapped.extend(("--ro-bind", str(config), str(destination)))
        for name in ("auto-save-list", "eln-cache", "etc", "var"):
            if not (config / name).is_dir():
                continue
            overlay = run / "emacs-state" / name
            overlay.mkdir(mode=0o700, parents=True, exist_ok=True)
            target = destination / name
            wrapped.extend(("--bind", str(overlay), str(target)))
    return wrapped + command


def start(args: argparse.Namespace) -> int:
    repo = args.repo.resolve()
    state_root = args.state_root.expanduser().resolve()
    state_root.mkdir(mode=0o700, parents=True, exist_ok=True)
    state_root.chmod(0o700)
    jj, emacs = resolve_program(args.jj), resolve_program(args.emacs)
    client_choice = args.emacsclient or str(Path(emacs).with_name("emacsclient"))
    client, program, bwrap = (resolve_program(client_choice),
                              resolve_program(args.isled),
                              resolve_program(args.bwrap))
    candidate = exact_revision(repo, args.candidate, jj)
    preview_id = f"{candidate[:10]}-{dt.datetime.now().strftime('%Y%m%dT%H%M%S')}-{secrets.token_hex(2)}"
    run = state_root / preview_id
    run.mkdir(mode=0o700)
    manifest_path = run / "manifest.json"
    manifest = {"schema": SCHEMA, "id": preview_id, "status": "starting",
                "started_at": now(), "candidate_input": args.candidate,
                "candidate": candidate, "profile": args.profile,
                "run_directory": str(run), "repo": str(repo)}
    write_json(manifest_path, manifest)
    process = None
    socket_dir = None
    identity = None
    try:
        source = run / "source" / "frontends" / "emacs"
        files = materialize_frontend(repo, candidate, source, jj)
        environment = private_environment(run)
        ledger = run / "ledger"
        create_ledger(program, ledger, manifest, run)
        bootstrap = run / "bootstrap.el"
        bootstrap.write_text(bootstrap_text())
        socket_dir = Path(tempfile.mkdtemp(prefix="isled-preview-socket-", dir="/tmp"))
        ready = run / "ready.json"
        title = f"isled preview {candidate[:10]} ({args.profile})"
        environment.update(
            ISLED_PREVIEW_ID=preview_id, ISLED_PREVIEW_CANDIDATE=candidate,
            ISLED_PREVIEW_PROFILE=args.profile, ISLED_PREVIEW_SOURCE=str(source) + os.sep,
            ISLED_PREVIEW_LEDGER=str(ledger), ISLED_PREVIEW_PROGRAM=program,
            ISLED_PREVIEW_SOCKET_DIR=str(socket_dir), ISLED_PREVIEW_READY=str(ready),
            ISLED_PREVIEW_TITLE=title,
        )
        config = None
        command = [emacs, "-L", str(source), "--no-desktop", "--name", title]
        if args.profile == "vanilla":
            command.insert(1, "-Q")
        else:
            if not args.config_dir:
                raise ValueError("--config-dir is required for the personal profile")
            config = args.config_dir.expanduser().resolve()
            if not (config / "init.el").is_file() and not (config / "init.elc").is_file():
                raise ValueError(f"configuration has no init.el or init.elc: {config}")
            config_destination = run / "home" / ".emacs.d"
            wrapper = run / "personal-init"
            wrapper.mkdir(mode=0o700)
            early, init = personal_init_text()
            (wrapper / "early-init.el").write_text(early)
            (wrapper / "init.el").write_text(init)
            environment["ISLED_PREVIEW_CONFIG_DIR"] = str(config_destination)
            command.append(f"--init-directory={wrapper}")
        command.extend(("--load", str(bootstrap)))
        full_command = sandbox_command(bwrap, run, socket_dir, config, command)
        child_pid_file = run / "emacs-process.json"
        supervisor_command = [sys.executable, str(Path(__file__).resolve()),
                              "_supervise", "--pid-file", str(child_pid_file),
                              "--stdout-log", str(run / "emacs.stdout.log"),
                              "--stderr-log", str(run / "emacs.stderr.log"),
                              *full_command]
        process = subprocess.Popen(supervisor_command, cwd=run, env=environment,
                                   stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL,
                                   start_new_session=True)
        identity = process_identity(process.pid)
        manifest.update(source_files=len(files), title=title,
                        programs={"jj": jj, "emacs": emacs,
                                  "emacsclient": client, "isled": program,
                                  "bwrap": bwrap},
                        supervisor_process=identity,
                        command=full_command, command_shell=shlex.join(full_command),
                        supervisor_command=supervisor_command,
                        log_limit_bytes=LOG_LIMIT,
                        logs={"stdout": str(run / "emacs.stdout.log"),
                              "stderr": str(run / "emacs.stderr.log")},
                        socket=str(socket_dir / preview_id), ready_file=str(ready),
                        socket_directory=str(socket_dir),
                        config_input=str(config) if config else None,
                        config_mount=str(config_destination) if config else None)
        write_json(manifest_path, manifest)
        deadline = time.monotonic() + args.startup_timeout
        while time.monotonic() < deadline:
            if ready.is_file():
                readiness = json.loads(ready.read_text())
                if readiness.get("ready") is False:
                    raise RuntimeError("Emacs readiness failed: "
                                       + str(readiness.get("error", "unknown error")))
                if ((socket_dir / preview_id).exists()
                        and readiness.get("ready") is True
                        and readiness.get("candidate") == candidate
                        and readiness.get("profile") == args.profile):
                    if not child_pid_file.is_file():
                        time.sleep(0.05)
                        continue
                    init_file = readiness.get("user_init_file")
                    if args.profile == "personal":
                        expected_config = run / "home" / ".emacs.d"
                        if (not init_file or
                                not Path(init_file).is_relative_to(expected_config)):
                            raise RuntimeError("personal configuration was not loaded")
                    elif init_file is not False:
                        raise RuntimeError("vanilla preview unexpectedly loaded an init file")
                    dependencies = readiness.get("dependencies", {})
                    missing = [name for name in ("markdown-mode", "transient")
                               if not dependencies.get(name)]
                    if missing:
                        raise RuntimeError("missing configured dependencies: "
                                           + ", ".join(missing))
                    emacs_process = json.loads(child_pid_file.read_text())
                    manifest.update(status="ready", ready_at=now(), readiness=readiness,
                                    emacs_process=emacs_process)
                    write_json(manifest_path, manifest)
                    print(json.dumps({"id": preview_id, "candidate": candidate,
                                      "pid": emacs_process["pid"],
                                      "supervisor_pid": process.pid, "title": title,
                                      "manifest": str(manifest_path)}, sort_keys=True))
                    return 0
            if process.poll() is not None:
                raise RuntimeError(f"Emacs exited before readiness: {process.returncode}")
            time.sleep(0.05)
        raise RuntimeError(f"preview was not ready within {args.startup_timeout:g} seconds")
    except Exception as error:
        manifest.update(status="failed", failed_at=now(),
                        error=f"{type(error).__name__}: {error}")
        if process and identity and identity_live(identity):
            process.send_signal(signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                if child_pid_file.is_file():
                    kill_owned_emacs(json.loads(child_pid_file.read_text()),
                                     signal.SIGKILL)
                process.kill(); process.wait(timeout=5)
        if socket_dir:
            shutil.rmtree(socket_dir, ignore_errors=True)
        write_json(manifest_path, manifest)
        print(f"preview start failed; evidence: {manifest_path}: {error}", file=sys.stderr)
        return 1


def manifests(root: Path) -> list[tuple[Path, dict]]:
    result = []
    if root.is_dir():
        for path in sorted(root.glob("*/manifest.json")):
            try: result.append((path, json.loads(path.read_text())))
            except (OSError, json.JSONDecodeError): pass
    return result


def list_previews(args: argparse.Namespace) -> int:
    for path, manifest in manifests(args.state_root.expanduser().resolve()):
        live = preview_live(manifest)
        if args.all or live:
            print(json.dumps({"id": manifest.get("id"), "candidate": manifest.get("candidate"),
                              "profile": manifest.get("profile"), "status": manifest.get("status"),
                              "live": live,
                              "pid": manifest.get("emacs_process", {}).get("pid"),
                              "supervisor_pid": manifest.get("supervisor_process", {}).get("pid"),
                              "manifest": str(path)}, sort_keys=True))
    return 0


def valid_manifest_path(path: Path, manifest: dict) -> bool:
    """Return whether MANIFEST owns PATH's containing preview directory."""
    try:
        return (manifest.get("schema") == SCHEMA
                and manifest.get("id") == path.parent.name
                and Path(manifest.get("run_directory", "")).resolve()
                == path.parent.resolve())
    except (OSError, RuntimeError):
        return False


def cleanup_preview(path: Path, manifest: dict) -> bool:
    """Remove disposable state named by one validated stopped preview."""
    if not valid_manifest_path(path, manifest):
        return False
    socket = None
    if socket_directory := manifest.get("socket_directory"):
        socket = Path(socket_directory)
        if (socket.parent != Path("/tmp")
                or not socket.name.startswith("isled-preview-socket-")):
            return False
    for name in ("cache", "config", "data", "emacs-state", "home", "ledger",
                 "personal-init", "runtime", "source", "state", "tmp"):
        shutil.rmtree(path.parent / name, ignore_errors=True)
    if socket:
        shutil.rmtree(socket, ignore_errors=True)
    return True


def close_one(path: Path, manifest: dict, timeout: float) -> bool:
    if not valid_manifest_path(path, manifest):
        return False
    supervisor = manifest.get("supervisor_process", {})
    emacs = manifest.get("emacs_process", {})
    client = manifest["programs"]["emacsclient"]
    command = [client, "--socket-name", manifest["socket"], "--eval", "(kill-emacs 0)"]
    manifest["close_command"] = command
    if identity_live(emacs):
        try:
            result = subprocess.run(command, capture_output=True, text=True,
                                    timeout=timeout)
            manifest["client_exit_status"] = result.returncode
            if result.stderr:
                manifest["client_error"] = result.stderr[-4096:]
        except (OSError, subprocess.TimeoutExpired) as error:
            manifest["client_error"] = f"{type(error).__name__}: {error}"
    deadline = time.monotonic() + timeout
    while preview_live(manifest) and time.monotonic() < deadline:
        time.sleep(0.05)
    if identity_live(supervisor):
        try:
            os.kill(supervisor["pid"], signal.SIGTERM)
        except ProcessLookupError:
            pass
        deadline = time.monotonic() + timeout
        while preview_live(manifest) and time.monotonic() < deadline:
            time.sleep(0.05)
    if identity_live(emacs):
        kill_owned_emacs(emacs, signal.SIGKILL)
        deadline = time.monotonic() + timeout
        while preview_live(manifest) and time.monotonic() < deadline:
            time.sleep(0.05)
    if preview_live(manifest):
        manifest.update(status="close-failed", close_error="owned process did not exit")
        write_json(path, manifest); return False
    if not cleanup_preview(path, manifest):
        manifest.update(status="close-failed", close_error="invalid owned cleanup path")
        write_json(path, manifest); return False
    manifest.update(status="closed", closed_at=now())
    write_json(path, manifest)
    return True


def close_previews(args: argparse.Namespace) -> int:
    selected = [(path, value) for path, value in manifests(args.state_root.expanduser().resolve())
                if ((args.all and (preview_live(value) or value.get("status") == "ready"))
                    or (not args.all and value.get("id") == args.id))]
    if not selected:
        if args.all:
            return 0
        print("no matching preview", file=sys.stderr); return 1
    results = [close_one(path, value, args.timeout) for path, value in selected]
    return 0 if all(results) else 1


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--state-root", type=Path, default=default_state_root())
    sub = result.add_subparsers(dest="action", required=True)
    start_parser = sub.add_parser("start")
    start_parser.add_argument("--candidate", required=True)
    start_parser.add_argument("--profile", choices=("vanilla", "personal"), default="vanilla")
    start_parser.add_argument("--config-dir", type=Path)
    start_parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parent.parent)
    start_parser.add_argument("--jj", default="jj"); start_parser.add_argument("--emacs", default="emacs")
    start_parser.add_argument("--emacsclient")
    start_parser.add_argument("--isled", default="isled")
    start_parser.add_argument("--bwrap", default="bwrap")
    start_parser.add_argument("--startup-timeout", type=float, default=30)
    start_parser.set_defaults(function=start)
    list_parser = sub.add_parser("list"); list_parser.add_argument("--all", action="store_true")
    list_parser.set_defaults(function=list_previews)
    close_parser = sub.add_parser("close"); close_parser.add_argument("id", nargs="?")
    close_parser.add_argument("--all", action="store_true"); close_parser.add_argument("--timeout", type=float, default=10)
    close_parser.set_defaults(function=close_previews)
    supervisor = sub.add_parser("_supervise", help=argparse.SUPPRESS)
    supervisor.add_argument("--pid-file", type=Path, required=True)
    supervisor.add_argument("--stdout-log", type=Path, required=True)
    supervisor.add_argument("--stderr-log", type=Path, required=True)
    supervisor.add_argument("command", nargs=argparse.REMAINDER)
    supervisor.set_defaults(function=supervise)
    return result


def main() -> int:
    args = parser().parse_args()
    if args.action == "close" and not args.all and not args.id:
        parser().error("close requires ID or --all")
    return args.function(args)


if __name__ == "__main__":
    raise SystemExit(main())
