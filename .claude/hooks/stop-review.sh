#!/usr/bin/env bash
# Stop hook — non-blocking self-review reminder.
# Prints once per (cwd + HEAD-sha) when uncommitted changes exist; never blocks exit.
# The stamp re-fires when HEAD moves (a commit lands), not on every `claude --resume`.

if ! git rev-parse --git-dir &>/dev/null; then
  exit 0
fi

_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && _MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || _MROOT=$(pwd)

# Drain stdin so the harness doesn't block on the pipe; we don't need its content.
TMPF="${TMPDIR:-/tmp}/stop-review-$$"
timeout 1 cat > "$TMPF" 2>/dev/null || true
rm -f "$TMPF"

HEAD_SHA=$(git -C "$_MROOT" rev-parse --short HEAD 2>/dev/null || echo "nohead")
CWD_HASH=$(printf '%s' "$PWD" | cksum | cut -d' ' -f1)
STAMP_KEY="${CWD_HASH}-${HEAD_SHA}"
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
  # Sweep stale stamps from prior HEAD shas to keep .claude/ tidy.
  find "$_MROOT/.claude" -maxdepth 1 -name '.stop-review-*' \
    ! -name ".stop-review-${STAMP_KEY}" -delete 2>/dev/null || true
  touch "$STAMP"
  printf "Stop hook: %d file(s) modified but not committed.\n" "$MODIFIED"
fi

exit 0
