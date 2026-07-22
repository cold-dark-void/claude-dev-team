#!/usr/bin/env bash
# TaskCompleted hook — plugin JSON validation + council quality gate
# Council gate enforces SPEC-002 + SPEC-013 + SPEC-009 contracts.
# Stdin is the primary task-id transport per the verified Claude Code contract
# (see .claude/plans/2026-04-09-taskcompleted-hook-spike.md). CLAUDE_TASK_ID env
# var is a fallback for non-native invocations only.

set -uo pipefail  # not -e — we handle errors explicitly per gate case

# Resolve roots once (set-u-safe).
# WTROOT = working-tree root: plugin manifests are PER-WORKTREE tracked artifacts;
#   validate THIS worktree's copy (show-toplevel resolves it from any subdir).
# MROOT = git-common-dir root: .claude/tasks, .claude/council, settings.json are
#   SHARED across worktrees per SPEC-002 "MUST resolve $MROOT from
#   git rev-parse --git-common-dir (NOT from cwd) ... under the shared worktree root".
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)

# CDV-210: emit task_complete on successful completion paths only (never on exit 2).
# Fail-open — never blocks TaskCompleted. Dual delivery with orchestrate MCP/webhook OK.
_emit_task_complete() {
  [ -n "${TASK_ID:-}" ] || return 0
  local PDH="" helper="" _pdh_hit=""
  if [ -f skills/plugin-dir.sh ]; then
    PDH=$(pwd)
  else
    _pdh_hit=$(find "${HOME:-}/.claude/plugins/cache" \
      -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null \
      | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./') || _pdh_hit=""
    if [ -n "$_pdh_hit" ]; then
      PDH=$(CDPATH= cd -- "$(dirname -- "$_pdh_hit")/.." && pwd) || PDH=""
    fi
  fi
  [ -n "$PDH" ] || return 0
  helper=$(bash "$PDH/skills/plugin-dir.sh" file skills/notify/webhook.sh 2>/dev/null) || helper=""
  [ -n "$helper" ] && [ -f "$helper" ] || return 0
  NOTIFY_SOURCE=task_completed NOTIFY_TASK="$TASK_ID" \
    bash "$helper" task_complete 2>/dev/null || true
}

# === plugin JSON validation ===

ERRORS=()

for f in "$WTROOT/.claude-plugin/plugin.json" "$WTROOT/.claude-plugin/marketplace.json"; do
  if [ -f "$f" ]; then
    if ! python3 -c "import json,sys; json.load(open('$f'))" 2>/dev/null; then
      ERRORS+=("$f is not valid JSON")
    fi
  fi
done

if [ ${#ERRORS[@]} -gt 0 ]; then
  echo "TaskCompleted hook: fix these before marking task done:" >&2
  for e in "${ERRORS[@]}"; do
    echo "  - $e" >&2
  done
  exit 2
fi

# === council gate ===
# Uses $MROOT (git-common-dir root, resolved at top) for shared council state.

# Read stdin once (one-shot); timeout 1 avoids hanging on direct shell invocations
STDIN_JSON=$(timeout 1 cat 2>/dev/null || true)

# Resolve task_id: stdin .task_id first, then CLAUDE_TASK_ID env var fallback
# Use heredoc to pass STDIN_JSON safely (avoids shell injection on backticks/quotes)
TASK_ID=$(python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    print(data.get("task_id", ""))
except Exception:
    print("")
' <<< "$STDIN_JSON" 2>/dev/null || true)

if [ -z "$TASK_ID" ]; then
  TASK_ID="${CLAUDE_TASK_ID:-}"
fi

# If no task id resolved, silent pass — gate cannot apply.
# Per SPEC-002 "If neither stdin JSON nor CLAUDE_TASK_ID yields a task id, the
# hook MUST treat the event as non-gated and silent no-op pass" a missing task id
# is ALWAYS a silent pass; the "cannot gate without task id" hard-fail (SPEC-002
# "requires_council: true declared but no task id can be resolved ... structural
# impossibility") is unreachable past this guard, so it is intentionally not implemented.
if [ -z "$TASK_ID" ]; then
  exit 0
fi

# Read task metadata
# Support both legacy flat key (1.json) and compound key (TICKET-1.json).
# TaskCreate resets integers to 1 each new process; compound keys prevent
# cross-run collisions. Fallback: pick most-recently-modified *-<ID>.json.
TASKS_DIR="$MROOT/.claude/tasks"
TASK_META="${TASKS_DIR}/${TASK_ID}.json"
if [ ! -f "$TASK_META" ]; then
  TASK_META=$(ls -t "${TASKS_DIR}/"*"-${TASK_ID}.json" 2>/dev/null | head -1 || true)
fi
if [ -z "$TASK_META" ] || [ ! -f "$TASK_META" ]; then
  # Silent pass — task pre-dates the gate or is not council-tracked
  _emit_task_complete
  exit 0
fi

# Parse requires_council
REQUIRES_COUNCIL=$(python3 -c '
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    print("true" if data.get("requires_council", False) else "false")
except Exception:
    print("false")
' "$TASK_META" 2>/dev/null || echo "false")

if [ "$REQUIRES_COUNCIL" != "true" ]; then
  _emit_task_complete
  exit 0  # silent pass — gate not opted in
fi

# Read threshold from settings.json (default 80)
SETTINGS="$MROOT/.claude/settings.json"
THRESHOLD=$(python3 -c '
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    print(data.get("council", {}).get("taskgate", {}).get("min_confidence", 80))
except Exception:
    print(80)
' "$SETTINGS" 2>/dev/null || echo "80")
THRESHOLD="${THRESHOLD:-80}"

# Read council index — required when gate is opted in
INDEX="$MROOT/.claude/council/index.json"
if [ ! -f "$INDEX" ]; then
  echo "TaskCompleted council gate: council index missing at $INDEX (task $TASK_ID requires_council=true)" >&2
  exit 2
fi

# Look up task in index; find max verdict confidence; ignore finding[]-shape rows (max_verdict_confidence: null)
MAX_VERDICT=$(python3 -c '
import json, sys
task_id = sys.argv[1]
index_path = sys.argv[2]
try:
    data = json.load(open(index_path))
    rows = data.get(task_id, [])
    if not rows:
        print("NO_TASK_IN_INDEX")
        sys.exit(0)
    verdict_rows = [r for r in rows if r.get("max_verdict_confidence") is not None]
    if not verdict_rows:
        print("NO_VERDICT_ROWS")
    else:
        print(max(r["max_verdict_confidence"] for r in verdict_rows))
except Exception as e:
    print("PARSE_ERROR", file=sys.stderr)
    print("PARSE_ERROR")
' "$TASK_ID" "$INDEX" 2>/dev/null || echo "PARSE_ERROR")

case "$MAX_VERDICT" in
  NO_TASK_IN_INDEX)
    echo "TaskCompleted council gate: no council verdict for task $TASK_ID (task not found in index)" >&2
    exit 2
    ;;
  NO_VERDICT_ROWS)
    echo "TaskCompleted council gate: no verdict[]-shape council run for task $TASK_ID (only finding[] rows or no rows)" >&2
    exit 2
    ;;
  PARSE_ERROR)
    echo "TaskCompleted council gate: failed to parse council index $INDEX for task $TASK_ID" >&2
    exit 2
    ;;
esac

# Numeric comparison — MAX_VERDICT is an integer at this point
if [ "$MAX_VERDICT" -lt "$THRESHOLD" ]; then
  echo "TaskCompleted council gate: max verdict confidence $MAX_VERDICT below threshold $THRESHOLD for task $TASK_ID" >&2
  exit 2
fi

# Pass
_emit_task_complete
exit 0
