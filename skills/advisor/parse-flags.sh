#!/usr/bin/env bash
# parse-flags.sh — sibling --with-advisor parser (SPEC-039 M9).
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
#
#   parse-flags.sh [<arg>...]
#
# stdout: exactly one JSON object {"enabled":true|false,"source":"flag|env|none"}
#   --with-advisor present            -> {"enabled":true,"source":"flag"}
#   no flag, ADVISOR in {1,true}      -> {"enabled":true,"source":"env"}
#   else                              -> {"enabled":false,"source":"none"}
# Flag wins over env. A duplicate --with-advisor exits 64 (stderr one line).
# `--advisor` (the omp host flag) MUST NOT enable this feature and MUST NOT
# exit 64 — it is ignored here like any other non-member token. Default off.
# skills/autopilot/parse-flags.sh stays six-key; this sibling owns the one
# --with-advisor key and nothing else.

set -u

seen=0
for _arg in "$@"; do
  if [ "$_arg" = "--with-advisor" ]; then
    seen=$((seen + 1))
  fi
done

if [ "$seen" -gt 1 ]; then
  echo "advisor parse-flags: duplicate --with-advisor" >&2
  exit 64
fi

if [ "$seen" -eq 1 ]; then
  printf '{"enabled":true,"source":"flag"}\n'
  exit 0
fi

case "${ADVISOR:-}" in
  1|true) printf '{"enabled":true,"source":"env"}\n' ;;
  *)      printf '{"enabled":false,"source":"none"}\n' ;;
esac
