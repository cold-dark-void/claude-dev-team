#!/usr/bin/env bash
#
# metrics/rollup.sh — CDV-187 read-only observability rollup.
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
#
# Usage:
#   rollup.sh [--json] [--section all|council|outcomes|worktree]
#
# Reads (never writes):
#   $MROOT/.claude/council/index.json          (SPEC-013)
#   $MROOT/.claude/metrics/outcomes.jsonl      (SPEC-026)
#   $MROOT/.worktrees/* dirs + .claude/tasks/*.json (cheap counts)
#
# Exit codes:
#   0   success or partial (always non-fatal for orchestration-style use)
#  64   usage error (unknown flag / bad section)

set -euo pipefail
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

USAGE='Usage: rollup.sh [--json] [--section all|council|outcomes|worktree]'

JSON_MODE=0
SECTION=all

usage() {
  echo "error: $1" >&2
  echo "$USAGE" >&2
  exit 64
}

while [ $# -gt 0 ]; do
  case "$1" in
    --json)
      JSON_MODE=1
      shift
      ;;
    --section)
      [ $# -ge 2 ] || usage "--section requires a value"
      SECTION="$2"
      shift 2
      ;;
    --section=*)
      SECTION="${1#--section=}"
      shift
      ;;
    -h|--help)
      echo "$USAGE"
      exit 0
      ;;
    *)
      usage "unknown argument: $1"
      ;;
  esac
done

case "$SECTION" in
  all|council|outcomes|worktree) ;;
  *)
    usage "bad section '$SECTION' (expected all|council|outcomes|worktree)"
    ;;
esac

want_section() {
  [ "$SECTION" = "all" ] || [ "$SECTION" = "$1" ]
}

# ---- resolve_mroot ----------------------------------------------------------
resolve_mroot() {
  local _gc
  if _gc=$(git rev-parse --git-common-dir 2>/dev/null); then
    MROOT=$(cd "$(dirname "$_gc")" && pwd)
  else
    MROOT=$(pwd)
  fi
}

resolve_mroot

# ---- jq guard ---------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  if [ "$JSON_MODE" -eq 1 ]; then
    # Valid empty shell so callers can still parse.
    printf '%s\n' '{"council":null,"outcomes":null,"worktree":null,"error":"jq not found"}'
  else
    echo "rollup: jq not found; cannot aggregate metrics (install jq)" >&2
  fi
  exit 0
fi

# ---- empty section templates ------------------------------------------------
empty_council='{"present":false,"task_ids":0,"entries":0,"verdict_buckets":{"ge80":0,"b50_79":0,"lt50":0,"null":0}}'
empty_outcomes='{"present":false,"n":0,"by_outcome":{"accepted":0,"escalated":0,"rejected":0},"by_agent":{},"by_task_class":{}}'
empty_worktree='{"present":false,"worktrees_n":0,"tasks":{"pending":0,"in_progress":0,"completed":0,"blocked":0,"other":0,"files_n":0}}'

COUNCIL_JSON="$empty_council"
OUTCOMES_JSON="$empty_outcomes"
WORKTREE_JSON="$empty_worktree"

# ---- council ----------------------------------------------------------------
if want_section council; then
  CI_FILE="$MROOT/.claude/council/index.json"
  if [ -f "$CI_FILE" ]; then
    COUNCIL_JSON="$(
      jq -c '
        if type != "object" then
          {present:true, task_ids:0, entries:0, verdict_buckets:{ge80:0,b50_79:0,lt50:0,null:0}}
        else
          ([.[] | if type == "array" then .[] else empty end]) as $entries
          | {
              present: true,
              task_ids: (keys | length),
              entries: ($entries | length),
              verdict_buckets: (
                $entries
                | reduce .[] as $e (
                    {ge80:0, b50_79:0, lt50:0, "null":0};
                    ($e.max_verdict_confidence) as $c
                    | if $c == null then .null += 1
                      elif ($c | type) != "number" then .null += 1
                      elif $c >= 80 then .ge80 += 1
                      elif $c >= 50 then .b50_79 += 1
                      else .lt50 += 1
                      end
                  )
              )
            }
        end
      ' "$CI_FILE" 2>/dev/null
    )" || COUNCIL_JSON="$empty_council"
    if [ -z "$COUNCIL_JSON" ]; then
      COUNCIL_JSON='{"present":true,"task_ids":0,"entries":0,"verdict_buckets":{"ge80":0,"b50_79":0,"lt50":0,"null":0}}'
    fi
  fi
fi

# ---- outcomes ---------------------------------------------------------------
if want_section outcomes; then
  OUT_FILE="$MROOT/.claude/metrics/outcomes.jsonl"
  if [ -f "$OUT_FILE" ]; then
    OUTCOMES_JSON="$(
      jq -n -R '
        [inputs | select(length > 0) | try fromjson catch empty | select(type == "object")] as $rows
        | {
            present: true,
            n: ($rows | length),
            by_outcome: {
              accepted: ($rows | map(select(.outcome == "accepted")) | length),
              escalated: ($rows | map(select(.outcome == "escalated")) | length),
              rejected: ($rows | map(select(.outcome == "rejected")) | length)
            },
            by_agent: (
              $rows
              | map(
                  # rv-w3-24: a non-string .agent used to error the object-key
                  # build and zero the whole outcomes section; coerce it to the
                  # "null" bucket like by_task_class does.
                  if .agent == null then "null"
                  elif (.agent | type) == "string" then .agent
                  else "null"
                  end
                )
              | group_by(.)
              | map({(.[0]): length})
              | add // {}
            ),
            by_task_class: (
              $rows
              | map(
                  if .task_class == null then "null"
                  elif (.task_class | type) == "string" then .task_class
                  else "null"
                  end
                )
              | group_by(.)
              | map({(.[0]): length})
              | add // {}
            )
          }
      ' <"$OUT_FILE" 2>/dev/null
    )" || OUTCOMES_JSON="$empty_outcomes"
    if [ -z "$OUTCOMES_JSON" ]; then
      OUTCOMES_JSON='{"present":true,"n":0,"by_outcome":{"accepted":0,"escalated":0,"rejected":0},"by_agent":{},"by_task_class":{}}'
    fi
  fi
fi

# ---- worktree / tasks -------------------------------------------------------
if want_section worktree; then
  WT_DIR="$MROOT/.worktrees"
  TASK_DIR="$MROOT/.claude/tasks"
  WT_PRESENT=false
  WT_N=0
  if [ -d "$WT_DIR" ]; then
    WT_PRESENT=true
    # Count directories only (not files)
    WT_N=$(find "$WT_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
  fi

  TASK_PRESENT=false
  TASKS_JSON='{"pending":0,"in_progress":0,"completed":0,"blocked":0,"other":0,"files_n":0}'
  if [ -d "$TASK_DIR" ]; then
    TASK_PRESENT=true
    # Aggregate status from *.json; missing/malformed → other
    shopt -s nullglob
    TASK_FILES=("$TASK_DIR"/*.json)
    shopt -u nullglob
    if [ "${#TASK_FILES[@]}" -gt 0 ]; then
      # Per-file parse (rv-w3-24): one malformed task file used to make
      # `jq -s` error out and zero every count, although the comment above
      # promises malformed files count as "other". Parse each file on its
      # own; a file that fails to parse is one "other".
      T_PENDING=0; T_INPROG=0; T_COMPLETED=0; T_BLOCKED=0; T_OTHER=0; T_FILES=0
      for _tf in "${TASK_FILES[@]}"; do
        T_FILES=$((T_FILES + 1))
        _st=$(jq -rc 'if type == "object" then (.status // "other") else "malformed" end' "$_tf" 2>/dev/null) || _st=""
        case "$_st" in
          pending)     T_PENDING=$((T_PENDING + 1)) ;;
          in_progress) T_INPROG=$((T_INPROG + 1)) ;;
          completed)   T_COMPLETED=$((T_COMPLETED + 1)) ;;
          blocked)     T_BLOCKED=$((T_BLOCKED + 1)) ;;
          *)           T_OTHER=$((T_OTHER + 1)) ;;
        esac
      done
      TASKS_JSON="$(
        jq -cn \
          --argjson p "$T_PENDING" \
          --argjson i "$T_INPROG" \
          --argjson c "$T_COMPLETED" \
          --argjson b "$T_BLOCKED" \
          --argjson o "$T_OTHER" \
          --argjson n "$T_FILES" \
          '{
            pending: $p,
            in_progress: $i,
            completed: $c,
            blocked: $b,
            other: $o,
            files_n: $n
          }'
      )"
      if [ -z "$TASKS_JSON" ]; then
        TASKS_JSON='{"pending":0,"in_progress":0,"completed":0,"blocked":0,"other":0,"files_n":0}'
      fi
    fi
  fi

  # present if either worktrees dir or tasks dir exists
  if [ "$WT_PRESENT" = true ] || [ "$TASK_PRESENT" = true ]; then
    WORKTREE_JSON="$(
      jq -cn \
        --argjson wn "$WT_N" \
        --argjson tasks "$TASKS_JSON" \
        '{present: true, worktrees_n: $wn, tasks: $tasks}'
    )"
  fi
fi

# ---- emit -------------------------------------------------------------------
RESULT="$(
  jq -cn \
    --argjson council "$COUNCIL_JSON" \
    --argjson outcomes "$OUTCOMES_JSON" \
    --argjson worktree "$WORKTREE_JSON" \
    '{
      council: $council,
      outcomes: $outcomes,
      worktree: $worktree
    }'
)"

if [ "$JSON_MODE" -eq 1 ]; then
  printf '%s\n' "$RESULT"
  exit 0
fi

# Human tables
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%s)
echo "Metrics — all-time — $TS"
echo ""

if want_section council; then
  echo "─── Council ──────────────────────────────────────"
  if [ "$(printf '%s' "$COUNCIL_JSON" | jq -r '.present')" = "true" ]; then
    printf '  task_ids=%s  entries=%s  conf≥80=%s  50–79=%s  <50=%s  null=%s\n' \
      "$(printf '%s' "$COUNCIL_JSON" | jq -r '.task_ids')" \
      "$(printf '%s' "$COUNCIL_JSON" | jq -r '.entries')" \
      "$(printf '%s' "$COUNCIL_JSON" | jq -r '.verdict_buckets.ge80')" \
      "$(printf '%s' "$COUNCIL_JSON" | jq -r '.verdict_buckets.b50_79')" \
      "$(printf '%s' "$COUNCIL_JSON" | jq -r '.verdict_buckets.lt50')" \
      "$(printf '%s' "$COUNCIL_JSON" | jq -r '.verdict_buckets.null')"
  else
    echo "  (no council index yet)"
  fi
  echo ""
fi

if want_section outcomes; then
  echo "─── Outcomes (SPEC-026) ──────────────────────────"
  if [ "$(printf '%s' "$OUTCOMES_JSON" | jq -r '.present')" = "true" ]; then
    printf '  n=%s  accepted=%s  escalated=%s  rejected=%s\n' \
      "$(printf '%s' "$OUTCOMES_JSON" | jq -r '.n')" \
      "$(printf '%s' "$OUTCOMES_JSON" | jq -r '.by_outcome.accepted')" \
      "$(printf '%s' "$OUTCOMES_JSON" | jq -r '.by_outcome.escalated')" \
      "$(printf '%s' "$OUTCOMES_JSON" | jq -r '.by_outcome.rejected')"
    AGENTS_LINE=$(printf '%s' "$OUTCOMES_JSON" | jq -r '
      .by_agent
      | to_entries
      | if length == 0 then "(none)"
        else map("\(.key)=\(.value)") | join(" ")
        end
    ')
    CLASS_LINE=$(printf '%s' "$OUTCOMES_JSON" | jq -r '
      .by_task_class
      | to_entries
      | if length == 0 then "(none)"
        else map("\(.key)=\(.value)") | join(" ")
        end
    ')
    echo "  by agent: $AGENTS_LINE"
    echo "  by class: $CLASS_LINE"
  else
    echo "  (no outcomes ledger yet)"
  fi
  echo ""
fi

if want_section worktree; then
  echo "─── Worktrees / tasks ────────────────────────────"
  if [ "$(printf '%s' "$WORKTREE_JSON" | jq -r '.present')" = "true" ]; then
    printf '  worktrees=%s  tasks: pending=%s in_progress=%s completed=%s blocked=%s other=%s files_n=%s\n' \
      "$(printf '%s' "$WORKTREE_JSON" | jq -r '.worktrees_n')" \
      "$(printf '%s' "$WORKTREE_JSON" | jq -r '.tasks.pending')" \
      "$(printf '%s' "$WORKTREE_JSON" | jq -r '.tasks.in_progress')" \
      "$(printf '%s' "$WORKTREE_JSON" | jq -r '.tasks.completed')" \
      "$(printf '%s' "$WORKTREE_JSON" | jq -r '.tasks.blocked')" \
      "$(printf '%s' "$WORKTREE_JSON" | jq -r '.tasks.other')" \
      "$(printf '%s' "$WORKTREE_JSON" | jq -r '.tasks.files_n')"
  else
    echo "  (no worktrees or task store yet)"
  fi
  echo ""
fi

exit 0
