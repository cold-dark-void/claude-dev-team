#!/usr/bin/env bash
# journal-stats.sh — stats for one /craft-loop journal (rv-w3-28).
#
# Usage:
#   journal-stats.sh <name>.journal.md
#
# Prints one `key: value` line per stat:
#   file, bytes, lines, iterations, open_decisions, last_entry
# `open_decisions` counts `- [DECISION]` cards with no indented `Answer:`
# line beneath them (the same rule the list mode renders).
#
# Exit: 0 ok · 1 missing file · 64 usage

set -uo pipefail

usage() {
  echo "usage: journal-stats.sh <journal.md>" >&2
  exit 64
}

[ $# -eq 1 ] || usage
J=$1
[ -f "$J" ] || { echo "journal-stats: no such file: $J" >&2; exit 1; }

BYTES=$(wc -c < "$J" | tr -d ' ')
LINES=$(wc -l < "$J" | tr -d ' ')
ITERATIONS=$(grep -c '^## Iteration' "$J" 2>/dev/null) || ITERATIONS=0
case "$ITERATIONS" in ''|*[!0-9]*) ITERATIONS=0 ;; esac

# Open decision cards: a `- [DECISION]` line opens; only an INDENTED
# `Answer:` line beneath it closes it (a column-0 Answer: does not). A new
# entry heading ends the scan block; an unclosed card stays open.
OPEN=$(awk '
  /^[[:space:]]*-[[:space:]]*\[DECISION\]/ { total++; pending=1; next }
  pending && /^[[:space:]]+Answer:/ { closed++; pending=0; next }
  pending && /^## / { pending=0 }
  END { print total - closed }
' "$J")
LAST=$(grep '^## Iteration' "$J" 2>/dev/null | tail -1)

printf 'file: %s\n' "$J"
printf 'bytes: %s\n' "$BYTES"
printf 'lines: %s\n' "$LINES"
printf 'iterations: %s\n' "$ITERATIONS"
printf 'open_decisions: %s\n' "$OPEN"
printf 'last_entry: %s\n' "${LAST:-none}"
exit 0
