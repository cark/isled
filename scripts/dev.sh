#!/usr/bin/env bash
# Enter the pinned shell without importing the whole working directory.
set -euo pipefail

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
nix_source=$("$script_directory/nix-source.sh" --shell)
exec nix develop "path:$nix_source" "$@"
