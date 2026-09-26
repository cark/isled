#!/usr/bin/env bash
# Optional shell/jj adapter; the Python entry point needs only Git.
set -euo pipefail
script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ $# -eq 2 && $1 == --revision && $2 == @ ]]; then
    revision=$(jj --no-pager --color=never log -r @ --no-graph -T commit_id)
    exec python3 "$script_directory/check-coding-standards.py" --revision "$revision"
fi
exec python3 "$script_directory/check-coding-standards.py" "$@"
