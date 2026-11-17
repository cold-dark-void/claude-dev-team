#!/usr/bin/env bash
# add.sh — local backlog add under the shared backlog lock.
# Subprocess only. Does not call Linear. The session still does MCP;
# this script is the locked read-modify-write for the local store.
#
#   add.sh --root ROOT --title TITLE [--problem TEXT] [--goal TEXT] [--linear-id ID]
#          [--kind ticket|epic|child] [--epic-parent ID] [--child-id ID]
#          [--depends-on JSON-ARRAY] [--estimate S|M|L] [--agent NAME]
#
# --kind plus the SPEC-025 epic fields (epic_parent / child_id / depends_on /
# estimate / agent) write YAML frontmatter on the item, so the offline ticket
# verbs can create epics and children in the one store (CDT-646). With no
# --kind and no --linear-id the file keeps its frontmatter-free shape.
#
# Exit: 0 wrote the item · 1 lock busy or write failed · 64 usage
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lock.sh
. "$SCRIPT_DIR/lock.sh"
# valid_slug — one copy, shared with close.sh / defer.sh (CDT-175).
# shellcheck source=slug.sh
. "$SCRIPT_DIR/slug.sh"

ROOT=""
TITLE=""
PROBLEM="TODO: describe the problem"
GOAL="TODO: describe the goal"
LINEAR_ID=""
KIND="ticket"
EPIC_PARENT=""
CHILD_ID=""
DEPENDS_ON=""
ESTIMATE=""
AGENT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2 || { printf 'add: --root needs a value\n' >&2; exit 64; } ;;
    --title) TITLE="${2:-}"; shift 2 || { printf 'add: --title needs a value\n' >&2; exit 64; } ;;
    --problem) PROBLEM="${2:-}"; shift 2 || { printf 'add: --problem needs a value\n' >&2; exit 64; } ;;
    --goal) GOAL="${2:-}"; shift 2 || { printf 'add: --goal needs a value\n' >&2; exit 64; } ;;
    --linear-id) LINEAR_ID="${2:-}"; shift 2 || { printf 'add: --linear-id needs a value\n' >&2; exit 64; } ;;
    --kind) KIND="${2:-}"; shift 2 || { printf 'add: --kind needs a value\n' >&2; exit 64; } ;;
    --epic-parent) EPIC_PARENT="${2:-}"; shift 2 || { printf 'add: --epic-parent needs a value\n' >&2; exit 64; } ;;
    --child-id) CHILD_ID="${2:-}"; shift 2 || { printf 'add: --child-id needs a value\n' >&2; exit 64; } ;;
    --depends-on) DEPENDS_ON="${2:-}"; shift 2 || { printf 'add: --depends-on needs a value\n' >&2; exit 64; } ;;
    --estimate) ESTIMATE="${2:-}"; shift 2 || { printf 'add: --estimate needs a value\n' >&2; exit 64; } ;;
    --agent) AGENT="${2:-}"; shift 2 || { printf 'add: --agent needs a value\n' >&2; exit 64; } ;;
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
reject_ctrl "$KIND" kind
reject_ctrl "$EPIC_PARENT" epic-parent
reject_ctrl "$CHILD_ID" child-id
reject_ctrl "$DEPENDS_ON" depends-on
reject_ctrl "$ESTIMATE" estimate
reject_ctrl "$AGENT" agent

case "$KIND" in
  ticket | epic | child) ;;
  *) printf 'add: --kind must be ticket, epic, or child: %s\n' "$KIND" >&2; exit 64 ;;
esac
# Frontmatter identifiers are path-shaped: the slug charset, so a junk value
# cannot smuggle a path out of .claude/backlog/.
for _id in "$EPIC_PARENT" "$CHILD_ID"; do
  [ -z "$_id" ] && continue
  valid_slug "$_id" || { printf 'add: epic identifier must match [A-Za-z0-9_-]+: %s\n' "$_id" >&2; exit 64; }
done
case "$ESTIMATE" in
  "" | S | M | L) ;;
  *) printf 'add: --estimate must be S, M, or L: %s\n' "$ESTIMATE" >&2; exit 64 ;;
esac
if [ -n "$AGENT" ]; then
  bash "$SCRIPT_DIR/../lib/require-agent.sh" "$AGENT" || exit 64
fi
case "$DEPENDS_ON" in
  "" | \[*\]) ;;
  *) printf 'add: --depends-on must be a JSON array: %s\n' "$DEPENDS_ON" >&2; exit 64 ;;
esac

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

# YAML frontmatter, in fixed key order. Empty when the caller passes neither
# --kind (non-ticket) / epic fields / --linear-id: the pre-CDT-646 shape.
fm=""
fm_add() { fm="${fm}${1}
"; }
[ "$KIND" = "ticket" ] || fm_add "kind: ${KIND}"
[ -z "$EPIC_PARENT" ] || fm_add "epic_parent: ${EPIC_PARENT}"
[ -z "$CHILD_ID" ] || fm_add "child_id: ${CHILD_ID}"
[ -z "$DEPENDS_ON" ] || fm_add "depends_on: ${DEPENDS_ON}"
[ -z "$ESTIMATE" ] || fm_add "estimate: ${ESTIMATE}"
[ -z "$AGENT" ] || fm_add "agent: ${AGENT}"
[ -z "$LINEAR_ID" ] || fm_add "linear_id: ${LINEAR_ID}"

{
  if [ -n "$fm" ]; then
    printf '%s\n' '---'
    printf '%s' "$fm"
    printf '%s\n' '---'
    printf '\n'
  fi
  printf '# %s\n\n' "$TITLE"
  printf '%s\n\n' '**Status**: PENDING'
  printf '## Problem\n\n%s\n\n' "$PROBLEM"
  printf '## Goal\n\n%s\n\n' "$GOAL"
  printf '%s\n\n' '---'
  printf '*Added: %s*\n' "$today"
} > "$item"

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
