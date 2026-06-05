#!/usr/bin/env bash
#
# freshness.sh — Freshness guard for session JSONL files (SPEC-018 M9).
#
# Usage:
#   freshness.sh check <file>
#
# Exit codes:
#   0  — file is old enough (mtime >= 60 s ago); safe to parse
#   9  — file was modified < 60 s ago (in-progress); skip it
#   1  — usage error or file not found
#
# Cross-platform mtime: Linux `stat -c %Y` / macOS `stat -f %m`.
# Mirrors the 60 s guard in commands/retro.md (Filter 1).

set -eu

CMD="${1:-}"
FILE="${2:-}"

usage() {
  echo "Usage: freshness.sh check <file>" >&2
  exit 1
}

if [ "$CMD" != "check" ]; then
  usage
fi

if [ -z "$FILE" ]; then
  usage
fi

if [ ! -f "$FILE" ]; then
  echo "freshness.sh: file not found: $FILE" >&2
  exit 1
fi

# Cross-platform mtime: Linux uses -c %Y; macOS/BSD uses -f %m.
MTIME=$(stat -c %Y "$FILE" 2>/dev/null || stat -f %m "$FILE" 2>/dev/null)

if [ -z "$MTIME" ]; then
  echo "freshness.sh: cannot read mtime for: $FILE" >&2
  exit 1
fi

NOW=$(date +%s)
AGE=$(( NOW - MTIME ))

if [ "$AGE" -lt 60 ]; then
  echo "freshness.sh: WARNING — $FILE was modified ${AGE}s ago (< 60 s threshold); skipping in-progress transcript." >&2
  exit 9
fi

exit 0
