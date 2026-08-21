#!/usr/bin/env bash
# detached-packet-test.sh — CDT-204 / SPEC-018 M19 Test 39 AC8 packet identity.
# Same miner-event fixture through finalize twice (stand-in for detached vs
# current finalize — engines frozen). Byte-identical modulo timestamp/filename.
# Run: bash skills/handoff/detached-packet-test.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PREPASS="$HERE/prepass.sh"
FIX="$HERE/fixtures"
THRASH="$FIX/events-thrash.json"
GITBLOB="$FIX/git-state.txt"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/detached-packet-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# Strip captured_at ISO + YYYYMMDD-HHmm (header/path clock). Fixture event
# timestamps are ISO dates without that filename shape — left intact.
normalize_packet() {
  sed -E \
    -e 's/captured_at: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z/captured_at: TS/g' \
    -e 's/[0-9]{8}-[0-9]{4}/YYYYMMDD-HHmm/g'
}

run_finalize() {
  local dir="$1" out="$2"
  mkdir -p "$dir/handoff"
  env -u HANDOFF_LIGHT -u LIGHT HANDOFF_DIR="$dir/handoff" bash "$PREPASS" finalize \
    --uuid "cdt204-packet-id" \
    --events "$THRASH" \
    --git-state "$GITBLOB" \
    --leaf "leaf-cdt204-ac8" \
    --slug packet-id \
    --mode cold \
    --packet-out "$out" \
    >"$dir/stdout" 2>"$dir/stderr"
}

# ---- T0: fixtures ----
if [ -x "$PREPASS" ] && [ -f "$THRASH" ] && [ -f "$GITBLOB" ]; then ok
else bad "T0 missing PREPASS/fixtures"; fi

# ---- AC8: two isolated finalize invocations, identical args ----
A="$WORK/a"
B="$WORK/b"
set +e
run_finalize "$A" "$A/packet.md"
RC_A=$?
run_finalize "$B" "$B/packet.md"
RC_B=$?
set -e

if [ "$RC_A" -eq 0 ] && [ -f "$A/packet.md" ]; then ok
else bad "AC8a first finalize rc=$RC_A err=$(head -c 200 "$A/stderr" 2>/dev/null)"; fi

if [ "$RC_B" -eq 0 ] && [ -f "$B/packet.md" ]; then ok
else bad "AC8b second finalize rc=$RC_B err=$(head -c 200 "$B/stderr" 2>/dev/null)"; fi

if grep -q '## State now' "$A/packet.md" \
   && grep -q '## Through-line' "$A/packet.md" \
   && grep -q '## appendix' "$A/packet.md"; then ok
else bad "AC8c first packet missing STM headers"; fi

normalize_packet <"$A/packet.md" >"$WORK/a.norm"
normalize_packet <"$B/packet.md" >"$WORK/b.norm"
if cmp -s "$WORK/a.norm" "$WORK/b.norm"; then ok
else
  bad "AC8d packet bodies differ after timestamp/filename normalize"
  diff -u "$WORK/a.norm" "$WORK/b.norm" | head -n 40
fi

# Auto-path pair (filename clock in path; isolated dirs → no Supersedes).
set +e
mkdir -p "$WORK/c/handoff" "$WORK/d/handoff"
env -u HANDOFF_LIGHT -u LIGHT HANDOFF_DIR="$WORK/c/handoff" bash "$PREPASS" finalize \
  --uuid "cdt204-auto-id" \
  --events "$THRASH" \
  --git-state "$GITBLOB" \
  --leaf "leaf-cdt204-auto" \
  --slug auto-id \
  --mode warm \
  >"$WORK/c/stdout" 2>"$WORK/c/stderr"
RC_C=$?
env -u HANDOFF_LIGHT -u LIGHT HANDOFF_DIR="$WORK/d/handoff" bash "$PREPASS" finalize \
  --uuid "cdt204-auto-id" \
  --events "$THRASH" \
  --git-state "$GITBLOB" \
  --leaf "leaf-cdt204-auto" \
  --slug auto-id \
  --mode warm \
  >"$WORK/d/stdout" 2>"$WORK/d/stderr"
RC_D=$?
set -e

PKT_C=$(find "$WORK/c/handoff" -maxdepth 1 -name '*.md' ! -name '*precompact*' | head -1)
PKT_D=$(find "$WORK/d/handoff" -maxdepth 1 -name '*.md' ! -name '*precompact*' | head -1)
if [ "$RC_C" -eq 0 ] && [ "$RC_D" -eq 0 ] && [ -n "$PKT_C" ] && [ -n "$PKT_D" ]; then ok
else bad "AC8e auto-path finalize rcC=$RC_C rcD=$RC_D c=$PKT_C d=$PKT_D"; fi

BASE_C=$(basename -- "${PKT_C:-}")
BASE_D=$(basename -- "${PKT_D:-}")
NORM_C=$(printf '%s' "$BASE_C" | sed -E 's/[0-9]{8}-[0-9]{4}/YYYYMMDD-HHmm/')
NORM_D=$(printf '%s' "$BASE_D" | sed -E 's/[0-9]{8}-[0-9]{4}/YYYYMMDD-HHmm/')
if [ -n "$PKT_C" ] && [ "$NORM_C" = "$NORM_D" ] \
   && printf '%s' "$NORM_C" | grep -qE '^YYYYMMDD-HHmm-cdt204-auto-id-auto-id\.md$'; then ok
else bad "AC8f auto filename identity modulo YYYYMMDD-HHmm c=$BASE_C d=$BASE_D"; fi

if [ -n "$PKT_C" ] && [ -n "$PKT_D" ]; then
  normalize_packet <"$PKT_C" >"$WORK/c.norm"
  normalize_packet <"$PKT_D" >"$WORK/d.norm"
  if cmp -s "$WORK/c.norm" "$WORK/d.norm"; then ok
  else
    bad "AC8g auto-path packet bodies differ after normalize"
    diff -u "$WORK/c.norm" "$WORK/d.norm" | head -n 40
  fi
else
  bad "AC8g skipped — auto packets missing"
fi

echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
  exit 0
fi
exit 1
