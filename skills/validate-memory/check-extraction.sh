#!/usr/bin/env bash
# usage: check-extraction.sh <id> [id...] < extraction.json
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
exec python3 "$HERE/check-extraction.py" "$@"
