#!/usr/bin/env bash
# resolve-model.sh — emit a host model string from the local Model map (SPEC-037).
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
#
#   bash skills/model-map/resolve-model.sh <agent>
#
# stdout: trimmed model string, or empty (at most one trailing newline)
# stderr: warnings only (SPEC-037 M6/M7/M8/M9 prefixes)
# exit:   0 except 64 when $1 is missing or empty
# Extra argv after $1 is ignored.

set -euo pipefail

usage() {
  echo "usage: resolve-model.sh <agent>" >&2
  exit 64
}

[ -n "${1:-}" ] || usage
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
    pm|tech-lead|ic5|ic4|devops|qa|ds|council-judge) return 0 ;;
    *) return 1 ;;
  esac
}

is_internal() {
  case "$1" in
    distiller|project-init) return 0 ;;
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

argv_unknown() {
  if ! is_mappable "$AGENT" && ! is_internal "$AGENT"; then
    warn "model-map: unknown agent '${AGENT}'; using Tier default"
  fi
}

resolve_mroot
MAP="$MROOT/.claude/dev-team/models.local.json"

if ! command -v jq >/dev/null 2>&1; then
  warn "model-map: jq not found; using Tier default"
  exit 0
fi

if [ ! -f "$MAP" ]; then
  argv_unknown
  exit 0
fi

if ! jq empty "$MAP" >/dev/null 2>&1; then
  warn "model-map: unparseable JSON at ${MAP}; using Tier default"
  exit 0
fi

if ! jq -e 'has("agents")' "$MAP" >/dev/null 2>&1; then
  argv_unknown
  exit 0
fi

atype=$(jq -r '.agents | type' "$MAP" 2>/dev/null) || atype=""
if [ "$atype" != "object" ]; then
  warn "model-map: agents is not an object; using Tier default"
  exit 0
fi

while IFS= read -r key; do
  [ -n "$key" ] || continue
  if ! is_mappable "$key"; then
    warn "model-map: unknown agent key '${key}' ignored"
  fi
done < <(jq -r '.agents | keys[]' "$MAP" 2>/dev/null || true)

if is_internal "$AGENT"; then
  exit 0
fi

if ! is_mappable "$AGENT"; then
  warn "model-map: unknown agent '${AGENT}'; using Tier default"
  exit 0
fi

has=$(jq -r --arg n "$AGENT" '.agents | has($n)' "$MAP" 2>/dev/null) || has="false"
if [ "$has" != "true" ]; then
  exit 0
fi

typ=$(jq -r --arg n "$AGENT" '.agents[$n] | type' "$MAP" 2>/dev/null) || typ=""
if [ "$typ" != "string" ]; then
  warn "model-map: agents.${AGENT} is not a non-empty string; using Tier default"
  exit 0
fi

raw=$(jq -r --arg n "$AGENT" '.agents[$n]' "$MAP" 2>/dev/null) || raw=""
trimmed=$(trim "$raw")
if [ -z "$trimmed" ]; then
  warn "model-map: agents.${AGENT} is not a non-empty string; using Tier default"
  exit 0
fi

case "$AGENT" in
  qa|council-judge)
    warn "model-map: override for adversarial role '${AGENT}' is allowed and may weaken the gate"
    ;;
esac

printf '%s\n' "$trimmed"
exit 0
