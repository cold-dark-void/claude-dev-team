#!/usr/bin/env bash
# skills/backlog/readers.sh — read-only backlog item field readers (SPEC-009,
# SPEC-040 M5). SOURCE-ONLY — never run this file as a subprocess.
#
#   SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
#   [ -f "$SCRIPT_DIR/readers.sh" ] || die 1 "missing helper: $SCRIPT_DIR/readers.sh"
#   . "$SCRIPT_DIR/readers.sh"
#   status=$(item_status_value "$file")
#   title=$(item_title "$file")
#
# One copy of each reader shared by close.sh and sweep.sh (the writers of the
# write-through). reconcile.sh keeps its own pre-existing copies. Functions only:
# sourcing changes no shell options beyond `set -u`.

set -u

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  printf 'error: readers.sh is source-only — do ". readers.sh" from a caller script\n' >&2
  exit 64
fi

item_status_value() {
  local file="$1"
  grep -m1 -E '^\*\*Status\*\*:' "$file" 2>/dev/null \
    | sed 's/^\*\*Status\*\*:[[:space:]]*//' || true
}

# item_title <file> (SPEC-009 § Backlog write integrity, C6): prints the first
# "^# " line after the YAML frontmatter block (if any), with the leading "# "
# stripped. Prints nothing when no such line exists — callers fall back to the
# slug. Used at every former `head -n 1` title site.
item_title() {
  local file="$1"
  awk '
    NR == 1 && /^---[[:space:]]*$/ { in_fm = 1; next }
    in_fm && /^---[[:space:]]*$/ { in_fm = 0; next }
    in_fm { next }
    /^# / { sub(/^# */, ""); print; exit }
  ' "$file" 2>/dev/null || true
}
