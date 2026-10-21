#!/usr/bin/env bash
# parse-flags.sh — sibling --with-advisor parser (SPEC-039 M9/M37).
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
#
#   parse-flags.sh [<arg>...]
#
# stdout: exactly one JSON object
#   {"enabled":true|false,"source":"flag|env|none"}
#   plus an optional "model" key when a model override is resolved:
#   {"enabled":true,"source":"flag","model":"<model>"}
#
#   --with-advisor                    -> {"enabled":true,"source":"flag"}
#   --with-advisor=<model>            -> {"enabled":true,"source":"flag","model":"<model>"}
#   bare flag + ADVISOR_MODEL=<model> -> {"enabled":true,"source":"flag","model":"<model>"}
#   no flag, ADVISOR in {1,true}      -> {"enabled":true,"source":"env"}
#   + ADVISOR_MODEL=<model>           -> {"enabled":true,"source":"env","model":"<model>"}
#   else                              -> {"enabled":false,"source":"none"}
#
# Flag wins over env. A duplicate --with-advisor or --with-advisor=* exits 64.
# A model token MUST match [A-Za-z0-9._:+@~/-]+ ; `null` and `--clear` are
# reserved so an absent override can never be spelled as a model. ADVISOR_MODEL
# is validated even when a flag wins its precedence check.
# `--advisor` (the omp host flag) MUST NOT enable this feature and MUST NOT
# exit 64 — it is ignored here like any other non-member token. Default off.
# ADVISOR_MODEL is consulted only when the advisor is enabled; when disabled
# the output stays byte-identical to the pre-M37 two-key object.
# Every path prints with printf: the parser takes no jq dependency.
# skills/autopilot/parse-flags.sh stays six-key; this sibling owns the
# --with-advisor key and the optional model override.

set -u

trim() {
  local s=$1
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Allowlist, not a denylist: the token is echoed into a printf-built JSON
# object, an env assignment the orchestrator writes, epic state, and a host
# Agent `model` param. `null` and `--clear` are reserved so "absent" can never
# be spelled as a model. The grammar mirrors ask.sh deliberately: argv misuse
# exits 64 here, an ambient bad value refuses at the seam.
valid_model() {
  case "$1" in
    ''|null|--clear) return 1 ;;
    *..*) return 1 ;;
    *[!A-Za-z0-9._:+@~/-]*) return 1 ;;
  esac
  return 0
}

seen=0
flag_model=""
model_from_flag=false
for _arg in "$@"; do
  case "$_arg" in
    --with-advisor)
      seen=$((seen + 1))
      ;;
    --with-advisor=*)
      seen=$((seen + 1))
      flag_model="${_arg#--with-advisor=}"
      model_from_flag=true
      ;;
  esac
done

if [ "$seen" -gt 1 ]; then
  echo "advisor parse-flags: duplicate --with-advisor" >&2
  exit 64
fi

die_bad() {
  echo "advisor parse-flags: $1 is not a valid model token [A-Za-z0-9._:+@~/-], and null / --clear are reserved" >&2
  exit 64
}

# The ambient value is checked even when a flag wins: precedence must not hide a
# malformed ADVISOR_MODEL from the next run.
env_model=""
if [ -n "${ADVISOR_MODEL:-}" ]; then
  env_model=$(trim "${ADVISOR_MODEL}")
  valid_model "$env_model" || die_bad "ADVISOR_MODEL '$ADVISOR_MODEL'"
fi

# stdout is printf-only on every path: the parser stays jq-free so a missing jq
# can never yield exit 0 with an empty object (SPEC-039 AC1).
emit() { # emit <enabled> <source> <model>
  if [ -n "$3" ]; then
    printf '{"enabled":%s,"source":"%s","model":"%s"}\n' "$1" "$2" "$3"
  else
    printf '{"enabled":%s,"source":"%s"}\n' "$1" "$2"
  fi
}

if [ "$seen" -eq 1 ]; then
  model="$env_model"
  if [ "$model_from_flag" = true ]; then
    model=$(trim "$flag_model")
    valid_model "$model" || die_bad "--with-advisor=<model> '$flag_model'"
  fi
  emit true flag "$model"
  exit 0
fi

case "${ADVISOR:-}" in
  1|true) emit true env "$env_model" ;;
  *)      emit false none "" ;;
esac
