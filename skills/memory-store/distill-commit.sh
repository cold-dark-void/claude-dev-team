#!/usr/bin/env bash
# One transaction for a distill group. Arguments match distill-commit.py.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
exec python3 "$HERE/distill-commit.py" "$@"
