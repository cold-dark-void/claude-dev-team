#!/usr/bin/env bash
#
# retro-gate/hint.sh — Non-blocking friction hint for /kickoff and /orchestrate
#
# Resolves the current session JSONL, runs gate.sh, and prints a /retro
# suggestion to stdout when the gate passes. Always exits 0. Never blocks.
#
# Usage: bash skills/retro-gate/hint.sh <GATE_SH>
#   where GATE_SH is the absolute path to skills/retro-gate/gate.sh
#   (the caller already has this from its own PLUGIN_VER lookup).

set -u

GATE_SH="${1:-}"
if [ -z "$GATE_SH" ] || [ ! -x "$GATE_SH" ]; then
  exit 0
fi

# Resolve current session JSONL (Claude stores sessions under an encoded project path)
ENCODED_PATH=$(pwd | sed 's|/|-|g')
SESSION_JSONL=$(ls -t "$HOME/.claude/projects/${ENCODED_PATH}/"*.jsonl 2>/dev/null | head -1)

if [ -z "$SESSION_JSONL" ]; then
  exit 0
fi

GATE_OUT=$(bash "$GATE_SH" "$SESSION_JSONL" 2>/dev/null)
if echo "$GATE_OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("passed") else 1)' 2>/dev/null; then
  SID=$(basename "$SESSION_JSONL" .jsonl)
  echo "Consider: /retro $SID"
fi

exit 0
