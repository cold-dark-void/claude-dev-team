#!/usr/bin/env bash
# worktree-lib.sh — manage per-task git worktrees with advisory, age-gated locks.
#
# Subcommands:
#   ensure <slug>            create-or-reuse worktree at $MROOT/.worktrees/<slug>
#   release [--preview] <slug>
#                            remove lock + worktree if clean; delete feat/<slug>
#                            only when git-safety.sh says it is merged (kept
#                            otherwise, exit 0); --preview is read-only (WP 1-06)
#   status | list            enumerate $MROOT/.worktrees/* (lock FRESH|STALE|NONE)
#   register <slug>          stamp .wt-lock only (dir must already exist)
#   sweep                    propose STALE worktrees with no live task (never delete)
#   gc --stale               remove STALE .wt-lock files (doctor --fix path; the
#                            FRESH/STALE TTL lives only here — rv-w3-39)
#
# The real holder of a worktree is an LLM agent/conversation, not an OS process
# with a checkable PID, so the lock is ADVISORY and keyed on AGE: a lock younger
# than WT_LOCK_TTL_SECONDS is FRESH (prompt before reuse); older (or unparseable)
# is STALE. ensure reclaims STALE only when the tree is clean (release porcelain)
# and no live task references the slug; otherwise refuses with exit 1. sweep
# proposes STALE worktrees with no live task (never deletes). ensure also refuses
# an existing $MROOT/.worktrees/<slug> directory that is not itself a git
# worktree (no-lock path only; WP 1-06, SPEC-016).
#
# release never adds a force flag when it removes a worktree (WP 1-06):
# a failed remove exits 1 and keeps the directory, the branch and its
# config unchanged. It also never deletes a branch through git's own
# delete subcommand: the only branch-delete path is
# skills/lib/git-safety.sh safe-delete-branch, gated on resolve-base +
# is-merged. An unmerged (or base-less) branch is kept, with a stderr
# note, and release still exits 0 -- callers that do `release || exit 1`
# are unaffected by a kept branch.
#
# Stdout discipline: ensure/register print ONLY the absolute worktree path on
# success. status/list print listing rows. sweep prints PROPOSAL lines (or
# nothing). release --preview prints exactly eight `key: value` lines and
# changes nothing (SPEC-016 section release). All other diagnostics go to
# stderr. ensure/register stdout is empty on any non-zero exit.

set -euo pipefail

# Lock time-to-live: a lock younger than this is treated as FRESH (held by an
# active agent); older is STALE (reclaimable when clean + no live task).
# Env-overridable; falls back to 6h on a non-numeric value.
WT_LOCK_TTL_SECONDS="${WT_LOCK_TTL_SECONDS:-21600}"
[[ "$WT_LOCK_TTL_SECONDS" =~ ^[0-9]+$ ]] || WT_LOCK_TTL_SECONDS=21600

# Shared base-resolution / merge-check primitive (SPEC-025 M17). Subprocess
# only -- never sourced. release and release --preview are its only
# consumers here (C3).
GIT_SAFETY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/git-safety.sh"

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

# is_worktree_dirty <wt>
# exit 0 if porcelain dirty after excluding .wt-lock; 1 if clean.
# Shared by release and ensure STALE reclaim (filter must not drift).
is_worktree_dirty() {
  local wt="$1" dirty
  # Filter out .wt-lock — bookkeeping, not user content.
  # Porcelain format: "XY <path>" — strip the lock entry by exact-path match.
  dirty=$(git -C "$wt" status --porcelain 2>/dev/null | awk '$0 !~ /^.. \.wt-lock$/' || true)
  [ -n "$dirty" ]
}

# is_git_worktree <wt>
# exit 0 if <wt> is itself a git worktree (its own toplevel resolves to <wt>,
# not to some ancestor such as $MROOT). Used only by ensure's no-lock +
# existing-directory branch (WP 1-06, SPEC-016): the exit code of a bare
# `git -C <wt> rev-parse ...` is not enough for a plain directory under
# $MROOT/.worktrees/, because git walks up and finds $MROOT.
is_git_worktree() {
  local wt="$1" top top_real wt_real
  [ -e "$wt/.git" ] || return 1
  top=$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null) || return 1
  top_real=$(cd "$top" 2>/dev/null && pwd -P) || return 1
  wt_real=$(cd "$wt" 2>/dev/null && pwd -P) || return 1
  [ "$top_real" = "$wt_real" ]
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

    # STALE lock (age >= TTL, or unparseable/legacy format) — reclaim only
    # when clean and no live task (CDT-162). Dirty first so operators see
    # uncommitted work when both guards would apply.
    if is_worktree_dirty "$wt"; then
      echo "ensure: uncommitted changes in $wt — refusing STALE reclaim" >&2
      exit 1
    fi
    if slug_has_live_task "$slug"; then
      echo "ensure: live task references $slug — refusing STALE reclaim" >&2
      exit 1
    fi
    if [ "$age" -ge 0 ]; then
      echo "stale lock (age $(( age / 3600 ))h >= $(( WT_LOCK_TTL_SECONDS / 3600 ))h TTL) — reclaiming" >&2
    else
      echo "stale lock (unparseable / legacy format) — reclaiming" >&2
    fi
    write_lock_and_exit "$wt" "$lock"
  fi

  # No lock. If the worktree dir exists, it must be a real git worktree
  # before ensure stamps a lock on it (WP 1-06, SPEC-016). A bare
  # `git -C <wt> rev-parse` exit code is not enough here: for a plain
  # directory under $MROOT/.worktrees/, git walks up and finds $MROOT.
  if [ -d "$wt" ]; then
    if ! is_git_worktree "$wt"; then
      echo "ensure: $wt exists but is not a git worktree" >&2
      exit 1
    fi
    write_lock_and_exit "$wt" "$lock"
  fi

  mkdir -p "$MROOT/.worktrees"
  # Atomic preference: -b when branch absent. Both arms via git_retry 3 200
  # (CDT-161). Re-probe after failed -b so sticky -b is never used once the
  # branch exists (partial add can create the ref then EBUSY on config).
  if git -C "$MROOT" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null 2>&1; then
    git_retry 3 200 -C "$MROOT" worktree add "$wt" "$branch"
  else
    local _add_rc=0
    git_retry 3 200 -C "$MROOT" worktree add -b "$branch" "$wt" || _add_rc=$?
    if [ "$_add_rc" -ne 0 ]; then
      if git -C "$MROOT" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null 2>&1 \
         && [ ! -e "$wt" ]; then
        git_retry 3 200 -C "$MROOT" worktree add "$wt" "$branch" || exit $?
      else
        exit "$_add_rc"
      fi
    fi
  fi

  write_lock_and_exit "$wt" "$lock"
}

# count_or_q <rev-list args...>
# git rev-list --count with the given args, each a separate positional
# argument (a caller-built "A..B" range is one such argument). Prints "?"
# on any git error or a non-numeric result (release --preview count
# fields; SPEC-016 section release says a failed count prints "?").
count_or_q() {
  local out rc=0
  out=$(git -C "$MROOT" rev-list --count "$@" 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ] || ! [[ "$out" =~ ^[0-9]+$ ]]; then
    printf '?'
  else
    printf '%s' "$out"
  fi
}

# cmd_release_preview <branch>
# Read-only eight-line report for `release --preview` (SPEC-016 section
# release, WP 1-06). Never removes the lock, the worktree, the branch or
# the config section, and does not need the worktree directory to exist.
cmd_release_preview() {
  local branch="$1"
  local branch_disp base ahead_base upstream ahead_up merged pushed confirm

  local base_val="" base_rc=0
  base_val=$(bash "$GIT_SAFETY" -C "$MROOT" resolve-base 2>/dev/null) || base_rc=$?
  if [ "$base_rc" -eq 0 ] && [ -n "$base_val" ]; then
    base="$base_val"
  else
    base="none"
  fi

  if ! git -C "$MROOT" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null 2>&1; then
    # Branch absent: counts are 0, merged/pushed are no, confirm is yesno.
    # base still reports whatever resolve-base found (independent of the
    # feat/<slug> branch's existence).
    branch_disp="none"
    ahead_base=0
    upstream="none"
    ahead_up=0
    merged="no"
    pushed="no"
    confirm="yesno"
  else
    branch_disp="$branch"

    if [ "$base" != "none" ]; then
      ahead_base=$(count_or_q "$base..$branch")
    else
      ahead_base=$(count_or_q "$branch")
    fi

    local up_rc=0
    upstream=$(git -C "$MROOT" rev-parse --abbrev-ref "${branch}@{upstream}" 2>/dev/null) || up_rc=$?
    if [ "$up_rc" -ne 0 ] || [ -z "$upstream" ]; then
      upstream="none"
      ahead_up=$(count_or_q "$branch" --not --remotes)
    else
      ahead_up=$(count_or_q "${branch}@{upstream}..${branch}")
    fi

    merged="no"
    if [ "$base" != "none" ] \
       && bash "$GIT_SAFETY" -C "$MROOT" is-merged "refs/heads/$branch" "$base" >/dev/null 2>&1; then
      merged="yes"
    fi

    pushed="no"
    if bash "$GIT_SAFETY" -C "$MROOT" is-pushed "$branch" >/dev/null 2>&1; then
      pushed="yes"
    fi

    confirm="yesno"
    [ "$merged" = "no" ] && confirm="slug"
  fi

  printf 'branch: %s\n' "$branch_disp"
  printf 'base: %s\n' "$base"
  printf 'ahead_of_base: %s\n' "$ahead_base"
  printf 'upstream: %s\n' "$upstream"
  printf 'ahead_of_upstream: %s\n' "$ahead_up"
  printf 'merged: %s\n' "$merged"
  printf 'pushed: %s\n' "$pushed"
  printf 'confirm: %s\n' "$confirm"
}

cmd_release() {
  local preview=0
  if [ "${1:-}" = "--preview" ]; then
    preview=1
    shift
  fi
  local slug="${1:-}"
  validate_slug "release" "$slug"
  shift || true
  if [ "$#" -gt 0 ]; then
    # WP 1-06 review L1: a flag after the slug (e.g. `release <slug>
    # --preview`) must not silently fall through to a real, destructive
    # release. Reject any extra argument.
    echo "release: unexpected argument: $1" >&2
    exit 64
  fi

  resolve_mroot
  local wt="$MROOT/.worktrees/$slug"
  local branch="feat/$slug"

  if [ "$preview" -eq 1 ]; then
    cmd_release_preview "$branch"
    exit 0
  fi

  if [ ! -d "$wt" ]; then
    echo "release: worktree not found: $wt" >&2
    exit 1
  fi

  if is_worktree_dirty "$wt"; then
    echo "release: uncommitted changes in $wt — refusing to remove" >&2
    exit 1
  fi

  rm -f "$wt/.wt-lock"

  # Worktree remove -- no fallback that adds a force flag (WP 1-06,
  # CDT-298). Re-running the dirty check above does not make a forced
  # remove safe: a file can change between the check and this call, or
  # the tree can be locked. On failure the directory, the branch and its
  # config section all stay.
  if ! git_retry 3 200 -C "$MROOT" worktree remove "$wt"; then
    echo "release: git worktree remove failed for $wt — not forcing" >&2
    exit 1
  fi

  # Reap any leftover admin entries (handles partial-failure state).
  git_retry 3 200 -C "$MROOT" worktree prune || true

  # Branch delete (WP 1-06): the only path is git-safety.sh
  # safe-delete-branch, gated on the shared base resolver and is-merged.
  # An unmerged branch (or one with no resolvable base) is kept, with a
  # stderr note; release still exits 0 for a kept branch — callers that
  # run `release || exit 1` are unaffected.
  if git -C "$MROOT" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null 2>&1; then
    local base="" base_rc=0
    base=$(bash "$GIT_SAFETY" -C "$MROOT" resolve-base 2>/dev/null) || base_rc=$?
    if [ "$base_rc" -eq 0 ] && [ -n "$base" ]; then
      # git-safety.sh safe-delete-branch swallows git's own stderr, so a
      # WSL2 EBUSY-class .git/config race on its internal delete step is
      # indistinguishable here from a genuine "not merged" refusal
      # (review L2). Retry the call a bounded number of times before
      # settling; a truly unmerged branch just re-fails cheaply each time.
      local del_rc=0 attempt=0
      while :; do
        del_rc=0
        bash "$GIT_SAFETY" -C "$MROOT" safe-delete-branch "$branch" "$base" || del_rc=$?
        [ "$del_rc" -eq 0 ] && break
        attempt=$((attempt + 1))
        [ "$attempt" -ge 3 ] && break
        sleep 0.2 2>/dev/null || sleep 1
      done
      if git -C "$MROOT" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null 2>&1; then
        # Ref still present: safe-delete-branch genuinely refused (no
        # base, or unmerged) even after retrying.
        echo "release: kept $branch: not merged into $base" >&2
      else
        # Ref is gone even though the last attempt reported non-zero: a
        # config-section rewrite inside that delete step can itself hit
        # EBUSY after the ref delete already landed (review L2). Sweep
        # the leftover section unconditionally, regardless of del_rc.
        git_retry 3 200 -C "$MROOT" config --remove-section "branch.$branch" 2>/dev/null || true
      fi
    else
      echo "release: kept $branch: no base" >&2
    fi
  fi

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

cmd_gc() {
  # Remove STALE .wt-lock files. Staleness is decided by read_lock_state — the
  # single TTL implementation in this lib (rv-w3-39). Nothing is deleted but
  # the lock file; the worktree directory and branch are untouched. Stdout
  # stays empty (diagnostics to stderr), like ensure/register.
  resolve_mroot
  local base="$MROOT/.worktrees"
  [ -d "$base" ] || exit 0
  local d slug lock removed=0
  for d in "$base"/*; do
    [ -d "$d" ] || continue
    slug=$(basename "$d")
    lock="$d/.wt-lock"
    [ -f "$lock" ] || continue
    read_lock_state "$lock"
    if [ "$LOCK_STATE" = "STALE" ]; then
      rm -f "$lock"
      printf 'gc --stale: removed %s (worktree %s kept)\n' "$lock" "$slug" >&2
      removed=$((removed + 1))
    fi
  done
  printf 'gc --stale: removed %d stale lock(s)\n' "$removed" >&2
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
    gc)       cmd_gc "$@" ;;
    *)
      echo "usage: worktree-lib.sh {ensure|release [--preview]|status|list|register|sweep|gc --stale} [slug]" >&2
      exit 64
      ;;
  esac
}

main "$@"
