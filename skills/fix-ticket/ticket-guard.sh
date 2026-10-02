#!/usr/bin/env bash
# ticket-guard.sh — ticket id, worktree slug, git worktree check, report path.
# Subprocess only. Do not source.
set -u

TICKET_RE='^[A-Za-z0-9._-]+$'

usage() {
  echo "usage: ticket-guard.sh {validate|slug|check-worktree|report-path} ..." >&2
  exit 64
}

cmd_validate() {
  local ticket="${1:-}"
  if [ -z "$ticket" ] || [[ ! "$ticket" =~ $TICKET_RE ]]; then
    echo "error: invalid ticket id (only [A-Za-z0-9._-] allowed): ${ticket:-}" >&2
    return 64
  fi
  printf '%s\n' "$ticket" || return 1
}

cmd_slug() {
  local ticket
  ticket="$(cmd_validate "${1:-}")" || return $?
  # worktree-lib rejects '.'. Map each dot to a hyphen.
  printf '%s\n' "${ticket//./-}" || return 1
}

cmd_check_worktree() {
  local wt="${1:-}" inside
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    echo "error: worktree not found: ${wt:-}" >&2
    return 1
  fi
  inside="$(git -C "$wt" rev-parse --is-inside-work-tree 2>/dev/null || true)"
  if [ "$inside" != "true" ]; then
    echo "error: --worktree is not a git worktree: $wt" >&2
    return 1
  fi
  printf '%s\n' "$wt" || return 1
}

cmd_report_path() {
  local dir="${1:-}" date="${2:-}" ticket="${3:-}" base cand n
  if [ -z "$dir" ] || [ -z "$date" ]; then
    echo "error: report-path needs dir, date, and ticket" >&2
    return 64
  fi
  if [[ ! "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "error: report date must be YYYY-MM-DD: $date" >&2
    return 64
  fi
  cmd_validate "$ticket" >/dev/null || return $?
  base="$dir/${date}-${ticket}.md"
  if [ ! -e "$base" ]; then
    printf '%s\n' "$base" || return 1
    return 0
  fi
  n=2
  while [ "$n" -le 99 ]; do
    cand="$dir/${date}-${ticket}-${n}.md"
    if [ ! -e "$cand" ]; then
      printf '%s\n' "$cand" || return 1
      return 0
    fi
    n=$((n + 1))
  done
  echo "error: too many same-day reports for $ticket" >&2
  return 1
}

cmd="${1:-}"
if [ "$#" -gt 0 ]; then
  shift
fi
case "$cmd" in
  validate) cmd_validate "${1:-}" ;;
  slug) cmd_slug "${1:-}" ;;
  check-worktree) cmd_check_worktree "${1:-}" ;;
  report-path) cmd_report_path "${1:-}" "${2:-}" "${3:-}" ;;
  *) usage ;;
esac
exit $?
