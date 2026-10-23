#!/usr/bin/env bash
# defer.sh — deterministic backlog item DEFER (subprocess-only, never source).
#
# Usage:
#   defer.sh <slug> [--root PATH] [--note TEXT]
#
# Writes `**Status**: DEFERRED` on ROOT/.claude/backlog/<slug>.md (SPEC-040 M14).
# DEFERRED is an OPEN status (SPEC-009 § Backlog terminal status classification;
# skills/backlog/terminal-status.sh), so this verb:
#   - does NOT mark the item terminal,
#   - does NOT touch ROOT/.claude/backlog.md (the index row stays under Pending),
#   - does NOT prune, and does NOT call Linear (the session owns Linear).
# With --note the item also carries one `*Deferred: YYYY-MM-DD — TEXT*` footer
# line (existing footer replaced, never duplicated).
#
# ROOT = --root if set, else $MROOT — the parent of `git rev-parse
# --git-common-dir` — else pwd outside git (SPEC-009 § Backlog root rule).
#
# <slug> must be path-safe (`^[A-Za-z0-9_-]+$`, skills/backlog/slug.sh) — this
# verb does no title matching, so the caller resolves the slug first.
#
# Holds the shared backlog lock (skills/backlog/lock.sh, <root>/.claude/backlog.lock/)
# for the whole read-decide-write, taken after the write-free early exits and
# before the first read a write decision uses — same posture as close.sh.
#
# Exit: 0 deferred (incl. already DEFERRED) · 1 invalid slug / missing item /
# closed item / write failure / lock busy · 64 usage.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

die() {
  local rc="$1"; shift
  printf 'error: %s\n' "$*" >&2
  exit "$rc"
}

_TS="$SCRIPT_DIR/terminal-status.sh"
is_closed_status() {
  bash "$_TS" is-closed "$1"
}

[ -f "$SCRIPT_DIR/../lib/portable.sh" ] || die 1 "missing helper: $SCRIPT_DIR/../lib/portable.sh"
# shellcheck source=../lib/portable.sh
. "$SCRIPT_DIR/../lib/portable.sh"
[ -f "$SCRIPT_DIR/lock.sh" ] || die 1 "missing helper: $SCRIPT_DIR/lock.sh"
# shellcheck source=lock.sh
. "$SCRIPT_DIR/lock.sh"
[ -f "$SCRIPT_DIR/slug.sh" ] || die 1 "missing helper: $SCRIPT_DIR/slug.sh"
# shellcheck source=slug.sh
. "$SCRIPT_DIR/slug.sh"

USAGE='Usage: defer.sh <slug> [--root PATH] [--note TEXT]'

SLUG=""
NOTE=""
ROOT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --note) NOTE="${2:-}"; shift 2 || die 64 "--note needs value" ;;
    --root) ROOT="${2:-}"; shift 2 || die 64 "--root needs value" ;;
    -h|--help) printf '%s\n' "$USAGE"; exit 0 ;;
    -*) die 64 "unknown option: $1" ;;
    *)
      if [ -z "$SLUG" ]; then
        SLUG="$1"
        shift
      else
        die 64 "unexpected argument: $1"
      fi
      ;;
  esac
done

[ -n "$SLUG" ] || die 64 "missing <slug>"$'\n'"$USAGE"
require_valid_slug "$SLUG"

# LF or CR in the note would inject extra lines into the item file.
case "$NOTE" in
  *$'\n'*|*$'\r'*) die 64 "option value must not contain a newline or CR: --note" ;;
esac

# resolve_root (SPEC-009 C3): --root if set, else $MROOT (the parent of
# `git rev-parse --git-common-dir`), else pwd outside git.
resolve_root() {
  if [ -n "$ROOT" ]; then
    [ -d "$ROOT" ] || die 1 "root not a directory: $ROOT"
    ROOT=$(cd "$ROOT" && pwd)
    return 0
  fi
  local _gc
  if _gc=$(git rev-parse --git-common-dir 2>/dev/null); then
    ROOT=$(cd "$(dirname "$_gc")" && pwd)
    return 0
  fi
  ROOT=$(pwd)
}

# Item status first token, upper-cased; empty when the file has no Status line.
item_status_token() {
  local file="$1"
  grep -m1 -E '^\*\*Status\*\*:' "$file" 2>/dev/null \
    | sed 's/^\*\*Status\*\*:[[:space:]]*//' \
    | tr '[:lower:]' '[:upper:]' \
    | awk '{ print $1; exit }' || true
}

resolve_root
backlog_dir="$ROOT/.claude/backlog"
[ -d "$backlog_dir" ] || die 1 "no backlog dir: $backlog_dir"
file="$backlog_dir/${SLUG}.md"
[ -f "$file" ] || die 1 "missing item file: $file"

backlog_lock_acquire "$ROOT" || exit $?

st=$(item_status_token "$file")

if [ "$st" = "DEFERRED" ]; then
  printf 'Already deferred: .claude/backlog/%s.md\n' "$SLUG"
  exit 0
fi

if is_closed_status "$st"; then
  die 1 "item is closed (status=${st:-unknown}) — DEFERRED is an open status: .claude/backlog/$SLUG.md"
fi

new_status='**Status**: DEFERRED'
footer=""
if [ -n "$NOTE" ]; then
  footer=$(printf '*Deferred: %s — %s*' "$(date -u +%Y-%m-%d)" "$NOTE")
fi

# Rewrite goes through atomic_write (SPEC-009 § Backlog write integrity); values
# reach awk via ENVIRON, never -v, so \t \n \\ & / stay byte-for-byte. The
# producer runs inside atomic_write's `if`, so its own failures must surface:
# awk exits non-zero on an unreadable file and atomic_write propagates that rc.
atomic_write "$file" env BL_NS="$new_status" BL_FOOTER="$footer" awk '
  BEGIN { ns = ENVIRON["BL_NS"]; ft = ENVIRON["BL_FOOTER"]; status_done = 0; foot_done = 0 }
  /^\*\*Status\*\*:/ {
    print ns
    status_done = 1
    next
  }
  /^\*Deferred:/ {
    if (ft != "") { print ft; foot_done = 1 }
    else { print }
    next
  }
  { print }
  END {
    if (!status_done) print ns
    if (ft != "" && !foot_done) {
      print ""
      print ft
    }
  }
' "$file" || die 1 "failed to update item: $file"

printf 'Deferred: .claude/backlog/%s.md\n' "$SLUG"
