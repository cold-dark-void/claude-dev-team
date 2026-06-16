#!/usr/bin/env bash
# worktree-lib.sh — manage per-task git worktrees with advisory, age-gated locks.
#
# Subcommands:
#   ensure <slug>   create-or-reuse worktree at $MROOT/.worktrees/<slug>
#   release <slug>  remove lock + worktree if clean
#
# The real holder of a worktree is an LLM agent/conversation, not an OS process
# with a checkable PID, so the lock is ADVISORY and keyed on AGE: a lock younger
# than WT_LOCK_TTL_SECONDS is FRESH (prompt before reuse); older (or unparseable)
# is STALE (silently reclaimed).
#
# Stdout discipline: ensure prints ONLY the absolute worktree path on success.
# All diagnostics go to stderr. Stdout is empty on any non-zero exit.

set -euo pipefail

# Lock time-to-live: a lock younger than this is treated as FRESH (held by an
# active agent); older is STALE and silently reclaimed. Env-overridable; falls
# back to 6h on a non-numeric value.
WT_LOCK_TTL_SECONDS="${WT_LOCK_TTL_SECONDS:-21600}"
[[ "$WT_LOCK_TTL_SECONDS" =~ ^[0-9]+$ ]] || WT_LOCK_TTL_SECONDS=21600

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
# Atomically write the lock file (mode 600) as one line:
#   <EPOCH_SECONDS> <ISO_8601_UTC>
# Field 1 (epoch) is authoritative for age; field 2 (ISO) is human-readable only.
# Print the worktree path on stdout, and exit 0.
write_lock_and_exit() {
  local wt="$1" lock="$2"
  (umask 077; printf '%s %s\n' "$(date +%s)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$lock")
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
    # Parse: "<epoch-seconds> <iso-timestamp>"; cap read at 256 bytes to bound
    # input. Field 1 (epoch) is authoritative for age.
    local lock_epoch lock_iso
    { read -r lock_epoch lock_iso _ ; } < <(head -c 256 "$lock" 2>/dev/null) \
      || { lock_epoch=""; lock_iso=""; }

    # Decide FRESH vs STALE by age. A non-numeric field 1 (corrupt, or a legacy
    # "PID TS" lock) is unparseable → STALE. A negative age (future stamp / clock
    # skew) is conservatively treated as FRESH (prompt, don't auto-clobber).
    local fresh=0 age=-1
    if [[ "$lock_epoch" =~ ^[0-9]+$ ]]; then
      local now; now=$(date +%s)
      age=$(( now - lock_epoch ))
      if [ "$age" -lt 0 ]; then
        fresh=1
      elif [ "$age" -lt "$WT_LOCK_TTL_SECONDS" ]; then
        fresh=1
      fi
    fi

    if [ "$fresh" -eq 1 ]; then
      # FRESH lock — likely held by an active agent. Gather diagnostics.
      local head_info="(unknown)"
      if [ -d "$wt/.git" ] || [ -f "$wt/.git" ]; then
        head_info=$(git -C "$wt" log -1 --format='%h %s' 2>/dev/null || echo "(unknown)")
      fi

      # Human-readable age summary.
      local age_human
      if [ "$age" -lt 0 ]; then
        age_human="future timestamp (clock skew)"
      elif [ "$age" -lt 3600 ]; then
        age_human="held $(( age / 60 ))m ago"
      else
        age_human="held $(( age / 3600 ))h$(( (age % 3600) / 60 ))m ago"
      fi

      {
        echo "Worktree collision: $slug"
        echo "  branch:   $branch"
        echo "  HEAD:     $head_info"
        echo "  lock age:  $age_human (lock ts: ${lock_iso:-unknown})"
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

    # STALE lock (age >= TTL, or unparseable/legacy format) — reclaim it.
    if [ "$age" -ge 0 ]; then
      echo "stale lock (age $(( age / 3600 ))h >= $(( WT_LOCK_TTL_SECONDS / 3600 ))h TTL) — reclaiming" >&2
    else
      echo "stale lock (unparseable / legacy format) — reclaiming" >&2
    fi
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
