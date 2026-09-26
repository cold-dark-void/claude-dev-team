#!/usr/bin/env bash
# tests/lib/skip.sh — SPEC-030 R18-R19 exit-77 skip protocol. Source-only:
# sourcing this file has no side effect. `<suite>` below is the basename of
# the sourcing script's $0.
#
#   skip_if_root [<reason>]  id -u = 0 -> stderr "SKIP: <suite>: root uid:
#                            <reason>"; exit 77. Else return 0.
#   require_cmd <cmd>...     any <cmd> missing from PATH -> stderr
#                            "SKIP: <suite>: missing command: <cmd>";
#                            exit 77. Else return 0.
#
# A whole-suite skip calls one of these at the top of the suite, before any
# other work. A per-case skip runs the helper in a subshell so only that
# case is skipped:
#   if ( skip_if_root "<case>" ); then <case body>; fi
#
# A suite MUST exit 77 only for an environment cause (missing command, root
# uid). A missing repo file or a failed assertion is a FAIL, never a skip
# (R19).

skip_if_root() {
  local reason="${1:-}"
  if [ "$(id -u)" = "0" ]; then
    echo "SKIP: $(basename -- "$0"): root uid: $reason" >&2
    exit 77
  fi
  return 0
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "SKIP: $(basename -- "$0"): missing command: $cmd" >&2
      exit 77
    fi
  done
  return 0
}
