#!/usr/bin/env bash
# memdb.sh — the CLI skills use to touch memory.db.
#
# Parameterized statements (? via sqlq.sh), busy timeout 5000, bail on error,
# foreign_keys on. One write retries only when the first attempt did not commit.
#
# Usage:
#   memdb.sh query <db> <sql> [arg...]
#   memdb.sh exec <db> <sql> [arg...]
#   memdb.sh script <db>                 # SQL on stdin
#   memdb.sh load-session <db> <agent>
#   memdb.sh write <db> <agent> <type> <content>
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SQLQ="$HERE/../lib/sqlq.sh"

usage() {
  echo "usage: memdb.sh query|exec|script|load-session|write <db> ..." >&2
  exit 64
}

[ $# -ge 1 ] || usage
cmd="$1"
shift

case "$cmd" in
  query|exec)
    [ $# -ge 2 ] || usage
    bash "$SQLQ" "$@"
    ;;
  script)
    [ $# -eq 1 ] || usage
    # Setter pragmas return no row. -bail stops the script on the first error.
    sqlite3 -bail -cmd ".timeout 5000" -cmd "PRAGMA foreign_keys=ON" "$1"
    ;;
  load-session)
    [ $# -eq 2 ] || usage
    # Tier 2, tier 1, and every non-archived tier-0 row. Distill marks consumed
    # tier-0 archived, so a later lesson and a pre-existing unarchived row both
    # stay visible after a digest exists (CDT-336).
    bash "$SQLQ" "$1" \
      "SELECT type, content FROM memories WHERE agent = ? AND archived = FALSE ORDER BY tier DESC, type ASC, updated_at DESC" \
      "$2"
    ;;
  write)
    [ $# -eq 4 ] || usage
    db="$1"
    agent="$2"
    mtype="$3"
    content="$4"
    insert_once() {
      bash "$SQLQ" "$db" \
        "INSERT INTO memories(agent, type, content) VALUES (?, ?, ?)" \
        "$agent" "$mtype" "$content"
    }
    if ! id=$(insert_once); then
      sleep 1
      id=$(insert_once)
    fi
    n=$(bash "$SQLQ" "$db" \
      "SELECT COUNT(*) FROM memories WHERE id = ? AND content = ?" \
      "$id" "$content")
    if [ "$n" != "1" ]; then
      echo "memdb: write read-back failed for id ${id:-}" >&2
      exit 1
    fi
    printf '%s\n' "$id"
    ;;
  *)
    usage
    ;;
esac
