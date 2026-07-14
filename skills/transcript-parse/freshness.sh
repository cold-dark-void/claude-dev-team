#!/usr/bin/env bash
#
# freshness.sh — Freshness guard for session JSONL files (SPEC-018 M9).
#
# Usage:
#   freshness.sh check <file> [--allow-in-progress]
#
# Exit codes:
#   0  — file is old enough (mtime >= 60 s ago); safe to parse
#        OR --allow-in-progress was passed (M14 carve-out; still warns)
#   9  — file was modified < 60 s ago (in-progress); skip it
#   1  — usage error or file not found
#
# SCOPED CARVE-OUT (SPEC-018 M14): a PreCompact capture is by definition
# mid-write. Passed EXCLUSIVELY by skills/handoff/precompact-capture.sh via
# prepass.sh prepare --allow-in-progress. No user-invoked path (/handoff cold,
# /retro) passes it — default guard behavior (exit 9) is unchanged.
#
# Cross-platform mtime: Linux `stat -c %Y` / macOS `stat -f %m`.
# Mirrors the 60 s guard in commands/retro.md (Filter 1).

set -eu

CMD="${1:-}"
FILE="${2:-}"
ALLOW=0
if [ "${3:-}" = "--allow-in-progress" ]; then
  ALLOW=1
fi

usage() {
  echo "Usage: freshness.sh check <file> [--allow-in-progress]" >&2
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
# `|| true` keeps set -e from aborting when BOTH stat variants fail, so the
# "cannot read mtime" branch below is reachable (not dead code).
MTIME=$(stat -c %Y "$FILE" 2>/dev/null || stat -f %m "$FILE" 2>/dev/null || true)

if [ -z "$MTIME" ]; then
  echo "freshness.sh: cannot read mtime for: $FILE" >&2
  exit 1
fi

NOW=$(date +%s)
AGE=$(( NOW - MTIME ))

if [ "$AGE" -lt 60 ]; then
  if [ "$ALLOW" = "1" ]; then
    echo "freshness.sh: NOTE — $FILE modified ${AGE}s ago (< 60 s); proceeding anyway (--allow-in-progress, PreCompact capture path)." >&2
    exit 0
  fi
  echo "freshness.sh: WARNING — $FILE was modified ${AGE}s ago (< 60 s threshold); skipping in-progress transcript." >&2
  exit 9
fi

exit 0
