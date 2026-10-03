#!/usr/bin/env bash
# tests/lib/mtimes.sh — GNU/BSD-safe mtime helpers for suites (CDT-285).
# Source-only, like hermetic.sh. `touch -d` and `find -printf` do not exist on
# stock macOS; these helpers branch on the date/stat flavor instead.
#
#   touch_ago FILE SECONDS            Set mtime to SECONDS before now.
#   touch_when FILE "YYYY-MM-DD HH:MM:SS"
#                                     Set mtime to that LOCAL wall-clock time.
#   find_mtimes DIR                   One "<epoch> <path>" line per entry under
#                                     DIR (recursive, all types) — the portable
#                                     form of `find DIR -printf '%T@ %p\n'`.
#                                     Second-resolution, like BSD stat; suites
#                                     that need sub-second ordering must keep
#                                     their fixtures separated by >= 1s.
#
# Every helper is errexit-safe: call it from an if/|| context or accept that
# a failure means the fixture mtime was not set.

touch_ago() {
  _ta_f=$1; _ta_s=$2
  _ta_then=$(( $(date +%s) - _ta_s ))
  _ta_fmt=$(date -d "@$_ta_then" '+%Y%m%d%H%M.%S' 2>/dev/null) \
    || _ta_fmt=$(date -r "$_ta_then" '+%Y%m%d%H%M.%S' 2>/dev/null) \
    || return 1
  touch -t "$_ta_fmt" "$_ta_f"
}

touch_when() {
  _tw_f=$1; _tw_when=$2
  _tw_epoch=$(date -d "$_tw_when" '+%s' 2>/dev/null) \
    || _tw_epoch=$(date -j -f '%Y-%m-%d %H:%M:%S' "$_tw_when" '+%s' 2>/dev/null) \
    || return 1
  _tw_fmt=$(date -d "@$_tw_epoch" '+%Y%m%d%H%M.%S' 2>/dev/null) \
    || _tw_fmt=$(date -r "$_tw_epoch" '+%Y%m%d%H%M.%S' 2>/dev/null) \
    || return 1
  touch -t "$_tw_fmt" "$_tw_f"
}

find_mtimes() { # find_mtimes DIR
  if stat -c '%Y %n' "$1" >/dev/null 2>&1; then
    find "$1" -exec stat -c '%Y %n' {} + 2>/dev/null
  else
    find "$1" -exec stat -f '%m %N' {} + 2>/dev/null
  fi
}
