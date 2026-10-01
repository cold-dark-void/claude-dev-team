#!/usr/bin/env bash
# check-traceability.sh — report-only AC coverage (W1-41, CDT-485).
#
#   bash tools/check-traceability.sh [--root DIR]
#
# An id is SPEC-<n>/T<n> or SPEC-<n>/M<n> written in specs/**/*.md.
# A cover is a `# covers: <id>` line in a test script (test.sh, test-*.sh,
# *-test.sh). This phase prints uncovered ids and always exits 0.
# Exit 64 is usage only.
set -u
ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
if [ "${1:-}" = "--root" ]; then
  [ -n "${2:-}" ] || { echo "usage: check-traceability.sh [--root DIR]" >&2; exit 64; }
  ROOT=$2
  shift 2
fi
[ $# -eq 0 ] || { echo "usage: check-traceability.sh [--root DIR]" >&2; exit 64; }
[ -d "$ROOT" ] || { echo "usage: check-traceability.sh [--root DIR]" >&2; exit 64; }

ids=$(mktemp "${TMPDIR:-/tmp}/trace-ids.XXXXXX")
tags=$(mktemp "${TMPDIR:-/tmp}/trace-tags.XXXXXX")
trap 'rm -f "$ids" "$tags"' EXIT

if [ -d "$ROOT/specs" ]; then
  find "$ROOT/specs" -type f -name '*.md' -print0 \
    | xargs -0 grep -hoE 'SPEC-[0-9]+/[TM][0-9]+' 2>/dev/null \
    | sort -u > "$ids" || true
fi

find "$ROOT" -type f \( -name 'test.sh' -o -name 'test-*.sh' -o -name '*-test.sh' \) \
  -not -path '*/.git/*' -not -path "$ROOT/.worktrees/*" -print0 \
  | xargs -0 grep -hoE '# covers: SPEC-[0-9]+/[TM][0-9]+' 2>/dev/null \
  | sed 's/^# covers: //' | sort -u > "$tags" || true

uncovered=0
while IFS= read -r id; do
  [ -n "$id" ] || continue
  if ! grep -qxF "$id" "$tags"; then
    printf 'uncovered: %s\n' "$id"
    uncovered=$((uncovered + 1))
  fi
done < "$ids"

if [ "$uncovered" -eq 0 ]; then
  echo "traceability: clean (report only)"
else
  echo "traceability: $uncovered uncovered (report only)"
fi
exit 0
