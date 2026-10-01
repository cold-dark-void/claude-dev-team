#!/usr/bin/env bash
# Parameterized SQL. Arguments: <db> <sql> [arg ...]
# Placeholders are ?. Values stay in argv. sqlq.py binds them.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
exec python3 "$HERE/sqlq.py" "$@"
