#!/usr/bin/env bash
# PreCompact hook — delegate to the dev-team plugin's rescue-capture engine
# (SPEC-018 M12/M13). FAIL-OPEN (M17): always exits 0; exit 2 would block
# compaction and is forbidden. Graceful absence (M18): plugin not installed
# -> log one line, exit 0, compaction proceeds untouched.
#
# Locator: skills/plugin-dir.sh (product lock — not an ad-hoc third locator).
set -u

# Resolve plugin root (PDH): dev-checkout cwd fast path, else highest installed
# cache version. Same bootstrap as /orchestrate and init-orchestration Step 7.
PDH=""
if [ -f skills/plugin-dir.sh ]; then
  PDH=$(pwd)
else
  _pdh_hit=$(find "${HOME:-}/.claude/plugins/cache" \
    -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null \
    | sort -V | tail -1) || _pdh_hit=""
  if [ -n "$_pdh_hit" ]; then
    PDH=$(CDPATH= cd -- "$(dirname -- "$_pdh_hit")/.." && pwd) || PDH=""
  fi
fi

if [ -z "$PDH" ] || [ ! -f "$PDH/skills/plugin-dir.sh" ]; then
  echo "precompact-rescue: dev-team plugin not found — skipping rescue capture" >&2
  exit 0
fi

CAPTURE=$(bash "$PDH/skills/plugin-dir.sh" file skills/handoff/precompact-capture.sh 2>/dev/null) || CAPTURE=""
if [ -z "$CAPTURE" ] || [ ! -f "$CAPTURE" ]; then
  echo "precompact-rescue: precompact-capture.sh not found — skipping rescue capture" >&2
  exit 0
fi

bash "$CAPTURE"   # stdin (the hook JSON) passes through; engine always exits 0
exit 0
