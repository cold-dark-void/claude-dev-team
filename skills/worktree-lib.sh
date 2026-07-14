#!/usr/bin/env bash
# worktree-lib.sh — manage per-task git worktrees with advisory, age-gated locks.
#
# Subcommands:
#   ensure <slug>     create-or-reuse worktree at $MROOT/.worktrees/<slug>
#   release <slug>    remove lock + worktree if clean
#   status | list     enumerate $MROOT/.worktrees/* (lock FRESH|STALE|NONE)
#   register <slug>   stamp .wt-lock only (dir must already exist)
#   sweep             propose STALE worktrees with no live task (never delete)
#
# The real holder of a worktree is an LLM agent/conversation, not an OS process
# with a checkable PID, so the lock is ADVISORY and keyed on AGE: a lock younger
# than WT_LOCK_TTL_SECONDS is FRESH (prompt before reuse); older (or unparseable)
# is STALE (silently reclaimed on ensure; proposed on sweep).
#
# Stdout discipline: ensure/register print ONLY the absolute worktree path on
# success. status/list print listing rows. sweep prints PROPOSAL lines (or nothing).
# All diagnostics go to stderr. ensure/register stdout is empty on any non-zero exit.

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

# write_lock <lock>
# Atomically write the lock file (mode 600) as one line:
#   <EPOCH_SECONDS> <ISO_8601_UTC>
write_lock() {
  local lock="$1"
  (umask 077; printf '%s %s\n' "$(date +%s)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$lock")
}

# write_lock_and_exit <wt> <lock>
# Write lock, print worktree path on stdout, exit 0.
write_lock_and_exit() {
  local wt="$1" lock="$2"
  write_lock "$lock"
  printf '%s\n' "$wt"
  exit 0
}

# read_lock_state <lock_path>
# Sets: LOCK_EPOCH LOCK_ISO LOCK_AGE LOCK_FRESH LOCK_STATE
# LOCK_STATE = FRESH | STALE | NONE
# LOCK_AGE = seconds since stamp, or -1 if none/unparseable/future-handled separately
read_lock_state() {
  local lock="$1"
  LOCK_EPOCH=""
  LOCK_ISO=""
  LOCK_AGE=-1
  LOCK_FRESH=0
  LOCK_STATE=NONE

  [ -f "$lock" ] || return 0

  { read -r LOCK_EPOCH LOCK_ISO _ ; } < <(head -c 256 "$lock" 2>/dev/null) \
    || { LOCK_EPOCH=""; LOCK_ISO=""; }

  # Decide FRESH vs STALE by age. A non-numeric field 1 (corrupt, or a legacy
  # "PID TS" lock) is unparseable → STALE. A negative age (future stamp / clock
  # skew) is conservatively treated as FRESH (prompt, don't auto-clobber).
  if [[ "$LOCK_EPOCH" =~ ^[0-9]+$ ]]; then
    local now
    now=$(date +%s)
    LOCK_AGE=$(( now - LOCK_EPOCH ))
    if [ "$LOCK_AGE" -lt 0 ]; then
      LOCK_FRESH=1
      LOCK_STATE=FRESH
    elif [ "$LOCK_AGE" -lt "$WT_LOCK_TTL_SECONDS" ]; then
      LOCK_FRESH=1
      LOCK_STATE=FRESH
    else
      LOCK_STATE=STALE
    fi
  else
    LOCK_STATE=STALE
    LOCK_AGE=-1
  fi
}

# format_age_human <age_seconds>
# Compact age for status rows. age < 0 → unknown (unparseable) or caller override.
format_age_human() {
  local age="$1"
  if [ "$age" -lt 0 ]; then
    printf '%s' "unknown"
  elif [ "$age" -lt 60 ]; then
    printf '%ss' "$age"
  elif [ "$age" -lt 3600 ]; then
    printf '%sm' "$(( age / 60 ))"
  else
    printf '%sh%sm' "$(( age / 3600 ))" "$(( (age % 3600) / 60 ))"
  fi
}

# format_age_human_held <age_seconds>
# ensure collision summary style ("held Xm ago").
format_age_human_held() {
  local age="$1"
  if [ "$age" -lt 0 ]; then
    printf '%s' "future timestamp (clock skew)"
  elif [ "$age" -lt 3600 ]; then
    printf 'held %sm ago' "$(( age / 60 ))"
  else
    printf 'held %sh%sm ago' "$(( age / 3600 ))" "$(( (age % 3600) / 60 ))"
  fi
}

# slug_has_live_task <slug>
# True if $MROOT/.claude/tasks/*.json has status pending|in_progress|blocked
# and references slug via task_id (filename) or word-boundary content match.
slug_has_live_task() {
  local slug="$1"
  local tasks_dir="$MROOT/.claude/tasks"
  [ -d "$tasks_dir" ] || return 1

  local f base
  # nullglob-safe: literal glob fails [ -f ]
  for f in "$tasks_dir"/*.json; do
    [ -f "$f" ] || continue
    if ! grep -qE '"status"[[:space:]]*:[[:space:]]*"(pending|in_progress|blocked)"' "$f" 2>/dev/null; then
      continue
    fi
    base=$(basename "$f" .json)
    if [ "$base" = "$slug" ]; then
      return 0
    fi
    # Anchor like wrap-ticket: word-boundary, avoid WISO-1 matching WISO-10
    if grep -qwF -- "$slug" "$f" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

# validate_slug <cmd> <slug>
validate_slug() {
  local cmd="$1" slug="$2"
  if [ -z "$slug" ]; then
    echo "$cmd: missing <slug>" >&2
    exit 64
  fi
  if [[ ! "$slug" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "$cmd: invalid slug (only [A-Za-z0-9_-] allowed): $slug" >&2
    exit 64
  fi
}

cmd_ensure() {
  local slug="${1:-}"
  validate_slug "ensure" "$slug"

  resolve_mroot
  local wt="$MROOT/.worktrees/$slug"
  local lock="$wt/.wt-lock"
  local branch="feat/$slug"

  if [ -f "$lock" ]; then
    read_lock_state "$lock"
    local fresh="$LOCK_FRESH" age="$LOCK_AGE" lock_iso="$LOCK_ISO"

    if [ "$fresh" -eq 1 ]; then
      # FRESH lock — likely held by an active agent. Gather diagnostics.
      local head_info="(unknown)"
      if [ -d "$wt/.git" ] || [ -f "$wt/.git" ]; then
        head_info=$(git -C "$wt" log -1 --format='%h %s' 2>/dev/null || echo "(unknown)")
      fi

      local age_human
      age_human=$(format_age_human_held "$age")

      {
        echo "Worktree collision: $slug"
        echo "  branch:   $branch"
        echo "  HEAD:     $head_info"
        echo "  lock age:  $age_human (lock ts: ${lock_iso:-unknown})"
      } >&2

      local answer=""
      # Probe TTY by successful write, not mere -r: access() can succeed while
      # open fails ENXIO when there is no controlling terminal (agent/setsid).
      # Under set -e the failed open must not kill the script — gate via if.
      # Redirect order matters: 2>/dev/null BEFORE >/dev/tty so a failed open
      # does not leak "No such device" (bash processes redirections L→R).
      if printf "[abort/steal] " 2>/dev/null >/dev/tty; then
        IFS= read -r answer </dev/tty 2>/dev/null || answer=""
      else
        printf "[abort/steal] " >&2
        # No writable controlling TTY → empty answer → abort (exit 2)
        answer=""
      fi

      # Steal only on explicit "steal"; anything else (empty, abort, garbage) → exit 2
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
  validate_slug "release" "$slug"

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

# status row: slug | branch | FRESH|STALE|NONE | age | HEAD
cmd_status() {
  resolve_mroot
  local base="$MROOT/.worktrees"
  if [ ! -d "$base" ]; then
    exit 0
  fi

  local d slug lock branch head_info age_h
  # Sort for stable output
  local -a slugs=()
  for d in "$base"/*; do
    [ -d "$d" ] || continue
    slugs+=("$(basename "$d")")
  done

  if [ "${#slugs[@]}" -eq 0 ]; then
    exit 0
  fi

  # bash sort via printf | sort
  local sorted
  sorted=$(printf '%s\n' "${slugs[@]}" | LC_ALL=C sort)

  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    d="$base/$slug"
    lock="$d/.wt-lock"
    read_lock_state "$lock"

    # Only query git when this dir is a real checkout — otherwise git -C walks
    # up to MROOT and reports the main branch (wrong for bare fixture dirs).
    branch="feat/$slug"
    head_info="(unknown)"
    if [ -d "$d/.git" ] || [ -f "$d/.git" ]; then
      local br
      br=$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
      if [ -n "$br" ] && [ "$br" != "HEAD" ]; then
        branch="$br"
      fi
      head_info=$(git -C "$d" log -1 --format='%h %s' 2>/dev/null || echo "(unknown)")
    fi

    if [ "$LOCK_STATE" = "NONE" ]; then
      age_h="-"
    elif [ "$LOCK_AGE" -lt 0 ] && [ "$LOCK_STATE" = "FRESH" ]; then
      age_h="future"
    else
      age_h=$(format_age_human "$LOCK_AGE")
    fi

    printf '%s | %s | %s | %s | %s\n' "$slug" "$branch" "$LOCK_STATE" "$age_h" "$head_info"
  done <<< "$sorted"

  exit 0
}

cmd_list() {
  cmd_status "$@"
}

cmd_register() {
  local slug="${1:-}"
  validate_slug "register" "$slug"

  resolve_mroot
  local wt="$MROOT/.worktrees/$slug"
  local lock="$wt/.wt-lock"

  if [ ! -d "$wt" ]; then
    echo "register: worktree not found: $wt" >&2
    exit 1
  fi

  write_lock "$lock"
  printf '%s\n' "$wt"
  exit 0
}

cmd_sweep() {
  resolve_mroot
  local base="$MROOT/.worktrees"
  if [ ! -d "$base" ]; then
    exit 0
  fi

  local d slug lock
  local -a slugs=()
  for d in "$base"/*; do
    [ -d "$d" ] || continue
    slugs+=("$(basename "$d")")
  done

  if [ "${#slugs[@]}" -eq 0 ]; then
    exit 0
  fi

  local sorted
  sorted=$(printf '%s\n' "${slugs[@]}" | LC_ALL=C sort)

  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    d="$base/$slug"
    lock="$d/.wt-lock"
    read_lock_state "$lock"
    [ "$LOCK_STATE" = "STALE" ] || continue
    if slug_has_live_task "$slug"; then
      continue
    fi
    # Clearly labeled proposals — never delete
    printf 'PROPOSAL %s lock=STALE age=%s no-live-task (consider: worktree-lib.sh release %s)\n' \
      "$slug" "$(format_age_human "$LOCK_AGE")" "$slug"
  done <<< "$sorted"

  exit 0
}

main() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    ensure)   cmd_ensure "$@" ;;
    release)  cmd_release "$@" ;;
    status)   cmd_status "$@" ;;
    list)     cmd_list "$@" ;;
    register) cmd_register "$@" ;;
    sweep)    cmd_sweep "$@" ;;
    *)
      echo "usage: worktree-lib.sh {ensure|release|status|list|register|sweep} [slug]" >&2
      exit 64
      ;;
  esac
}

main "$@"
