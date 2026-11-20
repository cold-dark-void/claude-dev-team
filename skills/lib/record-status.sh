#!/usr/bin/env bash
# skills/lib/record-status.sh — the shared PASS/WARN/FAIL record-and-render pair
# (CDT-658 T3 copy-extract; the table contract is SPEC-043 M6, the check semantics
# are SPEC-022 M3).
#
# SOURCE-ONLY. This file declares arrays and functions and runs nothing, so a
# driver can source it before it resolves any root path.
#
# The registry is five parallel indexed arrays plus the footer counters
# (bash 3.2: no associative array, no nameref):
#   CHECK_IDS  CHECK_GROUPS  CHECK_STATUSES  CHECK_DETAILS  CHECK_FIXITS
#   N_PASS  N_WARN  N_FAIL  N_SKIP
#
# Function inventory:
#   record_status <id> <group> <status> <detail> [fixit]   append one row
#   reset_status                                           drop every row
#   count_statuses                                         fill the four counters
#   render_status_rows                                     the table body
#   status_footer                                          "N pass / N warn / N fail / N skip"
#   status_exit_code                                       rc 0 no FAIL · rc 2 any FAIL
#
# Consumers. skills/doctor/checks/lib.sh (SPEC-022) sources this and keeps its
# own extras: the CHECK_GATE_WAIVED column, the --gate waived-FAIL counting, the
# gate footer variant, the JSON document, and its header line.
# skills/control-plane/setup.sh (SPEC-043 M6) sources it for the verify table.
# The table body and its footer have exactly one home here — no divergence
# waiver.

# The registry arrays are declared once. A consumer that sources this file
# twice (a sourced driver under `set -e`) must not lose the rows it recorded,
# so each declaration is conditional.
if [ -z "${CHECK_IDS[@]+x}" ]; then
  CHECK_IDS=()
  CHECK_GROUPS=()
  CHECK_STATUSES=()
  CHECK_DETAILS=()
  CHECK_FIXITS=()
fi

record_status() {
  # record_status <id> <group> <status> <detail> [fixit]
  # Status is PASS | WARN | FAIL | SKIP. Unknown statuses are recorded and
  # counted as neither (SPEC-022 M3 keeps that leniency).
  local id="${1-}" group="${2-}" status="${3-}" detail="${4-}" fixit="${5:-}"
  if [ -z "$id" ] || [ -z "$status" ]; then
    printf 'record_status: an id and a status are required\n' >&2
    return 64
  fi
  CHECK_IDS+=("$id")
  CHECK_GROUPS+=("$group")
  CHECK_STATUSES+=("$status")
  CHECK_DETAILS+=("$detail")
  CHECK_FIXITS+=("$fixit")
  return 0
}

reset_status() {
  CHECK_IDS=()
  CHECK_GROUPS=()
  CHECK_STATUSES=()
  CHECK_DETAILS=()
  CHECK_FIXITS=()
  N_PASS=0
  N_WARN=0
  N_FAIL=0
  N_SKIP=0
  return 0
}

count_statuses() {
  # Fills N_PASS/N_WARN/N_FAIL/N_SKIP from the registry. A caller with an extra
  # column (doctor's --gate waiver) keeps its own walk: this one counts the
  # four severities only.
  local i=0
  N_PASS=0
  N_WARN=0
  N_FAIL=0
  N_SKIP=0
  while [ "$i" -lt "${#CHECK_IDS[@]}" ]; do
    case "${CHECK_STATUSES[$i]}" in
      PASS) N_PASS=$((N_PASS + 1)) ;;
      WARN) N_WARN=$((N_WARN + 1)) ;;
      FAIL) N_FAIL=$((N_FAIL + 1)) ;;
      SKIP) N_SKIP=$((N_SKIP + 1)) ;;
    esac
    i=$((i + 1))
  done
  return 0
}

render_status_rows() {
  # One row per check; a WARN or FAIL carries its fix-it line.
  local i=0
  while [ "$i" -lt "${#CHECK_IDS[@]}" ]; do
    printf '%-4s | %s | %s\n' \
      "${CHECK_STATUSES[$i]}" "${CHECK_IDS[$i]}" "${CHECK_DETAILS[$i]}" || return 1
    if [ "${CHECK_STATUSES[$i]}" = "WARN" ] || [ "${CHECK_STATUSES[$i]}" = "FAIL" ]; then
      if [ -n "${CHECK_FIXITS[$i]}" ]; then
        printf '       fix-it: %s\n' "${CHECK_FIXITS[$i]}" || return 1
      fi
    fi
    i=$((i + 1))
  done
  return 0
}

status_footer() {
  count_statuses
  printf '%d pass / %d warn / %d fail / %d skip\n' \
    "$N_PASS" "$N_WARN" "$N_FAIL" "$N_SKIP" || return 1
  return 0
}

status_exit_code() {
  # SPEC-043 M7: 0 when no row FAILED, 2 when any row FAILED.
  count_statuses
  if [ "$N_FAIL" -gt 0 ]; then
    return 2
  fi
  return 0
}
