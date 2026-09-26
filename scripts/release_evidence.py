"""Successful stage receipts, immutable build copies and per-stage timing."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

from release_inputs import file_hash


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


class Evidence:
    def __init__(self, root, store, keys):
        self.root, self.store, self.keys = root, store, keys
        self.results = {}
        self.pending = []

    def stage(self, name, commands, artifact=None):
        key = self.keys[name]
        receipt = self.store / "evidence" / name / f"{key}.json"
        retained = self.store / "artifacts" / name / key / "isled"
        start = time.monotonic()
        try:
            cached = json.loads(receipt.read_text())
            valid = cached["key"] == key and cached["success"] is True
            if artifact:
                valid = valid and os.access(retained, os.X_OK) and file_hash(retained) == cached["artifact_sha256"]
        except (OSError, ValueError, KeyError, TypeError):
            valid = False
        if valid:
            result = dict(cached, reused=True, seconds=time.monotonic() - start)
            print(f"reuse {name} ({result['seconds']:.3f}s)", flush=True)
        else:
            print(f"run {name}", flush=True)
            log = self.store / "logs" / f"{name}-{key}.log"
            log.parent.mkdir(parents=True, exist_ok=True)
            result = dict(key=key, success=False, reused=False, log=str(log), commands=[])
            with log.open("w") as stream:
                for command in commands:
                    then = time.monotonic()
                    process = subprocess.run(command, cwd=self.root, stdout=stream, stderr=subprocess.STDOUT)
                    result["commands"].append(dict(command=command, seconds=time.monotonic() - then, exit_code=process.returncode))
                    if process.returncode:
                        result["seconds"] = time.monotonic() - start
                        self.results[name] = result
                        print(f"FAILED {name}: {log}", flush=True)
                        raise RuntimeError(f"{name} failed (exit {process.returncode}); see {log}")
            if artifact:
                retained.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(cargo_executable(log), retained)
                result["artifact_sha256"] = file_hash(retained)
            result.update(success=True, seconds=time.monotonic() - start)
            self.pending.append((receipt, result))
            print(f"passed {name} ({result['seconds']:.3f}s)", flush=True)
        self.results[name] = result
        return retained if artifact else None

    def commit(self):
        for path, result in self.pending:
            write_json(path, result)


def cargo_executable(log):
    """Select Cargo's actual non-test binary, including configured target paths."""
    executable = None
    for line in log.read_text().splitlines():
        try:
            message = json.loads(line)
        except ValueError:
            continue
        if (message.get("reason") == "compiler-artifact"
                and message.get("target", {}).get("name") == "isled"
                and "bin" in message["target"].get("kind", [])
                and not message.get("profile", {}).get("test")
                and message.get("executable")):
            executable = Path(message["executable"])
    if executable is None or not os.access(executable, os.X_OK):
        raise RuntimeError(f"Cargo did not report an executable isled artifact; see {log}")
    return executable
