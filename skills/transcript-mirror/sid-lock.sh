#!/usr/bin/env bash
# sid-lock.sh — per-sid mkdir lock for the Transcript mirror.
# acquire ROOT SID  exits 0 when this process holds $ROOT/.$SID.lock
# release ROOT SID  removes the lock only when this process owns it
# A child that inherits TM_LOCK_HELD=SID does not take or drop the parent's lock.
# Stale: owner pid is dead, or the directory is older than 120s.
# Fail-open: acquire exits 1 when the lock stays busy. Never sourced.
set -u

cmd="${1:-}"
ROOT="${2:-}"
SID="${3:-}"
STALE=120

[ -n "$ROOT" ] && [ -n "$SID" ] || exit 64
case "$SID" in
  ""|.*|*[!A-Za-z0-9._-]*|*..*) exit 64 ;;
esac

LOCK="$ROOT/.$SID.lock"

owner_pid() {
  [ -f "$LOCK/owner" ] || return 0
  awk 'NR==1 { print; exit }' "$LOCK/owner" 2>/dev/null || true
}

pid_alive() {
  [ -n "${1:-}" ] || return 1
  kill -0 "$1" 2>/dev/null
}

lock_age() {
  local now mtime
  now=$(date +%s)
  mtime=$(date -r "$LOCK" +%s 2>/dev/null || echo "$now")
  printf '%s\n' $((now - mtime))
}

is_stale() {
  local pid age
  [ -d "$LOCK" ] || return 1
  pid=$(owner_pid)
  if [ -n "$pid" ] && pid_alive "$pid"; then
    age=$(lock_age)
    [ "$age" -gt "$STALE" ]
    return
  fi
  return 0
}

case "$cmd" in
  acquire)
    if [ "${TM_LOCK_HELD:-}" = "$SID" ]; then
      exit 0
    fi
    n=0
    while [ "$n" -lt 20 ]; do
      if mkdir "$LOCK" 2>/dev/null; then
        # The holder is the parent. This script exits, so $$ would look dead.
        printf '%s\n%s\n' "$PPID" "$(date +%s)" > "$LOCK/owner" || true
        exit 0
      fi
      if is_stale; then
        rm -rf "$LOCK"
        n=$((n + 1))
        continue
      fi
      n=$((n + 1))
      sleep 0.25
    done
    exit 1
    ;;
  release)
    pid=$(owner_pid)
    # Holder release is a child of the owner. A grandchild (reapply) is not.
    if [ -n "$pid" ] && { [ "$pid" = "$$" ] || [ "$pid" = "$PPID" ]; }; then
      rm -rf "$LOCK"
    fi
    exit 0
    ;;
  *)
    exit 64
    ;;
esac
