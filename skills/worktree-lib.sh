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

# git_retry <max_tries> <sleep_ms> <git args...>
# Run a git command, retrying on EBUSY-class errors that surface from
# concurrent .git/config rewrites (common on WSL2's 9p filesystem when
# multiple agents share a repo). Returns the final exit code.
git_retry() {
  local max="$1" sleep_ms="$2"; shift 2
  local i=0 rc=0 err=""
  while [ "$i" -lt "$max" ]; do
    err=$(git "$@" 2>&1) && { [ -n "$err" ] && printf '%s\n' "$err" >&2; return 0; }
    rc=$?
    case "$err" in
      *"Device or resource busy"*|*"could not write config"*|*"update of config-file failed"*)
        i=$(( i + 1 ))
        [ "$i" -ge "$max" ] && break
        # Bash sleep takes seconds; convert ms.
        local secs="0.$(printf '%03d' "$sleep_ms")"
        sleep "$secs" 2>/dev/null || sleep 1
        continue
        ;;
      *)
        printf '%s\n' "$err" >&2
        return $rc
        ;;
    esac
  done
  printf '%s\n' "$err" >&2
  return $rc
}

# write_lock_and_exit <wt> <lock>
# Atomically write the lock file (mode 600) with PID + UTC timestamp,
# print the worktree path on stdout, and exit 0.
write_lock_and_exit() {
  local wt="$1" lock="$2"
  (umask 077; printf '%s %s\n' "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$lock")
  printf '%s\n' "$wt"
  exit 0
}

cmd_ensure() {
  local slug="${1:-}"
  if [ -z "$slug" ]; then
    echo "ensure: missing <slug>" >&2
    exit 64
  fi
  if [[ ! "$slug" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "ensure: invalid slug (only [A-Za-z0-9_-] allowed): $slug" >&2
    exit 64
  fi

  resolve_mroot
  local wt="$MROOT/.worktrees/$slug"
  local lock="$wt/.wt-lock"
  local branch="feat/$slug"

  if [ -f "$lock" ]; then
    # Parse: "<pid> <iso-timestamp>"; cap read at 256 bytes to bound input.
    local lock_pid lock_ts
    { read -r lock_pid lock_ts _ ; } < <(head -c 256 "$lock" 2>/dev/null) \
      || { lock_pid=""; lock_ts=""; }

    # Reject implausible PIDs (non-numeric, zero, or PID 1 which is always alive).
    if [[ ! "$lock_pid" =~ ^[1-9][0-9]*$ ]] || [ "$lock_pid" -le 1 ]; then
      lock_pid=""  # treat as stale
    fi

    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
      # Live collision — gather diagnostics
      local head_info="(unknown)"
      if [ -d "$wt/.git" ] || [ -f "$wt/.git" ]; then
        head_info=$(git -C "$wt" log -1 --format='%h %s' 2>/dev/null || echo "(unknown)")
      fi

      {
        echo "Worktree collision: $slug"
        echo "  branch:   $branch"
        echo "  HEAD:     $head_info"
        echo "  lock ts:  $lock_ts"
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
        write_lock_and_exit "$wt" "$lock"
      fi
      exit 2
    fi

    # Stale lock — silently overwrite
    write_lock_and_exit "$wt" "$lock"
  fi

  # No lock. If worktree dir exists, just create the lock.
  if [ -d "$wt" ]; then
    write_lock_and_exit "$wt" "$lock"
  fi

  mkdir -p "$MROOT/.worktrees"
  # Atomic: create branch + worktree in one git call when branch is absent,
  # so a worktree-add failure never leaves an orphan branch behind.
  if git -C "$MROOT" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null 2>&1; then
    git -C "$MROOT" worktree add "$wt" "$branch" >&2
  else
    git -C "$MROOT" worktree add -b "$branch" "$wt" >&2
  fi

  write_lock_and_exit "$wt" "$lock"
}

cmd_release() {
  local slug="${1:-}"
  if [ -z "$slug" ]; then
    echo "release: missing <slug>" >&2
    exit 64
  fi
  if [[ ! "$slug" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "release: invalid slug (only [A-Za-z0-9_-] allowed): $slug" >&2
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

  # Worktree remove + branch delete + config cleanup. Each git op is
  # retried on EBUSY (WSL2 race); they run as separate calls so the
  # second op doesn't fire while the first is still releasing
  # .git/config.
  local branch="feat/$slug"
  git_retry 3 200 -C "$MROOT" worktree remove "$wt" || \
    git_retry 3 200 -C "$MROOT" worktree remove --force "$wt"

  # Reap any leftover admin entries (handles partial-failure state).
  git_retry 3 200 -C "$MROOT" worktree prune || true

  # Delete the feature branch if it exists. -D since squash-merge
  # leaves the branch "not fully merged" by git's reachability check.
  if git -C "$MROOT" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null 2>&1; then
    git_retry 3 200 -C "$MROOT" branch -D "$branch" || true
  fi

  # If branch -D's config-section rewrite was the op that hit EBUSY,
  # the ref is gone but [branch "feat/X"] may linger in .git/config.
  # Sweep it explicitly — this is a no-op if the section is absent.
  git_retry 3 200 -C "$MROOT" config --remove-section "branch.$branch" 2>/dev/null || true

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
