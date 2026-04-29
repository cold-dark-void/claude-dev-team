#!/usr/bin/env bash
# worktree-lib.sh — manage per-task git worktrees with PID-aware locks.
#
# Subcommands:
#   ensure <slug>   create-or-reuse worktree at $MROOT/.worktrees/<slug>
#   release <slug>  remove lock + worktree if clean
#
# Stdout discipline: ensure prints ONLY the absolute worktree path on success.
# All diagnostics go to stderr. Stdout is empty on any non-zero exit.

set -euo pipefail

resolve_mroot() {
  local _gc
  if _gc=$(git rev-parse --git-common-dir 2>/dev/null); then
    MROOT=$(cd "$(dirname "$_gc")" && pwd)
  else
    MROOT=$(pwd)
  fi
}

# lock_age_seconds <iso8601-utc-timestamp>
# Print integer seconds elapsed since timestamp, or empty string on parse failure.
lock_age_seconds() {
  local ts="$1" then now
  now=$(date -u +%s)
  # GNU date
  if then=$(date -u -d "$ts" +%s 2>/dev/null); then
    echo $(( now - then ))
    return 0
  fi
  # BSD/macOS date — strip trailing Z, use -j -f
  local stripped="${ts%Z}"
  if then=$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null); then
    echo $(( now - then ))
    return 0
  fi
  echo ""
}

cmd_ensure() {
  local slug="${1:-}"
  if [ -z "$slug" ]; then
    echo "ensure: missing <slug>" >&2
    exit 64
  fi

  resolve_mroot
  local wt="$MROOT/.worktrees/$slug"
  local lock="$wt/.wt-lock"
  local branch="feat/$slug"
  local session_id="${CLAUDE_SESSION_ID:-sess-$$}"

  if [ -f "$lock" ]; then
    # Parse: "<session> <pid> <iso-timestamp>"
    local lock_content lock_session lock_pid lock_ts
    lock_content=$(cat "$lock" 2>/dev/null || echo "")
    # shellcheck disable=SC2086
    set -- $lock_content
    lock_session="${1:-}"
    lock_pid="${2:-}"
    lock_ts="${3:-}"

    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
      # Live collision — gather diagnostics
      local head_info="(unknown)"
      if [ -d "$wt/.git" ] || [ -f "$wt/.git" ]; then
        head_info=$(git -C "$wt" log -1 --format='%h %s' 2>/dev/null || echo "(unknown)")
      fi
      local age_secs age_str
      age_secs=$(lock_age_seconds "$lock_ts")
      if [ -n "$age_secs" ]; then
        age_str="${age_secs}s"
      else
        age_str="unknown"
      fi

      {
        echo "Worktree collision: $slug"
        echo "  branch:   $branch"
        echo "  HEAD:     $head_info"
        echo "  lock age: $age_str"
        echo "  session:  $lock_session"
        echo "  PID $lock_pid is live"
      } >&2

      local answer=""
      if [ -r /dev/tty ]; then
        printf "[abort/steal] " >/dev/tty
        IFS= read -r answer </dev/tty || answer=""
      else
        printf "[abort/steal] " >&2
        # stdin closed → read returns empty → treated as abort (exit 2)
        IFS= read -r answer || answer=""
      fi

      if [ "$answer" = "steal" ]; then
        printf '%s %s %s\n' "$session_id" "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$lock"
        printf '%s\n' "$wt"
        exit 0
      fi
      exit 2
    fi

    # Stale lock — silently overwrite
    printf '%s %s %s\n' "$session_id" "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$lock"
    printf '%s\n' "$wt"
    exit 0
  fi

  # No lock. If worktree dir exists, just create the lock.
  if [ -d "$wt" ]; then
    printf '%s %s %s\n' "$session_id" "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$lock"
    printf '%s\n' "$wt"
    exit 0
  fi

  mkdir -p "$MROOT/.worktrees"
  # Atomic: create branch + worktree in one git call when branch is absent,
  # so a worktree-add failure never leaves an orphan branch behind.
  if git -C "$MROOT" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null 2>&1; then
    git -C "$MROOT" worktree add "$wt" "$branch" >&2
  else
    git -C "$MROOT" worktree add -b "$branch" "$wt" >&2
  fi

  printf '%s %s %s\n' "$session_id" "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$lock"
  printf '%s\n' "$wt"
  exit 0
}

cmd_release() {
  local slug="${1:-}"
  if [ -z "$slug" ]; then
    echo "release: missing <slug>" >&2
    exit 64
  fi

  resolve_mroot
  local wt="$MROOT/.worktrees/$slug"

  if [ ! -d "$wt" ]; then
    echo "release: worktree not found: $wt" >&2
    exit 1
  fi

  local dirty
  # Filter out .wt-lock — it's our bookkeeping file, not user content.
  # Porcelain format: "XY <path>" — strip the lock entry by exact-path match.
  dirty=$(git -C "$wt" status --porcelain 2>/dev/null | awk '$0 !~ /^.. \.wt-lock$/' || true)
  if [ -n "$dirty" ]; then
    echo "release: uncommitted changes in $wt — refusing to remove" >&2
    exit 1
  fi

  rm -f "$wt/.wt-lock"
  git -C "$MROOT" worktree remove "$wt" >&2
  exit 0
}

main() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    ensure)  cmd_ensure "$@" ;;
    release) cmd_release "$@" ;;
    *)
      echo "usage: worktree-lib.sh {ensure|release} <slug>" >&2
      exit 64
      ;;
  esac
}

main "$@"
