#!/usr/bin/env bash
#
# retro-gate/hint.sh — Non-blocking friction hint for /kickoff and /orchestrate
#
# Resolves the current session JSONL, runs gate.sh, and prints a /retro
# suggestion to stdout when the gate passes. Always exits 0. Never blocks.
#
# Self-locates gate.sh as a sibling of this script via BASH_SOURCE.
# No positional argument required.
#
# Usage: bash skills/retro-gate/hint.sh
#   (or via PDH bootstrap: bash "$PDH/skills/retro-gate/hint.sh")
#
# Optional: pass an explicit gate.sh path as $1 to override the sibling default.

set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE_SH="${1:-$SELF_DIR/gate.sh}"
if [ -z "$GATE_SH" ] || [ ! -x "$GATE_SH" ]; then
  exit 0
fi

# Resolve current session JSONL (Claude stores sessions under an encoded project
# path). Encode MROOT (the git-common-dir parent), NOT pwd: in a git worktree
# pwd != MROOT, so a pwd-based encoding would pick the WRONG project dir and can
# flag the wrong session. Mirrors commands/retro.md's MROOT resolution.
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
ENCODED_PATH=$(echo "$MROOT" | sed 's|/|-|g')
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
