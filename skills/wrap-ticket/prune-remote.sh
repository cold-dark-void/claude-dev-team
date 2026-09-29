#!/usr/bin/env bash
# prune-remote.sh — best-effort remote feat/* prune after wrap-ticket ship (CDT-157).
#
# Subprocess CLI — NEVER source. stdout = report; stderr = diagnostics.
#
# Usage:
#   prune-remote.sh allowlisted <name>
#   prune-remote.sh candidates <T> [--linear-id ID] [--child ID]... [--epic]
#   prune-remote.sh safe-to-delete <branch> [--base REF]
#   prune-remote.sh prune <T> [--linear-id ID] [--child ID]... [--epic] [--dry-run] [--base REF]
#
# Exit: allowlisted 0/1; safe-to-delete 0 safe / 1 leftover; prune 0 (usage 64).
#
# Safety (WP 1-06, SPEC-016 wp-1-06-branch-deletion-safety AC C, D): each
# candidate is fetched into refs/remotes/origin/<n> first and judged there
# via skills/lib/git-safety.sh is-merged — never on refs/heads/<n> once
# origin exists. Delete uses --force-with-lease on the exact fetched SHA;
# an unqualified force flag is never used. resolve_base delegates to
# git-safety.sh resolve-base (SPEC-025 M17 item 9) — this file holds no
# copy of the base order.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
EPIC_LIB="$HERE/../epic/epic-lib.sh"
GIT_SAFETY="$HERE/../lib/git-safety.sh"

USAGE='Usage: prune-remote.sh allowlisted <name>
       prune-remote.sh candidates <T> [--linear-id ID] [--child ID]... [--epic]
       prune-remote.sh safe-to-delete <branch> [--base REF]
       prune-remote.sh prune <T> [--linear-id ID] [--child ID]... [--epic] [--dry-run] [--base REF]'

usage() {
  printf '%s\n' "$USAGE" >&2
  exit 64
}

# allowlisted <name>
# Accepts ^feat/(epic-)?[A-Za-z][A-Za-z0-9]*-[0-9]+(-[A-Za-z0-9]+)*$ after
# optional origin/ strip. Rejects master/main/stable/develop/HEAD/extra / / ...
allowlisted() {
  local n="${1-}"
  [ -n "$n" ] || return 1
  n="${n#origin/}"
  case "$n" in
    *..*|*/|*/*/*) return 1 ;;
  esac
  [[ "$n" =~ ^feat/(epic-)?[A-Za-z][A-Za-z0-9]*-[0-9]+(-[A-Za-z0-9]+)*$ ]]
}

resolve_mroot() {
  local _gc
  if _gc=$(git rev-parse --git-common-dir 2>/dev/null); then
    MROOT=$(cd "$(dirname "$_gc")" && pwd)
  else
    MROOT=$(pwd)
  fi
}

epic_exists() {
  local id="$1"
  [ -n "$id" ] || return 1
  if [ -f "$EPIC_LIB" ]; then
    bash "$EPIC_LIB" exists "$id" >/dev/null 2>&1 && return 0
  fi
  resolve_mroot
  [ -f "$MROOT/.claude/epics/$id/state.json" ]
}

# Print child id / linear_id lines from epic state (skip empty/null).
state_child_ids() {
  local id="$1" state
  resolve_mroot
  state="$MROOT/.claude/epics/$id/state.json"
  [ -f "$state" ] || return 0
  if command -v jq >/dev/null 2>&1; then
    jq -r '.children[]? | (.id // empty), (.linear_id // empty)' "$state" 2>/dev/null \
      | sed '/^$/d'
  fi
}

# Append unique feat/<id> lines to CANDS (newline-separated).
add_cand() {
  local id="${1-}" b
  [ -n "$id" ] || return 0
  b="feat/${id}"
  case $'\n'"${CANDS-}"$'\n' in
    *$'\n'"$b"$'\n'*) return 0 ;;
  esac
  if [ -n "${CANDS-}" ]; then
    CANDS="${CANDS}"$'\n'"$b"
  else
    CANDS="$b"
  fi
}

# Populate CANDS from T + flags. Uses globals: T LINEAR_ID EPIC CHILDREN.
build_candidates() {
  local id
  CANDS=""
  add_cand "$T"
  if [ -n "$LINEAR_ID" ] && [ "$LINEAR_ID" != "$T" ]; then
    add_cand "$LINEAR_ID"
  fi
  if [ "$EPIC" = "1" ] || epic_exists "$T"; then
    add_cand "epic-${T}"
    while IFS= read -r id; do
      add_cand "$id"
    done < <(state_child_ids "$T")
  fi
  for id in "${CHILDREN[@]+"${CHILDREN[@]}"}"; do
    add_cand "$id"
  done
}

# Resolve merge base: --base wins; else delegate to the one shared order
# (SPEC-025 M17 item 9). No copy of the order list here (AC I).
resolve_base() {
  if [ -n "${BASE-}" ]; then
    printf '%s\n' "$BASE"
    return 0
  fi
  bash "$GIT_SAFETY" resolve-base
}

# Resolve a constructed feat/ name to a local or origin tracking ref.
# Local-only fallback: used when origin is absent (dry-run, safe-to-delete).
resolve_branch_ref() {
  local name="$1"
  name="${name#origin/}"
  if git rev-parse --verify --quiet "refs/heads/${name}" >/dev/null; then
    printf '%s\n' "refs/heads/${name}"
    return 0
  fi
  if git rev-parse --verify --quiet "refs/remotes/origin/${name}" >/dev/null; then
    printf '%s\n' "refs/remotes/origin/${name}"
    return 0
  fi
  return 1
}

# One-line join for a (possibly multi-line) git stderr blob.
join_err() {
  printf '%s' "$1" | tr '\n' ' ' | sed 's/  */ /g; s/ $//'
}

# Classify a push's stderr as "already gone" — narrow on purpose (AC D3):
# a repository-not-found or auth failure MUST NOT be treated as already
# gone (fail-open would silently drop a real failure).
is_already_gone() {
  local err="$1"
  printf '%s' "$err" | grep -qE 'remote ref does not exist|src refspec .+ does not match'
}

# Fetch (when origin exists) or locally resolve one candidate, then judge
# safety against base via git-safety.sh is-merged. Never reads
# refs/heads/<n> once origin exists (AC C1). Shared by cmd_prune and
# cmd_safe_to_delete — no copy of this logic.
#
# Always returns 0; the result is reported through the globals below (bash
# 3.2 has no associative arrays):
#   CHK_STATE  safe | leftover | skip | failed
#   CHK_REASON set on leftover and failed
#   CHK_REF / CHK_SHA  set on safe (for the caller's lease delete)
classify_candidate() {
  local name="$1" base="$2" have_origin="$3"
  local ref="" sha="" err="" rc=0 mrc=0
  name="${name#origin/}"

  CHK_STATE="failed"
  CHK_REASON=""
  CHK_REF=""
  CHK_SHA=""

  if [ "$have_origin" = "1" ]; then
    rc=0
    err=$(git fetch --no-tags --quiet origin "+refs/heads/${name}:refs/remotes/origin/${name}" 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
      if printf '%s' "$err" | grep -qi "couldn't find remote ref"; then
        CHK_STATE="skip"
        return 0
      fi
      CHK_STATE="failed"
      CHK_REASON=$(join_err "$err") || CHK_REASON="$err"
      return 0
    fi
    ref="refs/remotes/origin/${name}"
  else
    if ! ref=$(resolve_branch_ref "$name"); then
      CHK_STATE="skip"
      return 0
    fi
  fi

  rc=0
  sha=$(git rev-parse --verify "${ref}^{commit}" 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$sha" ]; then
    CHK_STATE="failed"
    CHK_REASON="cannot resolve ${ref}"
    return 0
  fi

  mrc=0
  bash "$GIT_SAFETY" is-merged "$ref" "$base" || mrc=$?
  if [ "$mrc" -eq 0 ]; then
    CHK_STATE="safe"
    CHK_REF="$ref"
    CHK_SHA="$sha"
    return 0
  fi

  CHK_STATE="leftover"
  if [ "$mrc" -eq 1 ]; then
    CHK_REASON="unique commits"
  else
    CHK_REASON="check failed"
  fi
  return 0
}

cmd_allowlisted() {
  [ $# -ge 1 ] || usage
  if allowlisted "$1"; then
    exit 0
  fi
  exit 1
}

cmd_candidates() {
  parse_ticket_flags "$@"
  [ -n "$T" ] || usage
  build_candidates
  if [ -n "${CANDS-}" ]; then
    printf '%s\n' "$CANDS"
  fi
}

cmd_safe_to_delete() {
  local branch="" have_origin=0
  BASE=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --base)
        [ $# -ge 2 ] || usage
        BASE="$2"
        shift 2
        ;;
      -*) usage ;;
      *)
        if [ -z "$branch" ]; then
          branch="$1"
          shift
        else
          usage
        fi
        ;;
    esac
  done
  [ -n "$branch" ] || usage
  if ! BASE=$(resolve_base); then
    printf 'unresolvable base\n'
    exit 1
  fi

  if git remote get-url origin >/dev/null 2>&1; then
    have_origin=1
  fi

  classify_candidate "$branch" "$BASE" "$have_origin"
  case "$CHK_STATE" in
    safe) exit 0 ;;
    skip) printf 'missing\n'; exit 1 ;;
    *) printf '%s\n' "$CHK_REASON"; exit 1 ;;
  esac
}

cmd_prune() {
  parse_ticket_flags "$@"
  [ -n "$T" ] || usage
  local base name have_origin=0 err rc

  if ! base=$(resolve_base); then
    printf 'remote prune failed: unresolvable base\n'
    exit 0
  fi

  if git remote get-url origin >/dev/null 2>&1; then
    have_origin=1
  fi

  if [ "$DRY" != "1" ] && [ "$have_origin" != "1" ]; then
    printf 'remote prune failed: no origin remote\n'
    exit 0
  fi

  build_candidates
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    allowlisted "$name" || continue

    classify_candidate "$name" "$base" "$have_origin"
    case "$CHK_STATE" in
      skip)
        continue
        ;;
      failed)
        printf 'remote prune failed: %s: %s\n' "$name" "$CHK_REASON"
        continue
        ;;
      leftover)
        printf 'leftover: %s (%s)\n' "$name" "$CHK_REASON"
        continue
        ;;
    esac

    if [ "$DRY" = "1" ]; then
      printf 'pruned: %s\n' "$name"
      continue
    fi

    err=""
    rc=0
    err=$(git push --force-with-lease="refs/heads/${name}:${CHK_SHA}" origin ":refs/heads/${name}" 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
      printf 'pruned: %s\n' "$name"
    elif is_already_gone "$err"; then
      :
    else
      printf 'remote prune failed: %s: %s\n' "$name" "$(join_err "$err")"
    fi
  done < <(printf '%s\n' "${CANDS-}")
  exit 0
}

# Parse T + shared flags into globals.
parse_ticket_flags() {
  T=""
  LINEAR_ID=""
  EPIC=0
  DRY=0
  BASE=""
  CHILDREN=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --linear-id)
        [ $# -ge 2 ] || usage
        LINEAR_ID="$2"
        shift 2
        ;;
      --child)
        [ $# -ge 2 ] || usage
        CHILDREN+=("$2")
        shift 2
        ;;
      --epic)
        EPIC=1
        shift
        ;;
      --dry-run)
        DRY=1
        shift
        ;;
      --base)
        [ $# -ge 2 ] || usage
        BASE="$2"
        shift 2
        ;;
      -h|--help) usage ;;
      -*) usage ;;
      *)
        if [ -z "$T" ]; then
          T="$1"
          shift
        else
          usage
        fi
        ;;
    esac
  done
}

[ $# -ge 1 ] || usage
CMD="$1"
shift

case "$CMD" in
  allowlisted) cmd_allowlisted "$@" ;;
  candidates) cmd_candidates "$@" ;;
  safe-to-delete) cmd_safe_to_delete "$@" ;;
  prune) cmd_prune "$@" ;;
  -h|--help) usage ;;
  *) usage ;;
esac
