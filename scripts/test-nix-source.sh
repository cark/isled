#!/usr/bin/env bash
# Exercise the pre-flake boundary with a disposable checkout, never live sources.
set -euo pipefail

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture"/{scripts,src,tests,target,.jj,.issues,.direnv,.dogfood}
mkdir -p "$fixture"/skills/{isled/references,unrelated}
printf 'excluded skill\n' >"$fixture/skills/unrelated/SKILL.md"
cp "$script_directory/nix-source.sh" "$fixture/scripts/"
for file in flake.nix flake.lock Cargo.toml Cargo.lock LICENSE src/main.rs tests/basic.rs skills/isled/SKILL.md skills/isled/references/mutations.md; do
    printf 'fixture\n' >"$fixture/$file"
done
source_before=$("$fixture/scripts/nix-source.sh")
shell_before=$("$fixture/scripts/nix-source.sh" --shell)
for file in flake.nix flake.lock; do
    cmp "$fixture/$file" "$shell_before/$file"
done
for file in Cargo.toml Cargo.lock LICENSE src tests skills; do
    [[ ! -e $shell_before/$file ]]
done
for file in flake.nix flake.lock Cargo.toml Cargo.lock LICENSE src/main.rs tests/basic.rs skills/isled/SKILL.md skills/isled/references/mutations.md; do
    cmp "$fixture/$file" "$source_before/$file"
done
[[ ! -e $source_before/skills/unrelated ]]
for directory in target .jj .issues .direnv .dogfood; do
    printf 'local state\n' >"$fixture/$directory/ignored"
    [[ ! -e $source_before/$directory ]]
done
printf 'documentation\n' >"$fixture/README.md"
[[ $("$fixture/scripts/nix-source.sh") == "$source_before" ]]
printf 'new Rust input\n' >"$fixture/src/new.rs"
source_after=$("$fixture/scripts/nix-source.sh")
[[ $("$fixture/scripts/nix-source.sh" --shell) == "$shell_before" ]]
for file in Cargo.toml Cargo.lock LICENSE tests/basic.rs skills/isled/SKILL.md; do
    printf 'changed package input\n' >>"$fixture/$file"
    [[ $("$fixture/scripts/nix-source.sh" --shell) == "$shell_before" ]]
done
for file in flake.nix flake.lock; do
    printf 'changed tool input\n' >>"$fixture/$file"
    shell_after=$("$fixture/scripts/nix-source.sh" --shell)
    [[ $shell_after != "$shell_before" ]]
    shell_before=$shell_after
done
if "$fixture/scripts/nix-source.sh" --unknown >"$fixture/invalid-output" 2>&1; then
    printf 'unknown source mode unexpectedly accepted\n' >&2
    exit 1
fi
[[ $source_after != "$source_before" ]]
cmp "$fixture/src/new.rs" "$source_after/src/new.rs"
printf 'nix-source: required inputs preserved, local state ignored, new source detected\n'

# Evaluate only a tiny fixture to check the guard without copying the live tree.
cp "$script_directory/../flake.nix" "$fixture/flake.nix"
export ISLED_GUARD_FIXTURE=$fixture
if nix eval --impure --expr '
  (import (builtins.getEnv "ISLED_GUARD_FIXTURE" + "/flake.nix")).outputs {
    self = null; nixpkgs = null; flake-utils = null; agent-lsp-src = null;
  }
' >"$fixture/guard-output" 2>"$fixture/guard-error"; then
    printf 'unfiltered fixture unexpectedly passed the flake guard\n' >&2
    exit 1
fi
grep -q 'Unfiltered isled checkout: use scripts/dev.sh' "$fixture/guard-error"
printf 'nix-source: unfiltered fixture rejected with recovery instructions\n'
