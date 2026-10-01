#!/usr/bin/env bash
# vec-cosine.sh — sqlite-vec tables use cosine distance, not the L2 default.
#
# Source this file and call vec_create_sql, or run:
#   vec-cosine.sh repair <memory.db> <path-to-vec0.so-or-dylib>
# repair is a no-op when the extension file is missing (vectors cannot load).
# When the extension loads, each vec_memories_* table whose CREATE text lacks
# distance_metric=cosine is copied, dropped, and recreated. Vectors are copied;
# they are not recomputed.

vec_create_sql() {
  local table="$1" dims="$2" ifne="${3:-1}"
  case "$table" in
    vec_memories_[0-9]|vec_memories_[0-9][0-9]|vec_memories_[0-9][0-9][0-9]|vec_memories_[0-9][0-9][0-9][0-9]) ;;
    *) echo "vec_create_sql: bad table name" >&2; return 2 ;;
  esac
  case "$dims" in
    ''|*[!0-9]*) echo "vec_create_sql: bad dimensions" >&2; return 2 ;;
  esac
  if [ "$ifne" = "1" ]; then
    printf 'CREATE VIRTUAL TABLE IF NOT EXISTS %s USING vec0(memory_id INTEGER, embedding FLOAT[%s] distance_metric=cosine);\n' "$table" "$dims"
  else
    printf 'CREATE VIRTUAL TABLE %s USING vec0(memory_id INTEGER, embedding FLOAT[%s] distance_metric=cosine);\n' "$table" "$dims"
  fi
}

# Virtual table only. sqlite-vec shadow tables are vec_memories_<dims>_<suffix>
# and must not be rebuilt.
vec_rebuild_names() {
  local db="$1"
  sqlite3 -cmd ".timeout 5000" "$db" \
    "SELECT name FROM sqlite_master
     WHERE type='table'
       AND name GLOB 'vec_memories_[0-9]*'
       AND name NOT GLOB 'vec_memories_[0-9]*_*'
       AND IFNULL(sql,'') NOT LIKE '%distance_metric=cosine%';"
}

vec_repair_db() {
  local db="$1" ext="${2:-}"
  local names name dims sql create_sql bak
  [ -n "$db" ] && [ -f "$db" ] || return 0
  [ -n "$ext" ] && [ -f "$ext" ] || return 0
  if ! sqlite3 "$db" ".load \"$ext\"" "SELECT vec_version();" >/dev/null 2>&1; then
    echo "vec-cosine: extension failed to load: $ext" >&2
    return 1
  fi
  names=$(vec_rebuild_names "$db") || return 1
  [ -n "$names" ] || return 0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    case "$name" in
      vec_memories_[0-9]|vec_memories_[0-9][0-9]|vec_memories_[0-9][0-9][0-9]|vec_memories_[0-9][0-9][0-9][0-9]) ;;
      *) echo "vec-cosine: skip $name" >&2; continue ;;
    esac
    dims=${name#vec_memories_}
    bak="${name}_cosbak"
    create_sql=$(vec_create_sql "$name" "$dims" 0) || return 1
    sql=$(printf '%s\n' \
      "CREATE TABLE ${bak}(memory_id INTEGER, embedding);" \
      "INSERT INTO ${bak}(memory_id, embedding) SELECT memory_id, embedding FROM ${name};" \
      "DROP TABLE ${name};" \
      "$create_sql" \
      "INSERT INTO ${name}(memory_id, embedding) SELECT memory_id, embedding FROM ${bak};" \
      "DROP TABLE ${bak};")
    # .load is an argument, so sqlite3 does not read stdin. The rebuild
    # script has to be an argument too, or the L2 table is left in place.
    if ! sqlite3 -bail -cmd ".timeout 5000" "$db" ".load \"$ext\"" "$sql"; then
      echo "vec-cosine: rebuild failed for $name" >&2
      return 1
    fi
  done <<< "$names"
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  case "${1:-}" in
    repair)
      [ $# -eq 3 ] || { echo "usage: vec-cosine.sh repair <db> <vec0-extension>" >&2; exit 64; }
      vec_repair_db "$2" "$3"
      ;;
    *)
      echo "usage: vec-cosine.sh repair <db> <vec0-extension>" >&2
      exit 64
      ;;
  esac
fi
