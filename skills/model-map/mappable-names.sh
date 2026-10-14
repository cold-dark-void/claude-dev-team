#!/usr/bin/env bash
# mappable-names.sh — single source of the Model map mappable set (SPEC-037 M8)
# and the always-empty internals (SPEC-039 M36).
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
#
#   mappable-names.sh --is NAME         exit 0 when NAME is mappable, 1 otherwise
#   mappable-names.sh --list            print the mappable names, one per line
#   mappable-names.sh --internal-empty  print the always-empty internal names, one per line
#
# Read-only. No jq. No filesystem access. Exit 64 on unknown flag or missing
# argument. The 11-name set is SPEC-037 M8 plus `advisor` (SPEC-039 M36);
# `distiller` and `project-init` stay always-empty internals (resolve to empty
# stdout, never emit).

set -euo pipefail

MAPPABLE="pm tech-lead ic5 ic4 devops qa ds council-judge finder debugger advisor"
INTERNAL_EMPTY="distiller project-init"

case "${1:-}" in
  --is)
    if [ -z "${2:-}" ] || [ -n "${3:-}" ]; then
      echo "usage: mappable-names.sh --is <name>" >&2
      exit 64
    fi
    for _n in $MAPPABLE; do
      if [ "$_n" = "$2" ]; then
        exit 0
      fi
    done
    exit 1
    ;;
  --list)
    if [ -n "${2:-}" ]; then
      echo "usage: mappable-names.sh --list" >&2
      exit 64
    fi
    for _n in $MAPPABLE; do
      printf '%s\n' "$_n"
    done
    ;;
  --internal-empty)
    if [ -n "${2:-}" ]; then
      echo "usage: mappable-names.sh --internal-empty" >&2
      exit 64
    fi
    for _n in $INTERNAL_EMPTY; do
      printf '%s\n' "$_n"
    done
    ;;
  *)
    echo "usage: mappable-names.sh --is <name> | --list | --internal-empty" >&2
    exit 64
    ;;
esac
