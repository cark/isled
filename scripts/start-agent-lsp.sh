#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_root"
export AGENT_LSP_OUTPUT_FORMAT=json
exec scripts/dev.sh -c agent-lsp rust:rust-analyzer
