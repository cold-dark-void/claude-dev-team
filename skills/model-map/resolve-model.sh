#!/usr/bin/env bash
# resolve-model.sh — emit a host model string or effort token from Model map layers (SPEC-037).
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
#
#   bash skills/model-map/resolve-model.sh <agent>
#   bash skills/model-map/resolve-model.sh --effort <agent>
#
# stdout: trimmed model string, or empty (at most one trailing newline)
#         --effort: lowercase token, or empty (inherited effort)
# stderr: warnings only (SPEC-037 M6/M7/M8/M9 prefixes; effort uses M25 inherited-effort)
# exit:   0 except 64 when the agent argument is missing or empty
# Extra argv after the agent is ignored.
# Read-only: MUST NOT mkdir or write. MUST NOT read DEVTEAM_MODEL_*.

set -euo pipefail

# JSON field in the Model map: agents (host model) or effort (inherited effort).
FIELD=agents
if [ "${1:-}" = "--effort" ]; then
  FIELD=effort
  shift
fi

if [ -z "${1:-}" ]; then
  extra=""
  [ "$FIELD" = "effort" ] && extra=" --effort"
  echo "usage: resolve-model.sh${extra} <agent>" >&2
  exit 64
fi
AGENT=$1

# Same rule as worktree-lib.sh resolve_mroot (SPEC-037 M1).
resolve_mroot() {
  local _gc
  if _gc=$(git rev-parse --git-common-dir 2>/dev/null); then
    MROOT=$(cd "$(dirname "$_gc")" && pwd)
  else
    MROOT=$(pwd)
  fi
}

is_mappable() {
  case "$1" in
    pm|tech-lead|ic5|ic4|devops|qa|ds|council-judge|finder|debugger) return 0 ;;
    *) return 1 ;;
  esac
}

is_internal() {
  case "$1" in
    distiller|project-init) return 0 ;;
    *) return 1 ;;
  esac
}

is_effort_token() {
  case "$1" in
    low|medium|high|xhigh|max) return 0 ;;
    *) return 1 ;;
  esac
}

trim() {
  local s=$1
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

warn() {
  echo "$1" >&2
}

# Accept one Model map value into WINNER, or warn and leave WINNER unset.
take_field_value() {
  local field=$1 typ=$2 raw=$3 trimmed
  if [ "$field" = "effort" ]; then
    if [ "$typ" != "string" ]; then
      warn "model-map: effort.${AGENT} is not a valid effort token; using inherited effort"
      return 0
    fi
    trimmed=$(trim "$raw")
    trimmed=$(printf '%s' "$trimmed" | tr '[:upper:]' '[:lower:]')
    if ! is_effort_token "$trimmed"; then
      warn "model-map: effort.${AGENT} is not a valid effort token; using inherited effort"
      return 0
    fi
    WINNER=$trimmed
    return 0
  fi
  if [ "$typ" != "string" ]; then
    warn "model-map: agents.${AGENT} is not a non-empty string; using Tier default"
    return 0
  fi
  trimmed=$(trim "$raw")
  if [ -z "$trimmed" ]; then
    warn "model-map: agents.${AGENT} is not a non-empty string; using Tier default"
    return 0
  fi
  WINNER=$trimmed
}

# Scan one layer: M7 unknown keys for $FIELD; first valid value for AGENT wins.
pick_from_layer() {
  local map=$1 field=$2 key has typ raw atype
  [ -f "$map" ] || return 0
  if ! jq empty "$map" >/dev/null 2>&1; then
    warn "model-map: unparseable JSON at ${map}; using Tier default"
    return 0
  fi
  if ! jq -e --arg f "$field" 'has($f)' "$map" >/dev/null 2>&1; then
    return 0
  fi
  atype=$(jq -r --arg f "$field" '.[$f] | type' "$map" 2>/dev/null) || atype=""
  if [ "$atype" != "object" ]; then
    if [ "$field" = "effort" ]; then
      warn "model-map: effort is not an object; using inherited effort"
    else
      warn "model-map: agents is not an object; using Tier default"
    fi
    return 0
  fi
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    if ! is_mappable "$key"; then
      warn "model-map: unknown agent key '${key}' ignored"
    fi
  done < <(jq -r --arg f "$field" '.[$f] | keys[]' "$map" 2>/dev/null || true)

  [ -z "$WINNER" ] || return 0
  if is_internal "$AGENT" || ! is_mappable "$AGENT"; then
    return 0
  fi

  has=$(jq -r --arg n "$AGENT" --arg f "$field" '.[$f] | has($n)' "$map" 2>/dev/null) || has="false"
  [ "$has" = "true" ] || return 0
  typ=$(jq -r --arg n "$AGENT" --arg f "$field" '.[$f][$n] | type' "$map" 2>/dev/null) || typ=""
  raw=$(jq -r --arg n "$AGENT" --arg f "$field" '.[$f][$n]' "$map" 2>/dev/null) || raw=""
  take_field_value "$field" "$typ" "$raw"
}

resolve_mroot

if ! command -v jq >/dev/null 2>&1; then
  warn "model-map: jq not found; using Tier default"
  exit 0
fi

WINNER=""
pick_from_layer "$MROOT/.claude/dev-team/models.local.json" "$FIELD"
pick_from_layer "$MROOT/.claude/dev-team/models.json" "$FIELD"
pick_from_layer "${HOME:-}/.claude/dev-team/models.json" "$FIELD"

if is_internal "$AGENT"; then
  exit 0
fi
if ! is_mappable "$AGENT"; then
  warn "model-map: unknown agent '${AGENT}'; using Tier default"
  exit 0
fi

if [ -n "$WINNER" ]; then
  case "$AGENT" in
    qa|council-judge)
      warn "model-map: override for adversarial role '${AGENT}' is allowed and may weaken the gate"
      ;;
  esac
  printf '%s\n' "$WINNER"
fi
exit 0
