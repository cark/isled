"""Explicit source and tool inputs for local release evidence."""
import hashlib
import json
import os
from pathlib import Path
import shutil


def digest(data):
    return hashlib.sha256(data).hexdigest()


def file_hash(path):
    return digest(Path(path).read_bytes())


def fingerprint(value):
    return digest(json.dumps(value, sort_keys=True).encode())


def files(root, patterns):
    result = {}
    for pattern in patterns:
        for path in sorted(root.glob(pattern)):
            if path.is_file() and "__pycache__" not in path.parts:
                result[str(path.relative_to(root))] = dict(sha256=file_hash(path), mode=path.stat().st_mode)
    return result


def tools(names):
    result = {}
    for name in names:
        path = shutil.which(name)
        if path is None:
            raise RuntimeError(f"Required tool is unavailable: {name}")
        path = Path(path).resolve()
        result[name] = {"path": str(path), "sha256": file_hash(path)}
    return result


def environment(prefixes):
    return {k: v for k, v in os.environ.items()
            if any(k.startswith(prefix) for prefix in prefixes)}


def inputs(root, check_nix=False):
    common = files(root, ["scripts/release_*.py"])
    rust = dict(source=files(root, ["src/**/*", "Cargo.toml", "Cargo.lock", "build.rs",
                                    ".cargo/**/*", "rust-toolchain*", "rustfmt.toml", "flake.nix", "flake.lock"]),
                tools=tools(["cargo", "rustc", "rustfmt", "cargo-clippy", "cc"]),
                env=environment(["CARGO", "RUST", "CC", "CFLAGS", "CPP", "AR", "LD", "LIBRARY_PATH", "PATH", "PKG_CONFIG", "NIX", "CXX", "CLIPPY", "LC_", "LANG", "TZ"]))
    cargo_home = Path(os.environ.get("CARGO_HOME", str(Path.home() / ".cargo")))
    rust["user_config"] = files(cargo_home, ["config", "config.toml"])
    emacs = dict(source=files(root, ["frontends/emacs/*.el", "frontends/emacs/Makefile", "frontends/emacs/test/**/*", "flake.nix", "flake.lock"]),
                 tools=tools([os.environ.get("ISLED_EMACS", "emacs"), "make"]),
                 env=environment(["ISLED_EMACS", "ISLED_PACKAGE_LINT_ROOT", "ISLED_MARKDOWN_MODE_ROOT", "ISLED_TRANSIENT_ROOT", "ISLED_CHECK_LOAD_PATH", "ISLED_CHECK_PACKAGE_DIR", "PATH", "NIX", "LC_", "LANG", "TZ"]))
    dependency_paths = [value for key in ("ISLED_CHECK_PACKAGE_DIR", "ISLED_CHECK_LOAD_PATH")
                        for value in os.environ.get(key, "").split(os.pathsep) if value]
    emacs["explicit_dependencies"] = {path: files(Path(path), ["**/*.el", "**/*.elc"])
                                      for path in dependency_paths}
    rust_tests = dict(rust=rust, tests=files(root, ["tests/**/*"]))
    frontend_tests = dict(emacs=emacs, tests=files(root, ["frontends/emacs/test/**/*"]), rust=rust_tests)
    groups = {"rust": rust_tests, "optimized": rust, "debug": rust_tests,
              "emacs-static": emacs, "emacs-tests": frontend_tests,
              "helpers": dict(source=files(root, ["scripts/**/*"]), tools=tools(["bash", "shellcheck", "python3", "make", "jj"]), env=environment(["PATH", "PYTHON", "SHELLCHECK", "MAKE"]))}
    if check_nix:
        groups["nix"] = dict(source=files(root, ["flake.nix", "flake.lock", "Cargo.toml", "Cargo.lock", "src/**/*", "tests/**/*", "scripts/nix-source.sh"]), tools=tools(["nix"]), env=environment(["NIX", "PATH"]))
    return {name: fingerprint(dict(common=common, inputs=value)) for name, value in groups.items()}
