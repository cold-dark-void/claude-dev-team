#!/usr/bin/env bash
# skills/lib/portable.sh — atomic_write (SPEC-009 Backlog write integrity, C1).
#
# Source (preferred, needed when the producer is a shell function):
#   SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
#   . "$SCRIPT_DIR/../lib/portable.sh"
#   atomic_write <dest> <cmd> [args...]
#
# Subprocess (tests and future callers; producer must be an external command):
#   bash skills/lib/portable.sh atomic_write <dest> <cmd> [args...]
#
# atomic_write runs "<cmd> [args...]" with stdout redirected to a temp file
# next to <dest>, then renames the temp file onto <dest> once the producer
# succeeds. <dest> is left untouched on any failure and no temp file is left
# behind. Exactly one function is defined here.
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

# Subprocess entry point.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "$#" -ge 3 ] && [ "$1" = "atomic_write" ]; then
    shift
    atomic_write "$@"
    exit $?
  fi
  echo "usage: portable.sh atomic_write <dest> <cmd> [args...]" >&2
  exit 64
fi
