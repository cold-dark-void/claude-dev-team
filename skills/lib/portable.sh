#!/usr/bin/env bash
# skills/lib/portable.sh — atomic_write (SPEC-009 C1) plus the CDT-284
# portability shim: sha256, lock (no flock), with_timeout.
#
# Source (preferred, needed when the producer is a shell function):
#   SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
#   . "$SCRIPT_DIR/../lib/portable.sh"
#   atomic_write <dest> <cmd> [args...]
#   portable_sha256 [file...]            # no file args: hash stdin
#   portable_lock_acquire <dir> [wait] [ttl]   # source-only; installs traps
#   portable_lock_release
#   portable_with_timeout <seconds> <cmd> [args...]
#
# Subprocess (tests and future callers; producer must be an external command):
#   bash skills/lib/portable.sh atomic_write <dest> <cmd> [args...]
#   bash skills/lib/portable.sh sha256 [file...]   # no file args: hash stdin
#   bash skills/lib/portable.sh with_timeout <seconds> <cmd> [args...]
#   lock has no subprocess form: a transient process cannot hold a lock.
#
# atomic_write runs "<cmd> [args...]" with stdout redirected to a temp file
# next to <dest>, then renames the temp file onto <dest> once the producer
# succeeds. <dest> is left untouched on any failure and no temp file is left
# behind. The complete function inventory is: atomic_write, portable_sha256,
# portable_lock_acquire, portable_lock_release, portable_with_timeout, and
# the _portable_lock_* helpers. Nothing else defines a function here.
#
# portable_sha256: sha256sum first (GNU), shasum -a 256 second (macOS/BSD).
# One hex digest line per input. rc 127 when neither tool exists.
#
# portable_lock_acquire: atomic mkdir test-and-set (CDT-284), lock dir
# "<dir>" holding a stamp "<pid> <epoch> <owner>". Stale — and stolen — when
# the stamping PID is no longer alive OR the stamp is older than <ttl>
# seconds (default 600); a missing/unparseable stamp gets one 1s grace
# re-read first (another acquirer may be mid-mkdir). A flock-era leftover
# regular file at the lock path is unlinked and the mkdir retried; a failed
# unlink fails fast. A carried-off copy that turns out fresh (restamped or
# replaced between the read and the mv) is handed back, never destroyed —
# same posture as backlog/lock.sh. <wait> seconds (default
# 0 = block forever, matching flock) bounds the loop; 0 return means held.
# Installs EXIT/INT/TERM traps that release — like backlog/lock.sh, this
# REPLACES any traps the caller had for those signals. Release removes the
# dir only when the stamp's owner field is ours (survives a PID-reuse
# hand-back); it is idempotent.
#
# portable_with_timeout: timeout (GNU), gtimeout (coreutils on macOS), then
# a perl fork/alarm supervisor returning 124 on timeout, the child's exit
# code, or 128+N when the child died to a signal. <seconds> must be >= 1.
#
# atomic_write runs the producer inside `if "$@" > "$_aw_tmp"; then`, so the
# producer runs with errexit effectively off — bash suspends -e for the
# tested command of an if/while/until, even when the caller has `set -e`.
# A shell-function producer (source form) must therefore propagate its own
# failures explicitly (for example `printf '%s' "$x" || return 1`); a
# later, successful statement in that function would otherwise mask an
# earlier command's failure and atomic_write would report success.

set -u

atomic_write() {
  local _aw_dest _aw_dir _aw_tmp _aw_mode _aw_rc

  _aw_dest="${1-}"
  [ -n "$_aw_dest" ] || return 1
  shift
  [ "$#" -ge 1 ] || return 1

  # Symlink dest: refuse, no change.
  if [ -L "$_aw_dest" ]; then
    return 1
  fi
  # Must be a regular file, or missing (parent dir must exist either way).
  if [ -e "$_aw_dest" ] && [ ! -f "$_aw_dest" ]; then
    return 1
  fi

  _aw_dir=$(dirname -- "$_aw_dest")
  [ -d "$_aw_dir" ] || return 1

  _aw_tmp=$(mktemp "$_aw_dir/.$(basename -- "$_aw_dest").tmp.XXXXXX") || return 1

  if "$@" > "$_aw_tmp"; then
    :
  else
    _aw_rc=$?
    rm -f "$_aw_tmp"
    return "$_aw_rc"
  fi

  if [ -e "$_aw_dest" ]; then
    # `|| _aw_mode=""` guards a caller running under `set -e`: when both stat
    # forms fail, the command substitution's own exit status is non-zero and
    # a bare `_aw_mode=$(...)` assignment would trip errexit and abort the
    # caller's shell here, leaving this temp file behind. Falling back to
    # "" keeps the assignment itself successful; the case below already
    # treats an empty/unmatched mode as failure.
    _aw_mode=$(stat -c %a "$_aw_dest" 2>/dev/null || stat -f %Lp "$_aw_dest" 2>/dev/null) || _aw_mode=""
    case "$_aw_mode" in
      [0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) ;;
      *)
        rm -f "$_aw_tmp"
        return 1
        ;;
    esac
  else
    _aw_mode=$(printf '%o' $(( 0666 & ~0$(umask) )))
  fi

  if chmod "$_aw_mode" "$_aw_tmp" && mv -f "$_aw_tmp" "$_aw_dest"; then
    return 0
  fi
  rm -f "$_aw_tmp"
  return 1
}

# ---- portable_sha256 (CDT-284) ----------------------------------------------

portable_sha256() {
  _ps_tool=""
  if command -v sha256sum >/dev/null 2>&1; then
    _ps_tool=sha256sum
  elif command -v shasum >/dev/null 2>&1; then
    _ps_tool=shasum
  else
    echo "portable.sh: no sha256 tool found (need sha256sum or shasum)" >&2
    return 127
  fi
  if [ "$_ps_tool" = sha256sum ]; then
    sha256sum -- "$@" | awk '{print $1}'
  else
    shasum -a 256 -- "$@" | awk '{print $1}'
  fi
}

# ---- portable lock (CDT-284; modeled on skills/backlog/lock.sh) --------------

PORTABLE_LOCK_DIR=""
PORTABLE_LOCK_OWNER=""

# _portable_lock_stamp_field <dir> <field 1|2|3> — pid | epoch | owner.
_portable_lock_stamp_field() {
  [ -f "$1/stamp" ] || return 1
  awk -v _f="$2" 'NR == 1 { print $_f; exit }' "$1/stamp" 2>/dev/null
}

_portable_lock_pid_alive() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$1" 2>/dev/null
}

portable_lock_acquire() {
  local _pl_dir _pl_wait _pl_ttl
  if [ $# -ge 1 ]; then _pl_dir="$1"; fi
  _pl_wait="${2:-0}"
  _pl_ttl="${3:-600}"
  local _pl_start _pl_now _pl_pid _pl_epoch _pl_pid2 _pl_epoch2 _pl_status
  [ -n "${_pl_dir:-}" ] || return 64
  case "$_pl_dir" in */) _pl_dir="${_pl_dir%/}" ;; esac
  case "$_pl_wait" in ''|*[!0-9]*) return 64 ;; esac
  case "$_pl_ttl" in ''|*[!0-9]*) return 64 ;; esac
  [ "$_pl_ttl" -ge 1 ] || return 64

  PORTABLE_LOCK_DIR="$_pl_dir"
  PORTABLE_LOCK_OWNER="$$-$RANDOM$RANDOM"

  # Traps BEFORE the first mkdir, so any exit past this point releases a lock
  # we go on to hold. This REPLACES the caller's EXIT/INT/TERM traps (same
  # contract as backlog/lock.sh).
  trap portable_lock_release EXIT
  trap 'portable_lock_release; exit 130' INT
  trap 'portable_lock_release; exit 143' TERM

  _pl_start=$(date +%s)
  while :; do
    if mkdir "$PORTABLE_LOCK_DIR" 2>/dev/null; then
      if printf '%s %s %s\n' "$$" "$(date +%s)" "$PORTABLE_LOCK_OWNER" \
        > "$PORTABLE_LOCK_DIR/stamp" 2>/dev/null; then
        return 0
      fi
      rm -rf "$PORTABLE_LOCK_DIR" 2>/dev/null
      return 1
    fi

    # mkdir failed: held, mid-release, mid-reclaim, blocked by a leftover
    # file, or uncreatable.
    _pl_status=fresh
    _pl_now=$(date +%s)
    if [ ! -d "$PORTABLE_LOCK_DIR" ]; then
      if [ -e "$PORTABLE_LOCK_DIR" ] || [ -L "$PORTABLE_LOCK_DIR" ]; then
        # A flock-era leftover .lock FILE (or symlink) sits at the lock
        # path (CDT-284 review): mkdir can never succeed over it and the
        # loop below would spin forever. Unlink it and retry; a failed
        # unlink fails fast instead.
        if rm -f -- "$PORTABLE_LOCK_DIR" 2>/dev/null \
          && [ ! -e "$PORTABLE_LOCK_DIR" ] && [ ! -L "$PORTABLE_LOCK_DIR" ]; then
          continue
        fi
        echo "portable.sh: cannot create lock: $PORTABLE_LOCK_DIR exists and is not a directory" >&2
        return 1
      fi
      # Between our failed mkdir and this check the dir may already be
      # gone (holder's EXIT-trap rm -rf, or a stale-lock reclaim/hand-back
      # mv), so treat that as gone and retry — mkdir will very likely
      # succeed next pass. Those cases are told apart by testing the
      # PARENT for writability, not by re-testing the lock dir itself.
      if [ ! -w "$(dirname -- "$PORTABLE_LOCK_DIR")" ]; then
        echo "portable.sh: cannot create lock: $PORTABLE_LOCK_DIR" >&2
        return 1
      fi
      _pl_status=gone
    else
      _pl_pid=$(_portable_lock_stamp_field "$PORTABLE_LOCK_DIR" 1) || _pl_pid=""
      _pl_epoch=$(_portable_lock_stamp_field "$PORTABLE_LOCK_DIR" 2) || _pl_epoch=""
      if [ -z "$_pl_pid" ] || [ -z "$_pl_epoch" ]; then
        # Missing/unparseable stamp: another acquirer may be mid-mkdir.
        # One 1s grace re-read, then it counts as stale.
        sleep 1
        _pl_now=$(date +%s)
        _pl_pid=$(_portable_lock_stamp_field "$PORTABLE_LOCK_DIR" 1) || _pl_pid=""
        _pl_epoch=$(_portable_lock_stamp_field "$PORTABLE_LOCK_DIR" 2) || _pl_epoch=""
        if [ -z "$_pl_pid" ] || [ -z "$_pl_epoch" ]; then
          _pl_status=stale
        fi
      fi
      if [ "$_pl_status" = fresh ]; then
        if ! _portable_lock_pid_alive "$_pl_pid"; then
          _pl_status=stale
        elif (( _pl_now - _pl_epoch >= _pl_ttl )); then
          # Live holder past the TTL: steal anyway (PID reuse and hung
          # holders must not pin the lock forever).
          _pl_status=stale
        fi
      fi
    fi

    if [ "$_pl_status" = stale ]; then
      # Never assume ownership of a stale lock: move it aside under our own
      # owner id first, then re-read the moved copy. Another acquirer may
      # have created or restamped this lock between the read above and this
      # mv, so the copy may be somebody's LIVE lock (CDT-284 review): hand
      # back any fresh copy — never rm a stamp that names a live holder.
      if mv "$PORTABLE_LOCK_DIR" "$PORTABLE_LOCK_DIR.stale.$PORTABLE_LOCK_OWNER" 2>/dev/null; then
        _pl_pid2=$(_portable_lock_stamp_field "$PORTABLE_LOCK_DIR.stale.$PORTABLE_LOCK_OWNER" 1) || _pl_pid2=""
        _pl_epoch2=$(_portable_lock_stamp_field "$PORTABLE_LOCK_DIR.stale.$PORTABLE_LOCK_OWNER" 2) || _pl_epoch2=""
        if [ -n "$_pl_pid2" ] && [ -n "$_pl_epoch2" ] \
          && _portable_lock_pid_alive "$_pl_pid2" \
          && (( $(date +%s) - _pl_epoch2 < _pl_ttl )); then
          # Fresh: give it back when the path is free. When it is not
          # (a third acquirer re-mkdir'd first), leave the copy under its
          # .stale name rather than destroy a live holder's directory.
          if [ ! -e "$PORTABLE_LOCK_DIR" ] && [ ! -L "$PORTABLE_LOCK_DIR" ]; then
            mv "$PORTABLE_LOCK_DIR.stale.$PORTABLE_LOCK_OWNER" "$PORTABLE_LOCK_DIR" 2>/dev/null || :
          fi
          # We did not gain the lock either way: fall through to the
          # wait/deadline check and retry.
        else
          # Stale or abandoned copy (dead pid, expired stamp, or no
          # stamp at all): discard it and retry the mkdir.
          rm -rf "$PORTABLE_LOCK_DIR.stale.$PORTABLE_LOCK_OWNER" 2>/dev/null
          continue
        fi
      fi
    fi

    if [ "$_pl_wait" -gt 0 ]; then
      _pl_now=$(date +%s)
      if (( _pl_now - _pl_start >= _pl_wait )); then
        return 1
      fi
    fi
    sleep 1
  done
}

portable_lock_release() {
  local _pl_owner
  if [ -n "${PORTABLE_LOCK_DIR:-}" ]; then
    _pl_owner=$(_portable_lock_stamp_field "$PORTABLE_LOCK_DIR" 3) || _pl_owner=""
    if [ -n "$_pl_owner" ] && [ "$_pl_owner" = "${PORTABLE_LOCK_OWNER:-}" ]; then
      rm -rf "$PORTABLE_LOCK_DIR" 2>/dev/null
    fi
  fi
  return 0
}

# ---- portable_with_timeout (CDT-284) -----------------------------------------

portable_with_timeout() {
  local _pt_s="$1"
  [ $# -ge 2 ] || return 64
  shift
  case "$_pt_s" in
    ''|*[!0-9]*) return 64 ;;
  esac
  [ "$_pt_s" -ge 1 ] || return 64
  if command -v timeout >/dev/null 2>&1; then
    timeout "$_pt_s" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$_pt_s" "$@"
  else
    # perl supervisor: SIGALRM at the deadline kills the child; 124 on
    # timeout, the child's own exit code, or 128+N for a signalled child.
    perl -e '
      use POSIX qw(:sys_wait_h WIFEXITED WEXITSTATUS WIFSIGNALED WTERMSIG);
      my $t = shift @ARGV;
      my $pid = fork();
      die "fork: $!\n" unless defined $pid;
      if ($pid == 0) { exec(@ARGV) or exit 127; }
      my $timed_out = 0;
      local $SIG{ALRM} = sub { $timed_out = 1; kill "KILL", $pid; };
      alarm $t;
      waitpid $pid, 0;
      alarm 0;
      exit 124 if $timed_out && WIFSIGNALED($?);
      exit WEXITSTATUS($?) if WIFEXITED($?);
      exit 128 + WTERMSIG($?) if WIFSIGNALED($?);
      exit 1;
    ' "$_pt_s" "$@"
  fi
}

# Subprocess entry point.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "$#" -ge 3 ] && [ "$1" = "atomic_write" ]; then
    shift
    atomic_write "$@"
    exit $?
  fi
  if [ "$#" -ge 1 ] && [ "$1" = "sha256" ]; then
    shift
    portable_sha256 "$@"
    exit $?
  fi
  if [ "$#" -ge 2 ] && [ "$1" = "with_timeout" ]; then
    shift
    portable_with_timeout "$@"
    exit $?
  fi
  if [ "${1:-}" = "lock" ]; then
    echo "portable.sh: lock is source-only — source this file and call portable_lock_acquire/portable_lock_release" >&2
    exit 64
  fi
  echo "usage: portable.sh atomic_write <dest> <cmd> [args...] | sha256 [file...] | with_timeout <seconds> <cmd> [args...]" >&2
  exit 64
fi
