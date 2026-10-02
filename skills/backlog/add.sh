#!/usr/bin/env bash
# add.sh — local backlog add under the shared backlog lock.
# Subprocess only. Does not call Linear. The session still does MCP;
# this script is the locked read-modify-write for the local store.
#
#   add.sh --root ROOT --title TITLE [--problem TEXT] [--goal TEXT] [--linear-id ID]
#
# Exit: 0 wrote the item · 1 lock busy or write failed · 64 usage
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lock.sh
. "$SCRIPT_DIR/lock.sh"

ROOT=""
TITLE=""
PROBLEM="TODO: describe the problem"
GOAL="TODO: describe the goal"
LINEAR_ID=""

while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2 || { printf 'add: --root needs a value\n' >&2; exit 64; } ;;
    --title) TITLE="${2:-}"; shift 2 || { printf 'add: --title needs a value\n' >&2; exit 64; } ;;
    --problem) PROBLEM="${2:-}"; shift 2 || { printf 'add: --problem needs a value\n' >&2; exit 64; } ;;
    --goal) GOAL="${2:-}"; shift 2 || { printf 'add: --goal needs a value\n' >&2; exit 64; } ;;
    --linear-id) LINEAR_ID="${2:-}"; shift 2 || { printf 'add: --linear-id needs a value\n' >&2; exit 64; } ;;
    *) printf 'add: unknown argument: %s\n' "$1" >&2; exit 64 ;;
  esac
done

[ -n "$ROOT" ] && [ -n "$TITLE" ] || { printf 'add: --root and --title are required\n' >&2; exit 64; }
reject_ctrl() {
  case "$1" in
    *$'\n'*|*$'\r'*) printf 'add: %s must not contain a newline or CR\n' "$2" >&2; exit 64 ;;
  esac
}
reject_ctrl "$TITLE" title
reject_ctrl "$PROBLEM" problem
reject_ctrl "$GOAL" goal
reject_ctrl "$LINEAR_ID" linear-id

slug=$(printf '%s' "$TITLE" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed 's/^-//; s/-$//; s/--*/-/g' | cut -c1-50)
[ -n "$slug" ] || { printf 'add: title produced an empty slug\n' >&2; exit 64; }

backlog_lock_acquire "$ROOT" || exit $?

dir="$ROOT/.claude/backlog"
index="$ROOT/.claude/backlog.md"
mkdir -p "$dir"
n=2
base="$slug"
while [ -f "$dir/${slug}.md" ]; do
  slug="${base}-${n}"
  n=$((n + 1))
done

today=$(date -u +%Y-%m-%d)
item="$dir/${slug}.md"
if [ -n "$LINEAR_ID" ]; then
  cat > "$item" <<EOF
---
linear_id: ${LINEAR_ID}
---

# ${TITLE}

**Status**: PENDING

## Problem

${PROBLEM}

## Goal

${GOAL}

---

*Added: ${today}*
EOF
else
  cat > "$item" <<EOF
# ${TITLE}

**Status**: PENDING

## Problem

${PROBLEM}

## Goal

${GOAL}

---

*Added: ${today}*
EOF
fi

if [ ! -f "$index" ]; then
  printf '%s\n' "# Backlog Index" "" "## Pending" "" "## Completed" "" > "$index"
fi
row="- [${TITLE}](backlog/${slug}.md) - ${TITLE} [PENDING]"
if [ -n "$LINEAR_ID" ]; then
  row="${row} linear:${LINEAR_ID}"
fi
# Insert the row after the Pending heading. Keep every other line.
tmp=$(mktemp "${TMPDIR:-/tmp}/backlog-add.XXXXXX")
awk -v row="$row" '
  { print }
  /^## Pending$/ && !ins { print row; ins=1 }
' "$index" > "$tmp"
mv "$tmp" "$index"
printf 'Added: %s\n' "$item"
backlog_lock_release
