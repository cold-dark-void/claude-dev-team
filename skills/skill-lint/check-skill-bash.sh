#!/usr/bin/env bash
# SPEC-021: deterministic linter for fenced bash blocks in plugin .md files.
# Pure subprocess CLI — no LLM, no network. See skills/skill-lint/SKILL.md.
#
# Two engines, one report. lint.py runs C1-C5. fence-state.awk (bash + awk, no
# interpreter) runs C6 and C10 over the same file set. This wrapper merges the
# finding lines, the "N findings, M waived" summary, --json and the exit code
# (0 clean, 1 unwaived findings, 64 usage error). If the awk engine fails, the
# run fails: a broken rule engine never reads as a clean run.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PY="$HERE/lint.py"
AWKF="$HERE/fence-state.awk"

ARGS=("$@")
root=""
json=0
files=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) exec python3 "$PY" --help ;;
    --json) json=1; shift ;;
    --root)
      if [ $# -lt 2 ]; then echo "usage error: --root needs a directory" >&2; exit 64; fi
      root="$2"; shift 2 ;;
    --root=*) root="${1#--root=}"; shift ;;
    --) shift; files=(${files[@]+"${files[@]}"} "$@"); break ;;
    -?*) echo "usage error: unknown option: $1" >&2; exit 64 ;;
    *) files+=("$1"); shift ;;
  esac
done

# Engine 1: lint.py (C1-C5). stderr (warn: lines, C5 vacuity error) passes through.
if py_out=$(python3 "$PY" ${ARGS[@]+"${ARGS[@]}"}); then py_rc=0; else py_rc=$?; fi
case "$py_rc" in
  0|1) ;;
  *) if [ -n "$py_out" ]; then printf '%s\n' "$py_out"; fi; exit "$py_rc" ;;
esac

# Target set for engine 2: the explicit readable files, or the same discovery
# as lint.py (commands/skills/agents *.md + AGENTS.md; fixtures excluded).
discover() {
  local d
  for d in commands skills agents; do
    [ -d "$root/$d" ] || continue
    find "$root/$d" -path '*skill-lint/fixtures*' -prune -o \( -type f -o -type l \) -name '*.md' -print
  done | LC_ALL=C sort
  if [ -f "$root/AGENTS.md" ]; then printf '%s\n' "$root/AGENTS.md"; fi
  return 0
}

targets=()
if [ "${#files[@]}" -gt 0 ]; then
  for f in "${files[@]}"; do
    if [ -f "$f" ] && [ -r "$f" ]; then targets+=("$f"); fi
  done
else
  [ -n "$root" ] || root=$(git rev-parse --show-toplevel 2>/dev/null) || root=$(pwd)
  while IFS= read -r f || [ -n "$f" ]; do targets+=("$f"); done < <(discover)
fi

# Engine 2: fence-state.awk (C6, C10). One TSV line per finding.
awk_tsv=""
if [ "${#targets[@]}" -gt 0 ]; then
  if awk_tsv=$(awk -f "$AWKF" "${targets[@]}"); then :; else
    awk_rc=$?
    echo "error: fence-state.awk failed (rc=$awk_rc); C6/C10 were not checked — refusing to report a clean run" >&2
    exit 1
  fi
fi

a_unw=0   # unwaived awk findings
a_wv=0    # waived awk findings
a_txt=""  # printable unwaived awk findings
if [ -n "$awk_tsv" ]; then
  while IFS=$'\t' read -r w p l id msg || [ -n "$w" ]; do
    if [ "$w" = "1" ]; then
      a_wv=$((a_wv + 1))
    else
      a_unw=$((a_unw + 1))
      a_txt="${a_txt}${p}:${l}: [${id}] ${msg}"$'\n'
    fi
  done <<<"$awk_tsv"
fi

if [ "$json" -eq 1 ]; then
  if ! command -v jq >/dev/null 2>&1; then
    echo "error: --json needs jq to merge the fence-state findings" >&2
    exit 1
  fi
  awk_json=$(printf '%s\n' "$awk_tsv" | jq -R -s -c '[split("\n")[] | select(length > 0) | split("\t") | {path: .[1], line: (.[2] | tonumber), check: .[3], message: .[4], waived: (.[0] == "1")}]')
  printf '%s\n%s\n' "$py_out" "$awk_json" | jq -c -s '.[0] + .[1]'
else
  summary=$(printf '%s\n' "$py_out" | tail -n 1)
  re='^([0-9]+) findings, ([0-9]+) waived$'
  if ! [[ "$summary" =~ $re ]]; then
    echo "error: cannot parse the lint.py summary line: $summary" >&2
    exit 1
  fi
  py_n="${BASH_REMATCH[1]}"
  py_w="${BASH_REMATCH[2]}"
  body=$(printf '%s\n' "$py_out" | sed '$d')
  if [ -n "$body" ]; then printf '%s\n' "$body"; fi
  if [ -n "$a_txt" ]; then printf '%s' "$a_txt"; fi
  printf '%d findings, %d waived\n' $((py_n + a_unw + a_wv)) $((py_w + a_wv))
fi

if [ "$py_rc" -eq 1 ] || [ "$a_unw" -gt 0 ]; then exit 1; fi
exit 0
