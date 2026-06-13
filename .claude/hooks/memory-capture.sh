#!/usr/bin/env bash
# PostToolUse hook — memory capture for Write/Edit only (not Bash).
# High-signal events only: file changes are worth remembering, shell commands are not.

_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
MEMDB="$MROOT/.claude/memory/memory.db"

[ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null || exit 0

TMPF="${TMPDIR:-/tmp}/memcap-$$"
cat > "$TMPF"

TOOL_NAME=$(jq -r '.tool_name // empty' "$TMPF" 2>/dev/null)

case "$TOOL_NAME" in
  Write|Edit) ;;
  *) rm -f "$TMPF"; exit 0 ;;
esac

AGENT=$(jq -r '.teammate_name // "auto"' "$TMPF" 2>/dev/null || echo "auto")
FILE_PATH=$(jq -r '.tool_input.file_path // empty' "$TMPF" 2>/dev/null)
rm -f "$TMPF"

[ -z "$FILE_PATH" ] && exit 0

OBSERVATION="${TOOL_NAME,,} $FILE_PATH"

DEDUP_FILE="${TMPDIR:-/tmp}/.claude-memcap-last"
LAST=$(cat "$DEDUP_FILE" 2>/dev/null || true)
[ "$OBSERVATION" = "$LAST" ] && exit 0
printf '%s' "$OBSERVATION" > "$DEDUP_FILE"

AGENT_ESC=$(printf '%s' "$AGENT" | sed "s/'/''/g")
OBS_ESC=$(printf '%s' "$OBSERVATION" | sed "s/'/''/g")
sqlite3 "$MEMDB" "PRAGMA busy_timeout=5000; INSERT INTO memories(agent, type, content) VALUES ('$AGENT_ESC', 'memory', '$OBS_ESC');" 2>/dev/null || true

exit 0
