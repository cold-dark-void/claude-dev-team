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
#   write-model.sh set-concurrency <N>
#   write-model.sh unset-concurrency
#
# Writes $MROOT/.claude/dev-team/models.local.json.
# A successful set or unset also appends runtime .gitignore entries when absent.
# list does not write. MUST NOT write repo models.json or ~/.claude/dev-team/models.json.
# Extra argv after required args is ignored.
# Exit 64 + usage on bad argv. Unparseable existing local → refuse, exit 1.
# set-concurrency validates N through the ONE cap grammar —
# resolve-concurrency.sh --flag in an env-clean subshell (SPEC-037 M30/M34).

set -euo pipefail

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RESOLVE="$HERE/resolve-model.sh"
# shellcheck source=../lib/portable.sh
. "$HERE/../lib/portable.sh"

usage() {
  echo "usage: write-model.sh {list|set <agent> <string>|unset <agent>|set-effort <agent> <token>|unset-effort <agent>|set-concurrency <N>|unset-concurrency}" >&2
  exit 64
}

is_mappable() {
  # Single source of the mappable set: SPEC-037 M8 + SPEC-039 M36 (advisor).
  # mappable-names.sh sits next to this script.
  "$HERE/mappable-names.sh" --is "$1"
}

is_effort_token() {
  case "$1" in
    low|medium|high|xhigh|max) return 0 ;;
    *) return 1 ;;
  esac
}

# The cap grammar has ONE home: resolve-concurrency.sh (SPEC-037 M30/M34).
# This script never re-implements it — see cap_is_valid.
RESOLVE_CONCURRENCY="$HERE/resolve-concurrency.sh"

cap_is_valid() {
  # Grammar-only validation through the resolver CLI: --flag <N> validates N and
  # exits before the env and map layers. COUNCIL_CONCURRENCY is cleared so a
  # caller's env can never make an invalid N look valid (or a valid one invalid).
  env -u COUNCIL_CONCURRENCY bash "$RESOLVE_CONCURRENCY" --flag "$1" >/dev/null 2>&1
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

# Publish JSON through the shared atomic_write (same-directory temp, kept
# mode). The name write_json_file is not atomic_write: portable.sh owns that
# name, and its arguments are <dest> <cmd>, not <map> <json>.
write_json_file() {
  local map=$1 json=$2
  atomic_write "$map" printf '%s\n' "$json"
}

# Handoff spines, the friction ledger, and local model pins stay untracked.
# Idempotent. list does not call this.
ensure_runtime_gitignore() {
  local entry gi="$MROOT/.gitignore"
  for entry in \
    ".claude/handoff/" \
    ".claude/retro/" \
    ".claude/dev-team/models.local.json*"; do
    grep -qF -- "$entry" "$gi" 2>/dev/null || printf '%s\n' "$entry" >> "$gi"
  done
}

cmd_list() {
  local agent model effort cap rc
  printf 'local: %s\n' "$MAP"
  # M34: report the merged cap through the resolver CLI (never re-merge here).
  rc=0
  cap=$(bash "$RESOLVE" --concurrency) || rc=$?
  if [ "$rc" -eq 64 ]; then
    echo "model-map: concurrency map value is invalid; list cannot report a cap" >&2
    exit 64
  fi
  printf 'concurrency: %s\n' "${cap:-unbounded}"
  # Mappable set comes from mappable-names.sh (SPEC-037 M8 / SPEC-039 M36).
  for agent in $(bash "$HERE/mappable-names.sh" --list); do
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
  # Atomic read-validate-modify-write under the portable lock (CDT-231; CDT-284): local_ok_to_write's
  # validation and the merge+atomic_write below must run as one critical
  # section, or two concurrent invocations can race and one clobbers the other.
  # mkdir here — the lock dir lives in this directory, and atomic_write
  # refuses when the parent directory does not exist yet.
  mkdir -p "$(dirname "$MAP")"
  (
    portable_lock_acquire "$LOCK" || exit 1
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
    ensure_runtime_gitignore
    write_json_file "$MAP" "$json"
  )
}

# Delete one agent key from a Model map field (agents or effort).
unset_field() {
  local field=$1 agent=$2
  is_mappable "$agent" || usage
  need_jq
  [ -e "$MAP" ] || exit 0
  # Atomic read-validate-modify-write under the portable lock (CDT-231; CDT-284) — see cmd_set.
  (
    portable_lock_acquire "$LOCK" || exit 1
    local_ok_to_write "$MAP" || exit 1
    local has json
    has=$(jq -r --arg n "$agent" --arg f "$field" '.[$f] // {} | has($n)' "$MAP" 2>/dev/null) || has="false"
    [ "$has" = "true" ] || exit 0
    json=$(jq --arg n "$agent" --arg f "$field" 'del(.[$f][$n])' "$MAP")
    ensure_runtime_gitignore
    write_json_file "$MAP" "$json"
  )
}

cmd_set_effort() {
  local agent=$1 raw=$2 val
  is_mappable "$agent" || usage
  val=$(trim "$raw")
  val=$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')
  [ -n "$val" ] && is_effort_token "$val" || usage
  need_jq
  # Atomic read-validate-modify-write under the portable lock (CDT-231; CDT-284) — see cmd_set.
  mkdir -p "$(dirname "$MAP")"
  (
    portable_lock_acquire "$LOCK" || exit 1
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
    ensure_runtime_gitignore
    write_json_file "$MAP" "$json"
  )
}

cmd_set_concurrency() {
  local raw=$1 val
  val=$(trim "$raw")
  cap_is_valid "$val" || usage
  need_jq
  # Atomic read-validate-modify-write under the portable lock (CDT-231; CDT-284) — see cmd_set.
  mkdir -p "$(dirname "$MAP")"
  (
    portable_lock_acquire "$LOCK" || exit 1
    local_ok_to_write "$MAP" || exit 1
    local json
    if [ -f "$MAP" ]; then
      json=$(jq --argjson v "$val" \
        '.version = (.version // 1) | .concurrency = $v' "$MAP")
    else
      json=$(jq -n --argjson v "$val" '{version:1, concurrency:$v}')
    fi
    ensure_runtime_gitignore
    write_json_file "$MAP" "$json"
  )
}

cmd_unset_concurrency() {
  need_jq
  [ -e "$MAP" ] || exit 0
  # Atomic read-validate-modify-write under the portable lock (CDT-231; CDT-284) — see cmd_set.
  (
    portable_lock_acquire "$LOCK" || exit 1
    local_ok_to_write "$MAP" || exit 1
    local has json
    has=$(jq -r 'has("concurrency")' "$MAP" 2>/dev/null) || has="false"
    [ "$has" = "true" ] || exit 0
    json=$(jq 'del(.concurrency)' "$MAP")
    ensure_runtime_gitignore
    write_json_file "$MAP" "$json"
  )
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
  set-concurrency)
    [ -n "${1:-}" ] || usage
    cmd_set_concurrency "$1"
    ;;
  unset-concurrency)
    cmd_unset_concurrency
    ;;
  *)
    usage
    ;;
esac
exit 0
