#!/usr/bin/env bash
# tests/lib/path-farm.sh — hermetic PATH farm helper (wp-1-10-gate-hooks C2).
# Source-only, like hermetic.sh. bash 3.2 safe: no declare -A, no mapfile.
#
#   path_farm <dir> <cmd>...
#     Creates <dir>. For each <cmd>, symlinks `command -v <cmd>` into
#     <dir>/<cmd>. A <cmd> not found on the caller's PATH is skipped
#     silently. `timeout` and `gtimeout` are refused: the function does
#     NOT symlink either name, and returns 2 when either is named (other
#     requested commands in the same call are still farmed). Prints
#     nothing on stdout.
#
# Callers compose PATH from the farmed dir (plus any mock-command dir placed
# first), e.g.:
#   path_farm "$FARM" bash git jq sed awk
#   PATH="$MOCK_DIR:$FARM"
#   ! PATH="$FARM" command -v timeout   # assert timeout stays absent
# Resolve BASH_BIN (command -v bash) BEFORE narrowing PATH, then invoke a
# hook under test as "$BASH_BIN" <hook-script>, never bare `bash`.

path_farm() {
  local dir="$1"
  shift
  mkdir -p "$dir" || return 1
  local cmd path rc=0
  for cmd in "$@"; do
    case "$cmd" in
      timeout|gtimeout)
        rc=2
        continue
        ;;
    esac
    path=$(command -v "$cmd" 2>/dev/null) || continue
    ln -sf "$path" "$dir/$cmd" || return 1
  done
  return "$rc"
}
