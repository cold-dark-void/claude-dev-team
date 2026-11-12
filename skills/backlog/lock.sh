#!/usr/bin/env bash
# skills/backlog/lock.sh — advisory, age-gated lock for the shared backlog
# store (SPEC-009 Backlog write integrity, C2). SOURCE-ONLY — never run this
# file as a subprocess; the lock's traps and state must live in the caller's
# own shell.
#
#   SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
#   . "$SCRIPT_DIR/lock.sh"
#   backlog_lock_acquire "$ROOT" || exit $?
#   ... writes ...
#   # release happens automatically from the caller's EXIT/INT/TERM trap;
#   # backlog_lock_release may also be called directly (idempotent).
#
# Functions:
#   backlog_lock_acquire <root>   0 held | 1 busy | 64 bad env
#   backlog_lock_release          idempotent, always 0
#
# backlog_lock_acquire installs the EXIT/INT/TERM traps that call
# backlog_lock_release and REPLACES whatever traps the caller had for those
# three signals. A caller must not install its own EXIT/INT/TERM trap after
# calling backlog_lock_acquire — that would replace this trap and skip the
# lock release.
#
# Lock: "<root>/.claude/backlog.lock" (a directory — mkdir is the atomic
# test-and-set) holding one file "stamp": "<epoch> <ISO-8601-UTC> <owner>".
#
# Staleness is age-only: a stamp whose epoch field is >= BACKLOG_LOCK_TTL_SECONDS
# old is STALE and gets reclaimed. There is no PID-liveness check of any kind — the
# holder is a shell script, not a durably-checkable process (same posture as
# SPEC-016's .wt-lock). A missing/unparseable stamp gets one 1s grace re-read
# (another acquirer may be mid-mkdir) before it counts as stale too.
#
# BACKLOG_LOCK_WAIT_SECONDS (default 30, ^[0-9]+$) bounds how long
# backlog_lock_acquire waits on a FRESH (actively held) lock before returning 1.
# BACKLOG_LOCK_TTL_SECONDS (default 60, ^[1-9][0-9]*$) is the staleness age.
# Reclaiming a stale lock is not wait-gated — it always proceeds once detected.
# The WAIT deadline is still checked on every loop iteration regardless of why
# a given pass failed to acquire — including a failed reclaim attempt — so a
# lock directory that can never be reclaimed (e.g. a read-only ancestor) fails
# in bounded time instead of spinning forever.
#
# Concurrency posture (CDT-637 closes the widest window): the stamp is written
# under noclobber, so stamp creation is part of the mkdir test-and-set. A
# lock dir reclaimed between an acquirer's mkdir and its stamp write can no
# longer be stamped over — that acquirer retries, up to 3 times
# (_bl_stampfail), so two processes can no longer both hold; on persistent
# failure it gives up via an empty-dir-guarded rmdir (CDT-637).
# Residual windows (understates to
# "TOCTOU on one mv" if read narrowly — the actual worst case is two live
# holders, not just a failed mv): two processes can reclaim the SAME stale
# lock at the same time, each moving their own copy aside and re-mkdir'ing. If
# a THIRD process's acquire lands in the resulting hand-back window (the
# `mv <stale-copy> "$BACKLOG_LOCK_DIR"` that restores a copy that turned out
# to be fresh, per the reclaim-race check below), the copy of a live lock can
# be discarded and its holder keeps believing it holds. The age gate has the
# same effect for a holder that outlives BACKLOG_LOCK_TTL_SECONDS — stealing
# it is deliberate, a hung holder must not pin the lock forever. The worst
# case from those overlaps is ONE lost index update (a write from the loser
# gets clobbered by the winner's next
# write). This is bounded, not silent corruption: every file write still goes
# through `atomic_write` (dest is always fully-formed, never partially
# written), and the item file keeps its terminal status, and the next
# `/backlog reconcile` or re-close repairs the index; `close.sh verify`
# checks the item file only. Accepted: rare
# (needs a stale lock plus two racing reclaimers plus a third acquirer, all in
# a sub-second window), same advisory posture as SPEC-016 `.wt-lock`.
#
# Release only removes the lock when the stamp's owner field is ours
# (BACKLOG_LOCK_OWNER, a diagnostic "$$-$RANDOM$RANDOM" id — never used for
# staleness); a lock we do not own is left alone.

set -u

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  printf 'error: lock.sh is source-only — do ". lock.sh" from a caller script\n' >&2
  exit 64
fi

# _backlog_lock_read_epoch <lockdir>
# Prints the numeric epoch (field 1) from <lockdir>/stamp on stdout and
# returns 0, or prints nothing and returns 1 when the file is missing,
# unreadable, or field 1 does not match ^[0-9]+$. Errexit-safe: only ever
# called from an `if`/`||` context in this file.
_backlog_lock_read_epoch() {
  local _bl_dir="$1" _bl_epoch=""
  if [ -f "$_bl_dir/stamp" ]; then
    _bl_epoch=$(awk '{print $1; exit}' "$_bl_dir/stamp" 2>/dev/null)
  fi
  case "$_bl_epoch" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$_bl_epoch"
}

# _backlog_lock_read_owner <lockdir>
# Prints the owner field (field 3) from <lockdir>/stamp, or nothing.
_backlog_lock_read_owner() {
  local _bl_dir="$1"
  [ -f "$_bl_dir/stamp" ] || return 1
  awk '{print $3; exit}' "$_bl_dir/stamp" 2>/dev/null
}

# backlog_lock_acquire <root>
backlog_lock_acquire() {
  local _bl_root="$1" _bl_wait _bl_ttl

  _bl_wait="${BACKLOG_LOCK_WAIT_SECONDS:-30}"
  case "$_bl_wait" in
    ''|*[!0-9]*)
      printf 'error: invalid BACKLOG_LOCK_WAIT_SECONDS: %s\n' "$_bl_wait" >&2
      return 64
      ;;
  esac

  _bl_ttl="${BACKLOG_LOCK_TTL_SECONDS:-60}"
  if ! [[ "$_bl_ttl" =~ ^[1-9][0-9]*$ ]]; then
    printf 'error: invalid BACKLOG_LOCK_TTL_SECONDS: %s\n' "$_bl_ttl" >&2
    return 64
  fi

  BACKLOG_LOCK_DIR="$_bl_root/.claude/backlog.lock"
  BACKLOG_LOCK_OWNER="$$-$RANDOM$RANDOM"

  # Traps BEFORE the first mkdir, so any exit past this point releases a lock
  # we go on to hold (release is a no-op until the stamp's owner matches ours).
  trap backlog_lock_release EXIT
  trap 'backlog_lock_release; exit 130' INT
  trap 'backlog_lock_release; exit 143' TERM

  local _bl_start _bl_now _bl_epoch _bl_epoch2 _bl_status _bl_stampfail
  _bl_start=$(date +%s)
  _bl_stampfail=0

  while :; do
    if mkdir "$BACKLOG_LOCK_DIR" 2>/dev/null; then
      # The stamp write is part of the test-and-set: noclobber makes it fail
      # against an existing stamp (CDT-637). A stale reclaim can carry this
      # dir off between the mkdir and here, and a third acquirer can
      # re-create the path and stamp it first; a plain > would overwrite that
      # live holder's stamp and leave two processes holding one lock.
      if ! ( set -C; printf '%s %s %s\n' "$(date +%s)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BACKLOG_LOCK_OWNER" \
        > "$BACKLOG_LOCK_DIR/stamp" ) 2>/dev/null; then
        # Lost the stamp race, or the write failed outright. Retry the loop:
        # the path can name a LIVE holder's lock, so NEVER rm -rf it here.
        # The counter bounds the retries a persistent write error can cause
        # (a `continue` here skips the WAIT deadline check, same as a
        # completed reclaim).
        _bl_stampfail=$((_bl_stampfail + 1))
        if [ "$_bl_stampfail" -le 3 ]; then
          continue
        fi
        # Give up. rmdir (not rm -rf) is the guard: it succeeds only while
        # the dir is empty, so it can never carry off a stamped lock — a
        # stamped path belongs to the acquirer that won the stamp race.
        rmdir "$BACKLOG_LOCK_DIR" 2>/dev/null || :
        printf 'error: cannot write lock stamp: %s\n' "$BACKLOG_LOCK_DIR" >&2
        return 1
      fi
      return 0
    fi

    # mkdir failed. Either the lock dir genuinely exists (someone else holds
    # or held it — race the busy/deadline logic below) or it never can (a
    # read-only ancestor, a missing root, ...), which can never resolve by
    # waiting, so fail now instead of spinning to the WAIT deadline. Those two
    # are told apart by testing the PARENT for writability, not by re-testing
    # the lock dir itself: between our failed mkdir and this check, the dir
    # may already be gone (the holder's EXIT-trap `rm -rf`, or a stale-lock
    # reclaim/hand-back `mv`), so `[ ! -d "$BACKLOG_LOCK_DIR" ]` alone would
    # misread a plain EEXIST-then-released race as unrecoverable. Treat that
    # as `gone` instead: fall through to the existing busy/deadline check and
    # sleep below, then retry — mkdir will very likely succeed next pass.
    _bl_now=$(date +%s)
    if [ ! -d "$BACKLOG_LOCK_DIR" ]; then
      if [ ! -w "$_bl_root/.claude" ]; then
        printf 'error: cannot create backlog lock: %s\n' "$BACKLOG_LOCK_DIR" >&2
        return 1
      fi
      _bl_status=gone
    elif _bl_epoch=$(_backlog_lock_read_epoch "$BACKLOG_LOCK_DIR"); then
      _bl_status=fresh
      (( _bl_now - _bl_epoch < _bl_ttl )) || _bl_status=stale
    else
      # Missing/unparseable stamp: another acquirer may be mid-mkdir. Grace
      # re-read once before treating it as stale.
      sleep 1
      _bl_now=$(date +%s)
      if _bl_epoch=$(_backlog_lock_read_epoch "$BACKLOG_LOCK_DIR"); then
        _bl_status=fresh
        (( _bl_now - _bl_epoch < _bl_ttl )) || _bl_status=stale
      else
        _bl_status=stale
      fi
    fi

    if [ "$_bl_status" = stale ]; then
      # Never assume ownership of a stale lock: move it aside under our own
      # owner id first, then remove that renamed copy; only the retried
      # mkdir below actually claims the lock. `continue` (skip the WAIT
      # deadline check below) only when that hand-off actually happened — a
      # mv that fails (e.g. the lock's parent directory is read-only) must
      # still hit the deadline check and sleep, or a lock that can never be
      # reclaimed spins forever with no bound and no sleep.
      if mv "$BACKLOG_LOCK_DIR" "$BACKLOG_LOCK_DIR.stale.$BACKLOG_LOCK_OWNER" 2>/dev/null; then
        # Reclaim race: the copy we just moved aside may have gone fresh
        # between our stale read above and this mv — another acquirer's own
        # reclaim-and-remkdir may have landed at this same path first, so
        # what we actually just carried off is their brand-new lock, not the
        # stale one we read. Re-read the moved-aside copy before discarding
        # it; if it is fresh, hand it back instead of destroying a live lock.
        if _bl_epoch2=$(_backlog_lock_read_epoch "$BACKLOG_LOCK_DIR.stale.$BACKLOG_LOCK_OWNER") \
           && (( $(date +%s) - _bl_epoch2 < _bl_ttl )); then
          if [ ! -e "$BACKLOG_LOCK_DIR" ]; then
            mv "$BACKLOG_LOCK_DIR.stale.$BACKLOG_LOCK_OWNER" "$BACKLOG_LOCK_DIR" 2>/dev/null \
              || rm -rf "$BACKLOG_LOCK_DIR.stale.$BACKLOG_LOCK_OWNER" 2>/dev/null
          else
            rm -rf "$BACKLOG_LOCK_DIR.stale.$BACKLOG_LOCK_OWNER" 2>/dev/null
          fi
          # Still contended either way: fall through to the WAIT deadline.
        else
          rm -rf "$BACKLOG_LOCK_DIR.stale.$BACKLOG_LOCK_OWNER" 2>/dev/null
          continue
        fi
      fi
    fi

    _bl_now=$(date +%s)
    if (( _bl_now - _bl_start >= _bl_wait )); then
      printf 'error: backlog lock busy: %s (waited %ds)\n' "$BACKLOG_LOCK_DIR" "$(( _bl_now - _bl_start ))" >&2
      return 1
    fi
    sleep 0.2
  done
}

# backlog_lock_release — idempotent; always returns 0.
backlog_lock_release() {
  local _bl_owner
  if [ -n "${BACKLOG_LOCK_DIR:-}" ]; then
    _bl_owner=$(_backlog_lock_read_owner "$BACKLOG_LOCK_DIR" 2>/dev/null) || _bl_owner=""
    if [ -n "$_bl_owner" ] && [ "$_bl_owner" = "${BACKLOG_LOCK_OWNER:-}" ]; then
      rm -rf "$BACKLOG_LOCK_DIR" 2>/dev/null
    fi
  fi
  unset BACKLOG_LOCK_DIR
  return 0
}
