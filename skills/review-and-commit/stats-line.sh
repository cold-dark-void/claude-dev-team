#!/usr/bin/env bash
# Review stats line. Agent count is the plan flavor list, plus one when the
# external reviewer slot is available.
#   stats-line.sh <plan.json> <findings> <passed> <discarded>
set -u
[ "$#" -eq 4 ] || { printf 'stats-line: need plan.json findings passed discarded\n' >&2; exit 64; }
plan="$1"
n="$2"
passed="$3"
discarded="$4"
agents=$(jq '(.flavors // []) | length' "$plan")
ext=$(jq -r '.external.status // ""' "$plan")
if [ "$ext" = "available" ]; then
  agents=$((agents + 1))
fi
printf 'Review stats: %s findings from %s agents, %s passed confidence filter (≥80), %s discarded.\n' \
  "$n" "$agents" "$passed" "$discarded"
