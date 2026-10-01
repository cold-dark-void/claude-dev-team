#!/usr/bin/env bash
# scheduled-lock.sh — concurrency lock for scheduled /retro --all --auto (CDV-190).
#
# Usage:
#   scheduled-lock.sh acquire <mroot>          # stdout: owner token; exit 0 acquired; 2 held; 1 error
#   scheduled-lock.sh release <mroot> <token>  # exit 0; deletes the lock only when <token> matches
#
# Lock path: $MROOT/.claude/retro/scheduled.lock
# Content: pid\nts_epoch\ntoken\n
# TTL: 7200s (2h) — stale locks are stolen by rename, then exclusive create.
#
# Acquire writes a complete temp file, then publishes it with link(2). The
# published path is never an empty file another acquire could treat as stale
# (CDT-344). Release renames the lock aside and deletes that inode only when
# its token matches, so it cannot unlink a lock a stealer installed in between.
# A later fence is a new process, so the owner is the token, not the releasing
# pid (CDT-324). The pid is still recorded on line 1.
# A missing lock is fail-open (exit 0, nothing to delete). A wrong token or a
# missing token leaves a live lock in place and still exits 0.
set -u

TTL_SEC=7200

usage() {
  echo "usage: scheduled-lock.sh acquire <mroot>" >&2
  echo "       scheduled-lock.sh release <mroot> <token>" >&2
  exit 1
}

[ $# -ge 2 ] || usage
CMD=$1
MROOT=$2
[ -n "$MROOT" ] || usage

RETRO_DIR="$MROOT/.claude/retro"
LOCK="$RETRO_DIR/scheduled.lock"

# fresh_ts <ts> — 0 when missing, non-numeric, or older than TTL
fresh_ts() {
  _ts=$1
  case "$_ts" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$_ts" -gt 0 ] || return 1
  _age=$((NOW - _ts))
  [ "$_age" -lt "$TTL_SEC" ]
}

# install_lock — publish a complete lock file. 0 when this process owns it.
# link(2) fails if LOCK already exists, so two acquirers cannot both publish.
install_lock() {
  # link(2) publishes this complete file. The live path is never empty.
  _tmp=$(mktemp "${RETRO_DIR}/scheduled.lock.XXXXXX") || return 1
  if ! printf '%s\n%s\n%s\n' "$$" "$NOW" "$TOKEN" > "$_tmp"; then
    rm -f "$_tmp"
    return 1
  fi
  if ln "$_tmp" "$LOCK" 2>/dev/null; then
    rm -f "$_tmp"
    return 0
  fi
  rm -f "$_tmp"
  return 1
}

# restore_displaced <path> — put a renamed lock back when the live path is free.
# Never delete a fresh lock. A displaced stale file is removed only after a
# newer lock is already published at LOCK.
restore_displaced() {
  _old=$1
  _stale=$2
  if [ ! -e "$LOCK" ]; then
    mv "$_old" "$LOCK" 2>/dev/null || return 0
    return 0
  fi
  if [ "$_stale" = "1" ]; then
    rm -f "$_old"
  fi
}

held() {
  echo "scheduled retro: lock held, skipping" >&2
  exit 2
}

case "$CMD" in
  acquire)
    mkdir -p "$RETRO_DIR" || {
      echo "scheduled-lock: cannot create $RETRO_DIR" >&2
      exit 1
    }
    NOW=$(date +%s)
    TOKEN=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || true)
    if [ -z "$TOKEN" ]; then
      TOKEN="$$-$NOW"
    fi
    if install_lock; then
      printf '%s\n' "$TOKEN"
      exit 0
    fi
    lock_ts=$(sed -n '2p' "$LOCK" 2>/dev/null || true)
    if fresh_ts "$lock_ts"; then
      held
    fi
    # Stale or corrupt. Rename it aside so only one stealer creates the new file.
    OLD="$LOCK.stale.$$"
    if mv "$LOCK" "$OLD" 2>/dev/null; then
      old_ts=$(sed -n '2p' "$OLD" 2>/dev/null || true)
      if fresh_ts "$old_ts"; then
        restore_displaced "$OLD" 0
        held
      fi
      if install_lock; then
        rm -f "$OLD"
        printf '%s\n' "$TOKEN"
        exit 0
      fi
      restore_displaced "$OLD" 1
      held
    fi
    # Lost the rename. If the path is free, one more exclusive create; else it is held.
    if [ ! -e "$LOCK" ] && install_lock; then
      printf '%s\n' "$TOKEN"
      exit 0
    fi
    held
    ;;
  release)
    TOKEN_ARG=${3:-}
    if [ ! -f "$LOCK" ]; then
      exit 0
    fi
    if [ -z "$TOKEN_ARG" ]; then
      exit 0
    fi
    # A mismatch must not rename the live lock. A non-owner release leaves it.
    lock_token=$(sed -n '3p' "$LOCK" 2>/dev/null || true)
    lock_token=${lock_token%$'\r'}
    if [ -z "$lock_token" ] || [ "$TOKEN_ARG" != "$lock_token" ]; then
      exit 0
    fi
    # The pre-check matched. Rename, then confirm this inode is still ours.
    # A stealer may have replaced the path between the read and the rename.
    REL="$LOCK.releasing.$$"
    if ! mv "$LOCK" "$REL" 2>/dev/null; then
      exit 0
    fi
    lock_token=$(sed -n '3p' "$REL" 2>/dev/null || true)
    lock_token=${lock_token%$'\r'}
    if [ -n "$lock_token" ] && [ "$TOKEN_ARG" = "$lock_token" ]; then
      rm -f "$REL"
      exit 0
    fi
    # Not our inode. Put it back. Never delete a lock we do not own.
    if [ ! -e "$LOCK" ]; then
      mv "$REL" "$LOCK" 2>/dev/null || true
    fi
    exit 0
    ;;
  *)
    usage
    ;;
esac
