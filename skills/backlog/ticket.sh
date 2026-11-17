#!/usr/bin/env bash
# ticket.sh — offline ticket verbs over the local backlog store (SPEC-009
# § Offline ticket verbs, CDT-646). Subprocess-only, bash-only: this file
# spawns no network process and issues no Linear MCP call. The local store is
# the ticket source of truth; Linear is an opt-in downstream mirror.
#
# Usage:
#   ticket.sh create --root ROOT --title TITLE [--kind ticket|epic|child]
#                    [--problem TEXT] [--goal TEXT] [--epic-parent ID]
#                    [--child-id ID] [--depends-on JSON-ARRAY]
#                    [--estimate S|M|L] [--agent NAME] [--linear-id ID]
#   ticket.sh claim  --root ROOT <slug-or-title> [--owner NAME]
#   ticket.sh close  --root ROOT <slug-or-title> [--ticket ID] [--sha SHA]
#                    [--note TEXT] [--status COMPLETED|FIXED/CLOSED]
#
# --root is required: the verbs run from a session cwd that may be any
# worktree, and the store lives at $MROOT (SPEC-009 § Backlog root rule).
#
# A ticket, an epic, and a child all run through these three verbs — the kind
# and SPEC-025 epic fields ride in the item's YAML frontmatter (skills/backlog/add.sh).
#
# Verb engines (one copy of each write path — this file adds no writer of its own):
#   create → add.sh    claim → close.sh claim    close → close.sh
#
# Linear ordering (SPEC-009 § Linear sync is opt-in): the local write is always
# first. Only then does the verb hand off through skills/backlog/linear-gate.sh.
# Gate off → one skip line, zero Linear work. Gate on → the caller's Linear
# bridge runs second: set $LINEAR_SYNC_CMD (whitespace-separated argv, split
# without globbing) to a command the gate invokes with the new/changed item's
# linear_id appended when present.
#
# Every verb prints the store path. Exit: 0 ok · 1 verb failed (passed through
# from the engine) · 64 usage (an ambiguous match passes through as 64 too).

set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

die() {
  local rc="$1"
  shift
  printf 'error: %s\n' "$*" >&2
  exit "$rc"
}

usage() {
  printf '%s' >&2 <<'USAGE'
usage: ticket.sh create --root PATH --title TITLE [--kind ticket|epic|child]
                        [--problem TEXT] [--goal TEXT] [--epic-parent ID]
                        [--child-id ID] [--depends-on JSON-ARRAY]
                        [--estimate S|M|L] [--agent NAME] [--linear-id ID]
       ticket.sh claim  --root PATH <slug-or-title> [--owner NAME]
       ticket.sh close  --root PATH <slug-or-title> [--ticket ID] [--sha SHA]
                        [--note TEXT] [--status COMPLETED|FIXED/CLOSED]
USAGE
  exit 64
}

[ $# -ge 1 ] || usage
VERB="$1"
shift
case "$VERB" in
  create | claim | close) ;;
  *) usage ;;
esac

ROOT=""
ROOT_GIVEN=false
ENGINE_ARGS=()
SLUG_QUERY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --root)
      [ $# -ge 2 ] || usage
      ROOT="$2"
      ROOT_GIVEN=true
      shift 2
      ;;
    --linear-id)
      # local write takes the id; the verb prints it back after the write
      [ $# -ge 2 ] || usage
      LINEAR_ID_ARG="$2"
      ENGINE_ARGS+=("$1" "$2")
      shift 2
      ;;
    --)
      die 64 "ticket: '--' is not an argument of these verbs"
      ;;
    *)
      if [ "$VERB" != "create" ] && [ -z "$SLUG_QUERY" ] && [ "${1#--}" = "$1" ]; then
        SLUG_QUERY="$1"
        ENGINE_ARGS+=("$1")
        shift
      else
        [ $# -ge 2 ] || usage
        ENGINE_ARGS+=("$1" "$2")
        shift 2
      fi
      ;;
  esac
done

[ "$ROOT_GIVEN" = true ] || die 64 "ticket: --root is required (the store lives at \$MROOT)"
[ -d "$ROOT" ] || die 1 "root not a directory: $ROOT"
ROOT=$(cd "$ROOT" && pwd)
STORE="$ROOT/.claude/backlog"
GATE="$SCRIPT_DIR/linear-gate.sh"

if [ "$VERB" != "create" ]; then
  [ -n "$SLUG_QUERY" ] || die 64 "ticket $VERB needs <slug-or-title>"
fi

# --- 1. local write first (never a network call) ------------------------------
case "$VERB" in
  create)
    bash "$SCRIPT_DIR/add.sh" --root "$ROOT" ${ENGINE_ARGS[@]+"${ENGINE_ARGS[@]}"} \
      || die $? "ticket create failed"
    ;;
  claim)
    bash "$SCRIPT_DIR/close.sh" claim ${ENGINE_ARGS[@]+"${ENGINE_ARGS[@]}"} --root "$ROOT" \
      || die $? "ticket claim failed"
    ;;
  close)
    bash "$SCRIPT_DIR/close.sh" ${ENGINE_ARGS[@]+"${ENGINE_ARGS[@]}"} --root "$ROOT" \
      || die $? "ticket close failed"
    ;;
esac

printf 'store: %s\n' "$STORE"

# --- 2. Linear second, and only when the gate says so -------------------------
if [ -n "${LINEAR_SYNC_CMD:-}" ]; then
  # read -a splits the seam on IFS only: no pathname expansion, so a glob
  # character in the value reaches the bridge as one literal argument.
  SYNC=()
  read -r -a SYNC <<< "$LINEAR_SYNC_CMD"
  if [ -n "${LINEAR_ID_ARG:-}" ]; then
    SYNC+=("$LINEAR_ID_ARG")
  fi
  bash "$GATE" sync --root "$ROOT" -- "${SYNC[@]}"
  exit $?
fi
bash "$GATE" sync --root "$ROOT"
exit 0
