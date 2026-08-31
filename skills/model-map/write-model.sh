#!/usr/bin/env bash
# write-model.sh — write the local Model map layer (SPEC-037 M18).
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
#
#   write-model.sh list
#   write-model.sh set <agent> <string>
#   write-model.sh unset <agent>
#   write-model.sh set-effort <agent> <token>
#   write-model.sh unset-effort <agent>
#
# Writes ONLY $MROOT/.claude/dev-team/models.local.json.
# MUST NOT write repo models.json or ~/.claude/dev-team/models.json.
# Extra argv after required args is ignored.
# Exit 64 + usage on bad argv. Unparseable existing local → refuse, exit 1.

set -euo pipefail

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RESOLVE="$HERE/resolve-model.sh"

usage() {
  echo "usage: write-model.sh {list|set <agent> <string>|unset <agent>|set-effort <agent> <token>|unset-effort <agent>}" >&2
  exit 64
}

is_mappable() {
  case "$1" in
    pm|tech-lead|ic5|ic4|devops|qa|ds|council-judge|finder|debugger) return 0 ;;
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

warn_adversarial() {
  case "$1" in
    qa|council-judge)
      warn "model-map: override for adversarial role '${1}' is allowed and may weaken the gate"
      ;;
  esac
}

# Same rule as worktree-lib.sh resolve_mroot (SPEC-037 M1).
resolve_mroot() {
  local _gc
  if _gc=$(git rev-parse --git-common-dir 2>/dev/null); then
    MROOT=$(cd "$(dirname "$_gc")" && pwd)
  else
    MROOT=$(pwd)
  fi
}

need_jq() {
  if command -v jq >/dev/null 2>&1; then
    return 0
  fi
  warn "model-map: jq not found"
  exit 1
}

# 0 = absent or object. 1 = present but not an object.
require_object_field() {
  local map=$1 field=$2 atype
  if jq -e --arg f "$field" 'has($f)' "$map" >/dev/null 2>&1; then
    atype=$(jq -r --arg f "$field" '.[$f] | type' "$map" 2>/dev/null) || atype=""
    if [ "$atype" != "object" ]; then
      warn "model-map: ${field} is not an object; refusing to write"
      return 1
    fi
  fi
  return 0
}

# 0 = ok to merge (missing file is ok). 1 = refuse.
local_ok_to_write() {
  local map=$1
  [ -e "$map" ] || return 0
  if [ ! -f "$map" ]; then
    warn "model-map: refusing to write; ${map} is not a file"
    return 1
  fi
  if ! jq empty "$map" >/dev/null 2>&1; then
    warn "model-map: unparseable JSON at ${map}; refusing to write"
    return 1
  fi
  if [ "$(jq -r 'type' "$map" 2>/dev/null || true)" != "object" ]; then
    warn "model-map: unparseable JSON at ${map}; refusing to write"
    return 1
  fi
  require_object_field "$map" agents || return 1
  require_object_field "$map" effort || return 1
  return 0
}

atomic_write() {
  local map=$1 json=$2 dir tmp
  dir=$(dirname "$map")
  mkdir -p "$dir"
  tmp=$(mktemp "${map}.tmp.XXXXXX")
  printf '%s\n' "$json" >"$tmp"
  mv "$tmp" "$map"
}

cmd_list() {
  local agent model effort
  printf 'local: %s\n' "$MAP"
  for agent in pm tech-lead ic5 ic4 devops qa ds council-judge finder debugger; do
    model=$(bash "$RESOLVE" "$agent") || model=""
    [ -n "$model" ] || model="Tier default"
    effort=$(bash "$RESOLVE" --effort "$agent") || effort=""
    [ -n "$effort" ] || effort="inherited"
    printf '%-14s %-16s %s\n' "$agent" "$model" "$effort"
  done
}

cmd_set() {
  local agent=$1 raw=$2 val
  is_mappable "$agent" || usage
  val=$(trim "$raw")
  [ -n "$val" ] || usage
  need_jq
  # Atomic read-validate-modify-write under flock (CDT-231): local_ok_to_write's
  # validation and the merge+atomic_write below must run as one critical
  # section, or two concurrent invocations can race and one clobbers the other.
  # mkdir here — atomic_write's own mkdir runs inside the subshell, too late
  # to open the lock fd on a fresh clone with no .claude/dev-team/ yet.
  mkdir -p "$(dirname "$MAP")"
  (
    flock -x 9
    local_ok_to_write "$MAP" || exit 1
    warn_adversarial "$agent"
    local json
    if [ -f "$MAP" ]; then
      json=$(jq --arg n "$agent" --arg v "$val" \
        '.version = (.version // 1) | .agents = (.agents // {}) | .agents[$n] = $v' \
        "$MAP")
    else
      json=$(jq -n --arg n "$agent" --arg v "$val" \
        '{version:1, agents:{($n):$v}}')
    fi
    atomic_write "$MAP" "$json"
  ) 9>"$LOCK"
}

# Delete one agent key from a Model map field (agents or effort).
unset_field() {
  local field=$1 agent=$2
  is_mappable "$agent" || usage
  need_jq
  [ -e "$MAP" ] || exit 0
  # Atomic read-validate-modify-write under flock (CDT-231) — see cmd_set.
  (
    flock -x 9
    local_ok_to_write "$MAP" || exit 1
    local has json
    has=$(jq -r --arg n "$agent" --arg f "$field" '.[$f] // {} | has($n)' "$MAP" 2>/dev/null) || has="false"
    [ "$has" = "true" ] || exit 0
    json=$(jq --arg n "$agent" --arg f "$field" 'del(.[$f][$n])' "$MAP")
    atomic_write "$MAP" "$json"
  ) 9>"$LOCK"
}

cmd_set_effort() {
  local agent=$1 raw=$2 val
  is_mappable "$agent" || usage
  val=$(trim "$raw")
  val=$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')
  [ -n "$val" ] && is_effort_token "$val" || usage
  need_jq
  # Atomic read-validate-modify-write under flock (CDT-231) — see cmd_set.
  mkdir -p "$(dirname "$MAP")"
  (
    flock -x 9
    local_ok_to_write "$MAP" || exit 1
    warn_adversarial "$agent"
    local json
    if [ -f "$MAP" ]; then
      json=$(jq --arg n "$agent" --arg v "$val" \
        '.effort = (.effort // {}) | .effort[$n] = $v' \
        "$MAP")
    else
      json=$(jq -n --arg n "$agent" --arg v "$val" \
        '{version:1, effort:{($n):$v}}')
    fi
    atomic_write "$MAP" "$json"
  ) 9>"$LOCK"
}

[ -n "${1:-}" ] || usage
CMD=$1
shift || true

resolve_mroot
MAP="$MROOT/.claude/dev-team/models.local.json"
LOCK="$MAP.lock"

case "$CMD" in
  list)
    cmd_list
    ;;
  set)
    [ -n "${1:-}" ] && [ -n "${2:-}" ] || usage
    cmd_set "$1" "$2"
    ;;
  unset)
    [ -n "${1:-}" ] || usage
    unset_field agents "$1"
    ;;
  set-effort)
    [ -n "${1:-}" ] && [ -n "${2:-}" ] || usage
    cmd_set_effort "$1" "$2"
    ;;
  unset-effort)
    [ -n "${1:-}" ] || usage
    unset_field effort "$1"
    ;;
  *)
    usage
    ;;
esac
exit 0
