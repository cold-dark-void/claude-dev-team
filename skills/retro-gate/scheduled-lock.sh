#!/usr/bin/env bash
# scheduled-lock.sh — concurrency lock for scheduled /retro --all --auto (CDV-190).
#
# Usage:
#   scheduled-lock.sh acquire <mroot>   # exit 0 acquired; 2 held (fresh); 1 error
#   scheduled-lock.sh release <mroot>   # exit 0 always (fail-open)
#
# Lock path: $MROOT/.claude/retro/scheduled.lock
# Content: pid\nts_epoch\n
# TTL: 7200s (2h) — stale locks are stolen.
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=../lib/portable.sh
. "$HERE/../lib/portable.sh"

TTL_SEC=7200

usage() {
  echo "usage: scheduled-lock.sh acquire|release <mroot>" >&2
  exit 1
}

[ $# -ge 2 ] || usage
CMD=$1
MROOT=$2
[ -n "$MROOT" ] || usage

RETRO_DIR="$MROOT/.claude/retro"
LOCK="$RETRO_DIR/scheduled.lock"

case "$CMD" in
  acquire)
    mkdir -p "$RETRO_DIR" || {
      echo "scheduled-lock: cannot create $RETRO_DIR" >&2
      exit 1
    }
    NOW=$(date +%s)
    if [ -f "$LOCK" ]; then
      # shellcheck disable=SC2034
      {
        read -r _pid || true
        read -r lock_ts || true
      } <"$LOCK"
      lock_ts=${lock_ts:-0}
      # Non-numeric → treat as stale.
      case "$lock_ts" in
        ''|*[!0-9]*) lock_ts=0 ;;
      esac
      age=$((NOW - lock_ts))
      if [ "$age" -lt "$TTL_SEC" ] && [ "$lock_ts" -gt 0 ]; then
        echo "scheduled retro: lock held, skipping" >&2
        exit 2
      fi
      # Stale or corrupt → steal.
    fi
    # Same-directory temp via atomic_write. A name that ends in $$ is predictable.
    if ! atomic_write "$LOCK" printf '%s\n%s\n' "$$" "$NOW"; then
      echo "scheduled-lock: cannot install lock" >&2
      exit 1
    fi
    exit 0
    ;;
  release)
    rm -f "$LOCK" 2>/dev/null || true
    exit 0
    ;;
  *)
    usage
    ;;
esac
