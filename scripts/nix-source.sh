#!/usr/bin/env bash
# Filter before flake evaluation: a path flake otherwise copies the full checkout.
set -euo pipefail

case "$#:${1-}" in
    0:) ISLED_NIX_SCOPE=package ;;
    1:--shell) ISLED_NIX_SCOPE=shell ;;
    *) printf 'usage: %s [--shell]\n' "$0" >&2; exit 2 ;;
esac
export ISLED_NIX_SCOPE

ISLED_NIX_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export ISLED_NIX_ROOT
exec nix eval --impure --raw --expr '
  let
    root = builtins.getEnv "ISLED_NIX_ROOT";
    shellOnly = builtins.getEnv "ISLED_NIX_SCOPE" == "shell";
    files = [ "flake.nix" "flake.lock" ]
      ++ (if shellOnly then [] else [ "Cargo.toml" "Cargo.lock" ]);
    trees = if shellOnly then [] else [ "src" "tests" ];
  in builtins.path {
    path = builtins.toPath root;
    name = "isled-source";
    filter = path: type:
      let
        relative = builtins.substring (builtins.stringLength root + 1) (-1) (toString path);
        top = builtins.head (builtins.split "/" relative);
      in builtins.elem top trees || builtins.elem relative files;
  }
'
