#!/usr/bin/env bash
# Composite staleness score, 0-100.
# usage: score.sh <age_days> <tier> VERDICT:CONF [VERDICT:CONF...]
# Point average is 0-40. Scale it to 0-100 before age and tier modifiers,
# so one CONTRADICTED claim at confidence 90 scores 90.
set -euo pipefail

age=${1:?age_days}
tier=${2:?tier}
shift 2
if [ $# -eq 0 ]; then
  echo 0
  exit 0
fi

sum=0
n=0
for item in "$@"; do
  verdict=${item%%:*}
  conf=${item##*:}
  case "$verdict" in
    VALID) base=0 ;;
    STALE) base=25 ;;
    AMBIGUOUS) base=10 ;;
    CONTRADICTED) base=40 ;;
    *) echo "score: unknown verdict $verdict" >&2; exit 64 ;;
  esac
  case "$conf" in
    ''|*[!0-9]*) echo "score: confidence must be an integer" >&2; exit 64 ;;
  esac
  sum=$((sum + base * conf / 100))
  n=$((n + 1))
done

raw=$((sum / n))
scaled=$((raw * 100 / 40))
if [ "$age" -gt 180 ]; then
  age_mod=5
elif [ "$age" -gt 30 ]; then
  age_mod=$(((age - 30) * 5 / 150))
else
  age_mod=0
fi
tier_mod=0
if [ "$tier" = 2 ]; then
  tier_mod=-5
fi
score=$((scaled + age_mod + tier_mod))
if [ "$score" -lt 0 ]; then
  score=0
fi
if [ "$score" -gt 100 ]; then
  score=100
fi
echo "$score"
