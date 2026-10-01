#!/usr/bin/env bash
# tests/lib/trailing-flag.sh — WP 2-02 trailing value-flag probe. Source-only:
# sourcing this file has no side effect (function definitions only).
#
#   trailing_flag_scan <script> <want_rc> [<fn>|- [<pre-arg>...]]
#
# A flag that takes a value is parsed as `X="${2:-}"; shift 2`. With one
# argument left, `shift 2` fails without shifting, so `while [ $# -gt 0 ]`
# never ends (no errexit) or the script exits 1 with no message (errexit).
# This probe finds every case arm of <script> that holds a `shift 2`, then
# runs `bash <script> <pre-arg>... <flag>` once per flag, under a 2 s timeout
# and with stdin closed, and checks that the exit code is <want_rc>.
#
#   <fn>   limit the search to the body of that shell function (from the line
#          `<fn>() {` to the next line that starts with `}`); `-` searches the
#          whole file. Use it for scripts that parse one flag set per
#          subcommand.
#   <pre-arg>...  arguments that come before the flag (the subcommand).
#
# Sets two globals and prints nothing:
#   TF_N    number of flags that were run (0 when nothing matched or when no
#           timeout command exists; the caller must treat 0 as a failure)
#   TF_BAD  space-separated "<flag>=<rc>" for each flag whose exit code is
#           not <want_rc> (124 = the script hung)
#   TF_SKIP 1 when neither `timeout` nor `gtimeout` is on PATH, else 0
#
# TF_EXEMPT (env, space-separated flags) names flags whose value is optional;
# the probe skips them. Flags with `=` or `*` in the pattern (`--key=*`) are
# skipped too: they carry their own value and never reach `shift 2`.
#
# bash 3.2 (no mapfile / declare -A).

trailing_flag_flags() { # trailing_flag_flags <script> <fn|->
  TF_FN="$2" awk '
    BEGIN { fn = ENVIRON["TF_FN"]; infn = (fn == "-"); pat = "" }
    {
      line = $0
      if (!infn) {
        if (line ~ ("^" fn "[ \t]*\\(\\)")) { infn = 1 } else next
      } else if (fn != "-" && line ~ /^}/) { infn = 0; next }
      if (line ~ /^[ \t]*#/) next
      if (match(line, /^[ \t]*-[^) \t]*\)/)) {
        pat = substr(line, RSTART, RLENGTH)
        sub(/^[ \t]*/, "", pat); sub(/\)$/, "", pat)
      }
      if (pat != "" && line ~ /(^|[ \t;])shift 2([ \t;|&]|$)/) {
        n = split(pat, alt, "|")
        for (i = 1; i <= n; i++) {
          if (alt[i] ~ /[=*]/) continue
          if (alt[i] ~ /^-/ && !(alt[i] in seen)) { seen[alt[i]] = 1; print alt[i] }
        }
      }
      if (line ~ /;;/) pat = ""
    }
  ' "$1"
}

trailing_flag_scan() {
  local script="$1" want="$2" fn="${3:--}" tmo flag rc
  local pre=()
  if [ "$#" -gt 3 ]; then shift 3; pre=("$@"); fi
  TF_N=0
  TF_BAD=""
  TF_SKIP=0
  tmo=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)
  if [ -z "$tmo" ]; then TF_SKIP=1; return 0; fi
  while IFS= read -r flag || [ -n "$flag" ]; do
    [ -n "$flag" ] || continue
    case " ${TF_EXEMPT:-} " in *" $flag "*) continue ;; esac
    TF_N=$((TF_N + 1))
    if "$tmo" 2 bash "$script" ${pre[@]+"${pre[@]}"} "$flag" </dev/null >/dev/null 2>&1; then
      rc=0
    else
      rc=$?
    fi
    if [ "$rc" -ne "$want" ]; then TF_BAD="$TF_BAD $flag=$rc"; fi
  done < <(trailing_flag_flags "$script" "$fn")
  return 0
}
