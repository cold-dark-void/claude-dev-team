#!/usr/bin/env bash
#
# model-map/test.sh — SPEC-037 bite-tests for resolve-model.sh (CDT-222)
#
# Machine-check: bash skills/model-map/test.sh  (exit 0)
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RESOLVE="$SCRIPT_DIR/resolve-model.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/model-map-test.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

git init -q "$TMP" || { echo "FAIL: git init" >&2; exit 1; }
cd "$TMP" || { echo "FAIL: cd $TMP" >&2; exit 1; }

OUTF="$TMP/stdout.txt"
ERRF="$TMP/stderr.txt"
MAP=".claude/dev-team/models.local.json"

run() {
  RC=0
  : >"$OUTF"
  : >"$ERRF"
  bash "$RESOLVE" "$@" >"$OUTF" 2>"$ERRF" || RC=$?
}

# Compare via $(cat): callers use MODEL=$(bash resolve-model.sh …).
# Empty and a lone trailing newline are equivalent (SPEC-037 SHOULD).
check() {
  local id=$1 want_rc=$2 want_out=$3 want_err=${4-}
  local got_out got_err ok=1
  got_out=$(cat "$OUTF")
  got_err=$(cat "$ERRF")
  [ "$RC" -eq "$want_rc" ] || ok=0
  [ "$got_out" = "$want_out" ] || ok=0
  if [ -z "$want_err" ]; then
    [ -z "$got_err" ] || ok=0
  else
    printf '%s\n' "$got_err" | grep -F -q -- "$want_err" || ok=0
  fi
  if [ "$ok" -eq 1 ]; then
    pass "$id"
  else
    fail "$id rc=$RC (want $want_rc) out='$got_out' (want '$want_out') err='$got_err' (need '$want_err')"
  fi
}

write_map() {
  mkdir -p .claude/dev-team
  cat >"$MAP"
}

rm_map() {
  rm -rf .claude
}

NOJQ_BIN="$TMP/nojq-bin"
mkdir -p "$NOJQ_BIN"
BASH_ABS=$(command -v bash)
for c in bash git dirname pwd; do
  p=$(command -v "$c" 2>/dev/null) || continue
  ln -sf "$p" "$NOJQ_BIN/$(basename "$p")"
done

# =============================================================================
# AC8 / M5 — missing argv → 64 + usage
# =============================================================================
run
check "AC8" 64 "" "usage: resolve-model.sh <agent>"

# =============================================================================
# AC3a / M3 + AC14 / M10 — absent file: empty, no warn, no create
# =============================================================================
rm_map
run pm
check "AC3a" 0 "" ""
if [ ! -e "$TMP/.claude" ] && [ ! -f "$TMP/.claude/dev-team/models.local.json" ]; then
  pass "AC14"
else
  fail "AC14 created path under $TMP/.claude"
fi

# =============================================================================
# AC3b / M3 — empty agents object
# =============================================================================
write_map <<'EOF'
{"version":1,"agents":{}}
EOF
run pm
check "AC3b" 0 "" ""

# =============================================================================
# AC4 / M4 — trim + stdout/stderr split
# =============================================================================
write_map <<'EOF'
{"version":1,"agents":{"pm":" grok-4 "}}
EOF
run pm
check "AC4" 0 "grok-4" ""

# =============================================================================
# AC5 / M4 — partial map: listed emits; omitted empty, no warn
# =============================================================================
write_map <<'EOF'
{"version":1,"agents":{"ic4":"grok-code-fast-1"}}
EOF
run ic4
check "AC5-ic4" 0 "grok-code-fast-1" ""
run pm
check "AC5-pm" 0 "" ""

# =============================================================================
# AC10 / M6 — unparseable JSON
# =============================================================================
write_map <<'EOF'
{
EOF
run pm
check "AC10-json" 0 "" "unparseable JSON"

# =============================================================================
# AC10 / M6 — agents not an object
# =============================================================================
write_map <<'EOF'
{"version":1,"agents":[]}
EOF
run pm
check "AC10-type" 0 "" "not an object"

# =============================================================================
# AC10 / M6 — value null / empty string / number
# =============================================================================
write_map <<'EOF'
{"version":1,"agents":{"pm":null}}
EOF
run pm
check "AC10-val-null" 0 "" "not a non-empty string"

write_map <<'EOF'
{"version":1,"agents":{"pm":""}}
EOF
run pm
check "AC10-val-empty" 0 "" "not a non-empty string"

write_map <<'EOF'
{"version":1,"agents":{"pm":1}}
EOF
run pm
check "AC10-val-num" 0 "" "not a non-empty string"

# =============================================================================
# AC10 / M6 — jq absent from PATH
# =============================================================================
write_map <<'EOF'
{"version":1,"agents":{"pm":"grok-4"}}
EOF
RC=0
: >"$OUTF"
: >"$ERRF"
env PATH="$NOJQ_BIN" "$BASH_ABS" "$RESOLVE" pm >"$OUTF" 2>"$ERRF" || RC=$?
check "AC10-jq" 0 "" "jq not found"

# =============================================================================
# AC11 / M7 — unknown key warns; other keys still resolve
# =============================================================================
write_map <<'EOF'
{"version":1,"agents":{"teh-lead":"nope","pm":"grok-4"}}
EOF
run pm
check "AC11" 0 "grok-4" "unknown agent key 'teh-lead' ignored"

# =============================================================================
# AC12 / M8 — distiller argv empty; key present still M7-warns
# =============================================================================
write_map <<'EOF'
{"version":1,"agents":{"distiller":"haiku"}}
EOF
run distiller
check "AC12" 0 "" "unknown agent key 'distiller' ignored"

# =============================================================================
# AC12b / M8 — unknown argv agent
# =============================================================================
rm_map
run nope
check "AC12b" 0 "" "unknown agent 'nope'"

# =============================================================================
# AC13 / M9 — qa emits + adversarial warn
# =============================================================================
write_map <<'EOF'
{"version":1,"agents":{"qa":"cheap"}}
EOF
run qa
check "AC13" 0 "cheap" "override for adversarial role 'qa'"

# =============================================================================
# AC13b / M9 — council-judge emits + adversarial warn
# =============================================================================
write_map <<'EOF'
{"version":1,"agents":{"council-judge":"x"}}
EOF
run "council-judge"
check "AC13b" 0 "x" "override for adversarial role 'council-judge'"

# =============================================================================
# AC15 / M11 — sibling models.json + DEVTEAM_MODEL_* ignored
# =============================================================================
write_map <<'EOF'
{"version":1,"agents":{"pm":"from-local"}}
EOF
printf '%s\n' '{"version":1,"agents":{"pm":"from-sibling"}}' >.claude/dev-team/models.json
RC=0
: >"$OUTF"
: >"$ERRF"
env DEVTEAM_MODEL_pm=from-env bash "$RESOLVE" pm >"$OUTF" 2>"$ERRF" || RC=$?
check "AC15" 0 "from-local" ""

# =============================================================================
# AC1 / M1 — worktree/subdir copy ignored; git-common-dir MROOT wins
# =============================================================================
write_map <<'EOF'
{"version":1,"agents":{"pm":"from-mroot"}}
EOF
mkdir -p "$TMP/wt/.claude/dev-team"
printf '%s\n' '{"version":1,"agents":{"pm":"from-wt"}}' >"$TMP/wt/.claude/dev-team/models.local.json"
cd "$TMP/wt" || { fail "AC1 cd wt"; cd "$TMP"; }
run pm
cd "$TMP" || true
check "AC1" 0 "from-mroot" ""

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
