#!/usr/bin/env python3
"""Exercise shell caching and package input tracking in a disposable checkout."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

REPOSITORY = Path(__file__).resolve().parent.parent


def main():
    with tempfile.TemporaryDirectory(prefix="isled-dev-env-") as temporary:
        fixture = Path(temporary)
        for name in (".envrc", "flake.nix", "flake.lock", "Cargo.toml", "Cargo.lock", "LICENSE",
                     "scripts/nix-source.sh", "scripts/dev.sh"):
            target = fixture / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPOSITORY / name, target)
        shutil.copytree(REPOSITORY / 'skills/isled', fixture / 'skills/isled')
        for name in ("src", "tests", "target", ".issues", ".jj"):
            (fixture / name).mkdir()
        (fixture / "src/lib.rs").write_text("// package input\n")
        (fixture / "tests/input.rs").write_text("// test input\n")
        # Fresh direnv invocations, with authorization/cache state confined here.
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith(("DIRENV_", "NIX_DIRENV_"))}
        # NixOS selects the installed nix-direnv integration through this
        # configuration pointer. Drop activation state, not configuration.
        for key in ("DIRENV_CONFIG", "DIRENV_CONFIG_HOME"):
            if key in os.environ:
                environment[key] = os.environ[key]
        environment["XDG_DATA_HOME"] = str(fixture / "xdg-data")

        def run(*arguments):
            result = subprocess.run(arguments, cwd=fixture, env=environment,
                                    capture_output=True, text=True, timeout=180)
            if result.returncode:
                raise AssertionError(f"{arguments}: {result.stderr}")
            return result

        def source(*arguments):
            return run("scripts/nix-source.sh", *arguments).stdout.strip()

        system = run("nix", "eval", "--impure", "--raw", "--expr",
                     "builtins.currentSystem").stdout

        def derivation(path, output):
            return run("nix", "eval", "--raw",
                       f"path:{path}#{output}.{system}.default.drvPath").stdout

        def activate():
            result = run("direnv", "exec", ".", "bash", "-c",
                         'test -z "${NIX_DIRENV_DID_FALLBACK:-}" && '
                         'command -v cargo rust-analyzer agent-lsp bwrap && '
                         'printf "%s\\n" "${ISLED_SHELL_PROBE:-original}"')
            return result

        def profiles():
            return {path.name: path.read_bytes()
                    for path in (fixture / ".direnv").glob("flake-profile-*.rc")}

        shell = source("--shell")
        package = source()
        shell_derivation = derivation(shell, "devShells")
        package_derivation = derivation(package, "packages")
        run("direnv", "allow", ".")
        original = activate().stdout
        cached = profiles()
        assert cached, "direnv did not create a shell cache"
        for name in ("src/lib.rs", "src/new.rs", "tests/input.rs", "Cargo.toml", "Cargo.lock", "LICENSE", "skills/isled/SKILL.md"):
            with (fixture / name).open("a") as output:
                output.write("\n# changed\n" if name.startswith("Cargo") else "// changed\n")
            assert source("--shell") == shell, name
            changed_package = source()
            assert changed_package != package, name
            package = changed_package
            result = activate()
            assert result.stdout == original, name
            assert "Using cached dev shell" in result.stderr, result.stderr
            assert "Renewed cache" not in result.stderr, result.stderr
            assert profiles() == cached, name
        assert derivation(source("--shell"), "devShells") == shell_derivation
        assert derivation(source(), "packages") != package_derivation
        for name in ("target/output", ".issues/private", ".jj/state", "README.md"):
            (fixture / name).write_text("ignored local content\n")
        assert source("--shell") == shell
        assert activate().stdout == original
        assert profiles() == cached
        wrapper = run("scripts/dev.sh", "-c", "bash", "-c",
                      "command -v cargo rust-analyzer agent-lsp bwrap")
        assert wrapper.stdout.splitlines() == original.splitlines()[:4]
        print("PASS: source/Cargo/test/local-state edits reuse the same shell and direnv cache; package derivation changes", flush=True)

        flake = fixture / "flake.nix"
        flake.write_text(flake.read_text().replace("devShells.default = pkgs.mkShell {",
                         'devShells.default = pkgs.mkShell {\n          ISLED_SHELL_PROBE = "changed";'))
        changed_shell = source("--shell")
        assert changed_shell != shell
        assert derivation(changed_shell, "devShells") != shell_derivation
        result = activate()
        assert result.stdout.splitlines()[-1] == "changed"
        assert profiles() != cached
        assert "Renewed cache" in result.stderr, result.stderr
        cached = profiles()
        lock = fixture / "flake.lock"
        lock.write_text(json.dumps(json.loads(lock.read_text()), indent=4) + "\n")
        assert source("--shell") != changed_shell
        result = activate()
        assert result.stdout.splitlines()[-1] == "changed"
        assert profiles() != cached
        assert "Renewed cache" in result.stderr, result.stderr
        # Touching the helper must also invalidate the shell cache, without
        # changing tool inputs or accidentally freezing automatic refresh.
        helper = fixture / "scripts/nix-source.sh"
        helper.write_text(helper.read_text() + "\n# fixture watch probe\n")
        result = activate()
        assert "Renewed cache" in result.stderr, result.stderr
        working_helper = helper.read_text()
        helper.write_text("#!/usr/bin/env bash\nexit 42\n")
        # direnv exec can still run its command after .envrc fails. Verify
        # that the requested environment was not imported, rather than assuming
        # the exit status of an unconditional `true` reports activation failure.
        failed = subprocess.run(("direnv", "exec", ".", "bash", "-c",
                                 'test "${ISLED_SHELL_PROBE:-}" = changed'), cwd=fixture,
                                env=environment, capture_output=True, text=True, timeout=30)
        assert failed.returncode != 0, failed
        assert "using flake" not in failed.stderr, failed.stderr
        assert "Could not prepare the filtered development-shell source" in failed.stderr
        helper.write_text(working_helper)
        assert activate().stdout.splitlines()[-1] == "changed"
        print("PASS: flake, lock and helper changes refresh automatically; no fallback; filtering failures stop before flake evaluation", flush=True)


if __name__ == "__main__":
    main()
