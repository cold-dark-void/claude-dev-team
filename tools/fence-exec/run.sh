#!/usr/bin/env bash
# SPEC-030 R23+: fence-exec harness. Checks and runs the ```bash fences in the
# plugin's commands, skills and agents (CDT-272). Pure subprocess CLI: bash,
# awk and POSIX utilities only (no interpreter, no network). See SPEC-030
# "Fence-exec harness".
#
# Usage: bash tools/fence-exec/run.sh [check|list|run] [--root DIR]
#                                     [--manifest FILE] [FILE.md ...]
#
#   list    Print every bash fence as TSV: file, first body line, last body
#           line, nearest heading, info string.
#   check   Static checks on every bash fence, then the manifest rules:
#             F1  `bash -n` parses the fence (`bash template` fences opt out)
#             F2  a function that only another fence defines is called
#             F3  `trap ... EXIT` in a fence that is not a script body
#             F4  `return` outside a function
#             F5  a literal $PDH/<path>, $PLUGIN_DIR/<path> or
#                 `plugin-dir.sh file|dir <path>` names a path that is absent
#             M1  a manifest row is stale or wrong (see manifest.tsv)
#           F2-F4 skip `bash template` fences (pseudocode, not shell text).
#   run     check, then run each manifest `suite` row as `bash <suite>` from
#           the root. This is the default and the CI entry.
#
# FILE arguments replace the no-argument scan set (skill_lint_scan_set:
# commands, skills and agents *.md plus AGENTS.md, skill-lint fixtures out).
# --root DIR is the repo root that F5 and the manifest resolve against
# (default: this checkout). --manifest FILE overrides
# tools/fence-exec/manifest.tsv; --manifest none runs without a manifest.
#
# Exclusions are in the manifest and are never silent: each is printed, must
# carry a reason and a backlog slug, and must match exactly the declared number
# of findings, so a fixed defect or a new one fails the run.
#
# Exit: 0 clean, 1 findings or a failed suite, 64 usage error or a malformed
# manifest. bash 3.2 portable (no mapfile, no associative arrays).
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
SCAN_AWK="$REPO/skills/skill-lint/fence-scan.awk"
ENGINE="$HERE/fence-check.awk"
PROG="tools/fence-exec/run.sh"

# shellcheck source=../../skills/skill-lint/scan-set.sh
. "$REPO/skills/skill-lint/scan-set.sh"
# shellcheck source=../../tests/lib/fence.sh
. "$REPO/tests/lib/fence.sh"

usage() {
  sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'
}

die64() { echo "$PROG: $*" >&2; exit 64; }

SUB=""
ROOT="$REPO"
MANIFEST="$HERE/manifest.tsv"
ORIG_PWD=$(pwd)
ARGFILES=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    check|list|run)
      if [ -n "$SUB" ]; then die64 "second subcommand: $1"; fi
      SUB="$1"; shift ;;
    --root)
      [ $# -ge 2 ] || die64 "--root needs a directory"
      ROOT="$2"; shift 2 ;;
    --root=*) ROOT="${1#--root=}"; shift ;;
    --manifest)
      [ $# -ge 2 ] || die64 "--manifest needs a file"
      MANIFEST="$2"; shift 2 ;;
    --manifest=*) MANIFEST="${1#--manifest=}"; shift ;;
    --) shift; while [ $# -gt 0 ]; do ARGFILES+=("$1"); shift; done ;;
    -?*) die64 "unknown option: $1" ;;
    *) ARGFILES+=("$1"); shift ;;
  esac
done
[ -n "$SUB" ] || SUB="run"

[ -d "$ROOT" ] || die64 "--root $ROOT is not a directory"
ROOT=$(cd "$ROOT" && pwd)
case "$MANIFEST" in none|/*) ;; *) MANIFEST="$ORIG_PWD/$MANIFEST" ;; esac
if [ "$MANIFEST" = none ]; then MANIFEST=""; fi
command -v awk >/dev/null 2>&1 || die64 "awk not found"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fence-exec.XXXXXX") || die64 "mktemp failed"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/dump" || die64 "cannot create $WORK/dump"
TSV="$WORK/engine.tsv"
FINDINGS="$WORK/findings.tsv"   # check TAB file TAB line TAB heading TAB message
: > "$FINDINGS"

# ---- scan set ------------------------------------------------------------
FILES=()
if [ "${#ARGFILES[@]}" -gt 0 ]; then
  for f in "${ARGFILES[@]}"; do
    case "$f" in /*) ;; *) f="$ORIG_PWD/$f" ;; esac
    if [ -f "$f" ] && [ -r "$f" ]; then FILES+=("$f"); else echo "warn: cannot read $f" >&2; fi
  done
  [ "${#FILES[@]}" -gt 0 ] || die64 "no readable FILE argument"
else
  while IFS= read -r f || [ -n "$f" ]; do FILES+=("${f#./}"); done < <(cd "$ROOT" && skill_lint_scan_set .)
  [ "${#FILES[@]}" -gt 0 ] || die64 "no .md file under $ROOT (commands, skills, agents)"
fi

# rel PATH: a path relative to the root when it lies under it
rel() {
  case "$1" in "$ROOT"/*) printf '%s' "${1#"$ROOT"/}" ;; *) printf '%s' "$1" ;; esac
}

# Engine file names are relative to the root (the engine runs from there), so
# every finding and every list row prints a short path.
RELFILES=()
for f in "${FILES[@]}"; do RELFILES+=("$(rel "$f")"); done

# ---- engine pass ---------------------------------------------------------
if ( cd "$ROOT" && FE_DUMP="$WORK/dump" awk -f "$SCAN_AWK" -f "$ENGINE" "${RELFILES[@]}" ) > "$TSV" 2> "$WORK/engine.err"; then :; else
  echo "$PROG: fence-check.awk failed; the fences were not checked — refusing to report a clean run" >&2
  head -5 "$WORK/engine.err" >&2
  exit 1
fi

if [ "$SUB" = "list" ]; then
  awk -F'\t' '$1 == "F" { printf "%s\t%s\t%s\t%s\t%s\n", $2, $3, $4, $5, $6 }' "$TSV"
  exit 0
fi

add_finding() { # add_finding CHECK FILE LINE HEADING MESSAGE
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$FINDINGS" || {
    echo "$PROG: cannot write the findings file" >&2; exit 1; }
}

# engine findings (F2, F3, F4)
while IFS=$'\t' read -r kind chk file line start heading msg || [ -n "$kind" ]; do
  [ "$kind" = "X" ] || continue
  add_finding "$chk" "$file" "$line" "$heading" "$msg"
done < "$TSV"

# F1: bash -n on each fence; the dump files hold the fence bodies
re_line='line ([0-9]+):'
while IFS=$'\t' read -r kind file start end heading info idx tmpl || [ -n "$kind" ]; do
  [ "$kind" = "F" ] || continue
  [ "$tmpl" = "1" ] && continue   # a template fence is pseudocode; the engine decides what one is
  if err=$(bash -n "$WORK/dump/$idx.sh" 2>&1 < /dev/null); then continue; fi
  first=$(printf '%s\n' "$err" | head -n 1)
  ln="$start"
  if [[ "$first" =~ $re_line ]]; then ln=$((start + BASH_REMATCH[1] - 1)); fi
  first="${first#"$WORK/dump/$idx.sh": }"
  add_finding "F1" "$file" "$ln" "$heading" "bash -n rejects this fence: $first"
done < "$TSV"

# F5: each path literal must exist under the root
while IFS=$'\t' read -r kind file line start heading pkind path || [ -n "$kind" ]; do
  [ "$kind" = "P" ] || continue
  if [ ! -e "$ROOT/$path" ]; then
    add_finding "F5" "$file" "$line" "$heading" "path literal $path does not exist in the repo ($pkind path) — the plugin ships no such file, so the command fails or reads an empty result"
  fi
done < "$TSV"

# ---- manifest ------------------------------------------------------------
EX_CHECK=(); EX_FILE=(); EX_NEEDLE=(); EX_COUNT=(); EX_SLUG=(); EX_REASON=(); EX_SEEN=()
SU_FILE=(); SU_HEAD=(); SU_PATH=(); SU_LINE=()
MANIFEST_REL=$(rel "${MANIFEST:-manifest}")

if [ -n "$MANIFEST" ] && [ -f "$MANIFEST" ]; then
  bad=$(awk -F'\t' '
    /^[ \t]*(#|$)/ { next }
    {
      for (i = 1; i <= NF; i++) if ($i == "") { printf "%d: empty field %d (every manifest field must hold text)\n", NR, i; next }
      if ($1 == "exclude") {
        if (NF != 7) { printf "%d: exclude row needs 7 tab-separated fields, has %d\n", NR, NF; next }
        if ($2 !~ /^F[1-5]$/) printf "%d: exclude check must be F1..F5, got %s\n", NR, $2
        if ($5 !~ /^[1-9][0-9]*$/) printf "%d: exclude count must be a positive integer, got %s\n", NR, $5
        if ($6 !~ /^[a-z0-9][a-z0-9-]*$/) printf "%d: exclude backlog slug must be lowercase words joined by -, got %s\n", NR, $6
      } else if ($1 == "suite") {
        if (NF != 5) printf "%d: suite row needs 5 tab-separated fields, has %d\n", NR, NF
      } else printf "%d: unknown row kind %s\n", NR, $1
    }
  ' "$MANIFEST")
  if [ -n "$bad" ]; then
    printf '%s\n' "$bad" | while IFS= read -r l || [ -n "$l" ]; do echo "$PROG: $MANIFEST_REL:$l" >&2; done
    exit 64
  fi
  lineno=0
  while IFS=$'\t' read -r k a b c d e f || [ -n "$k" ]; do
    lineno=$((lineno + 1))
    case "$k" in ''|'#'*) continue ;; esac
    if [ "$k" = "exclude" ]; then
      EX_CHECK+=("$a"); EX_FILE+=("$b"); EX_NEEDLE+=("$c"); EX_COUNT+=("$d"); EX_SLUG+=("$e"); EX_REASON+=("$f"); EX_SEEN+=(0)
    elif [ "$k" = "suite" ]; then
      SU_FILE+=("$a"); SU_HEAD+=("$b"); SU_PATH+=("$c"); SU_LINE+=("$lineno")
    fi
  done < "$MANIFEST"
elif [ -n "$MANIFEST" ]; then
  die64 "manifest $MANIFEST is not a file"
fi

# M1 for suite rows: the fence exists, and the suite names it
i=0
while [ "$i" -lt "${#SU_FILE[@]}" ]; do
  sf="${SU_FILE[$i]}"; sh="${SU_HEAD[$i]}"; sp="${SU_PATH[$i]}"; sl="${SU_LINE[$i]}"
  if [ ! -f "$ROOT/$sf" ]; then
    add_finding "M1" "$MANIFEST_REL" "$sl" "suite $sp" "suite row names $sf, which does not exist"
  elif [ -z "$(fence_blocks "$ROOT/$sf" "$sh")" ]; then
    add_finding "M1" "$MANIFEST_REL" "$sl" "suite $sp" "suite row: $sf has no bash fence under a heading that holds '$sh' (heading renamed or fence removed)"
  fi
  case "${sp##*/}" in
    test.sh|test-*.sh|*-test.sh) ;;
    *) add_finding "M1" "$MANIFEST_REL" "$sl" "suite $sp" "suite row: $sp is not a suite name the all-suites runner discovers (test.sh, test-*.sh, *-test.sh)" ;;
  esac
  if [ ! -f "$ROOT/$sp" ]; then
    add_finding "M1" "$MANIFEST_REL" "$sl" "suite $sp" "suite row names $sp, which does not exist"
  elif ! grep -qF -- "$sh" "$ROOT/$sp"; then
    add_finding "M1" "$MANIFEST_REL" "$sl" "suite $sp" "suite row: $sp never names the heading '$sh', so it does not run that fence"
  fi
  i=$((i + 1))
done

# exclusions: match each finding to the first exclusion that covers it
REPORT="$WORK/report.txt"
: > "$REPORT"
n_find=0
n_excl=0
while IFS=$'\t' read -r chk file line heading msg || [ -n "$chk" ]; do
  [ -n "$chk" ] || continue
  rfile=$(rel "$file")
  hit=-1
  i=0
  while [ "$i" -lt "${#EX_CHECK[@]}" ]; do
    if [ "${EX_CHECK[$i]}" = "$chk" ] && [ "${EX_FILE[$i]}" = "$rfile" ]; then
      case "$msg (section: $heading)" in *"${EX_NEEDLE[$i]}"*) hit=$i; break ;; esac
    fi
    i=$((i + 1))
  done
  if [ "$hit" -ge 0 ]; then
    EX_SEEN[$hit]=$((EX_SEEN[$hit] + 1))
    n_excl=$((n_excl + 1))
    continue
  fi
  n_find=$((n_find + 1))
  printf '%s:%s: [%s] %s (section: %s)\n' "$rfile" "$line" "$chk" "$msg" "$heading" >> "$REPORT"
done < "$FINDINGS"

i=0
while [ "$i" -lt "${#EX_CHECK[@]}" ]; do
  if [ "${EX_SEEN[$i]}" -ne "${EX_COUNT[$i]}" ]; then
    n_find=$((n_find + 1))
    printf '%s: [M1] exclusion %s %s "%s" matched %s finding(s), the manifest says %s — a fixed defect needs its row removed, a new one needs a backlog item and a new count\n' \
      "$MANIFEST_REL" "${EX_CHECK[$i]}" "${EX_FILE[$i]}" "${EX_NEEDLE[$i]}" "${EX_SEEN[$i]}" "${EX_COUNT[$i]}" >> "$REPORT"
  else
    printf 'excluded: [%s] %s, %s finding(s), backlog %s — %s\n' "${EX_CHECK[$i]}" "${EX_FILE[$i]}" "${EX_SEEN[$i]}" "${EX_SLUG[$i]}" "${EX_REASON[$i]}" >> "$REPORT"
  fi
  i=$((i + 1))
done

cat "$REPORT"
nf=$(grep -c '^F' "$TSV" || true)
printf '%d findings, %d excluded (%s fences in %d files)\n' "$n_find" "$n_excl" "$nf" "${#FILES[@]}"
rc=0
[ "$n_find" -eq 0 ] || rc=1
[ "$SUB" = "check" ] && exit "$rc"

# ---- run: manifest suites --------------------------------------------------
TMO="${FENCE_EXEC_TIMEOUT:-300}"
case "$TMO" in ''|*[!0-9]*) die64 "FENCE_EXEC_TIMEOUT must be a positive integer" ;; esac
ran=""
n_suite=0
n_fail=0
i=0
while [ "$i" -lt "${#SU_PATH[@]}" ]; do
  sp="${SU_PATH[$i]}"
  i=$((i + 1))
  case "
$ran
" in *"
$sp
"*) continue ;; esac
  ran="$ran
$sp"
  [ -f "$ROOT/$sp" ] || continue
  n_suite=$((n_suite + 1))
  out="$WORK/suite.$n_suite.out"
  if command -v timeout >/dev/null 2>&1; then
    ( cd "$ROOT" && timeout "$TMO" bash "$sp" ) < /dev/null > "$out" 2>&1
  else
    ( cd "$ROOT" && bash "$sp" ) < /dev/null > "$out" 2>&1
  fi
  src=$?
  if [ "$src" -eq 0 ]; then
    echo "PASS suite $sp"
  else
    n_fail=$((n_fail + 1))
    echo "FAIL suite $sp (rc=$src)"
    tail -n 20 "$out" | sed 's/^/    | /'
  fi
done
printf '%d suites, %d failed\n' "$n_suite" "$n_fail"
[ "$n_fail" -eq 0 ] || rc=1
exit "$rc"
