#!/usr/bin/env bash
# Stop hook — non-blocking self-review reminder.
# Prints once per session when uncommitted changes exist; never blocks exit.

if ! git rev-parse --git-dir &>/dev/null; then
  exit 0
fi

_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && _MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || _MROOT=$(pwd)

TMPF="${TMPDIR:-/tmp}/stop-review-$$"
timeout 1 cat > "$TMPF" 2>/dev/null || true

SESSION_ID=$(jq -r '.session_id // empty' "$TMPF" 2>/dev/null || true)
rm -f "$TMPF"

# Strip anything that isn't alphanumeric, hyphen, or underscore to prevent
# path traversal via a crafted session_id value.
SESSION_ID=$(printf '%s' "$SESSION_ID" | tr -cd 'a-zA-Z0-9_-')
STAMP_KEY="${SESSION_ID:-ppid-${PPID:-0}}"
STAMP="$_MROOT/.claude/.stop-review-${STAMP_KEY}"

[ -f "$STAMP" ] && exit 0

DIRTY=$(git status --porcelain 2>/dev/null)
[ -z "$DIRTY" ] && exit 0

MODIFIED=0
while IFS= read -r line; do
  case "$line" in
    [MADRC]\ *|\ [MADRC]\ *) MODIFIED=$(( MODIFIED + 1 )) ;;
  esac
done <<< "$DIRTY"

if [ "$MODIFIED" -gt 0 ]; then
  touch "$STAMP"
  printf "Stop hook: %d file(s) modified but not committed.\n" "$MODIFIED"
fi

exit 0
