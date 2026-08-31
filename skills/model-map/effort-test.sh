#!/usr/bin/env bash
#
# model-map/effort-test.sh — SPEC-037 M22–M26 bite-tests for resolve-model.sh --effort (CDT-229)
#
# Machine-check: bash skills/model-map/effort-test.sh  (exit 0)
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RESOLVE="$SCRIPT_DIR/resolve-model.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/model-map-effort-test.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

git init -q "$TMP" || { echo "FAIL: git init" >&2; exit 1; }
cd "$TMP" || { echo "FAIL: cd $TMP" >&2; exit 1; }

OUTF="$TMP/stdout.txt"
ERRF="$TMP/stderr.txt"
MAP=".claude/dev-team/models.local.json"
REPO_MAP=".claude/dev-team/models.json"
FAKE_HOME="$TMP/home"
GLOBAL_MAP="$FAKE_HOME/.claude/dev-team/models.json"
mkdir -p "$FAKE_HOME"

run() {
  RC=0
  : >"$OUTF"
  : >"$ERRF"
  env HOME="$FAKE_HOME" bash "$RESOLVE" "$@" >"$OUTF" 2>"$ERRF" || RC=$?
}

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

write_repo() {
  mkdir -p .claude/dev-team
  cat >"$REPO_MAP"
}

write_global() {
  mkdir -p "$(dirname "$GLOBAL_MAP")"
  cat >"$GLOBAL_MAP"
}

rm_map() {
  rm -rf .claude
}

clear_layers() {
  rm -f "$MAP" "$REPO_MAP"
  rm -rf "$FAKE_HOME/.claude"
}

NOJQ_BIN="$TMP/nojq-bin"
mkdir -p "$NOJQ_BIN"
BASH_ABS=$(command -v bash)
for c in bash git dirname pwd; do
  p=$(command -v "$c" 2>/dev/null) || continue
  ln -sf "$p" "$NOJQ_BIN/$(basename "$p")"
done

# =============================================================================
# M24 — --effort missing agent → 64 + usage
# =============================================================================
run --effort
check "M24-usage" 64 "" "usage: resolve-model.sh --effort <agent>"

run --effort ""
check "M24-usage-empty" 64 "" "usage: resolve-model.sh --effort <agent>"

# =============================================================================
# M24 — trailing --effort ignored (model emit)
# =============================================================================
write_map <<'EOF'
{"version":1,"agents":{"ic4":"haiku"},"effort":{"ic4":"high"}}
EOF
run ic4 --effort
check "M24-trailing-flag" 0 "haiku" ""

# extra argv after --effort agent ignored
run --effort ic4 leftover
check "M24-extra-argv" 0 "high" ""

# =============================================================================
# M22 — absent file / absent effort / empty effort object: empty, no warn
# =============================================================================
rm_map
run --effort pm
check "M22-absent" 0 "" ""
if [ ! -e "$TMP/.claude" ] && [ ! -e "$FAKE_HOME/.claude" ]; then
  pass "M22-readonly"
else
  fail "M22-readonly created path under $TMP/.claude or $FAKE_HOME/.claude"
fi

write_map <<'EOF'
{"version":1,"agents":{"ic4":"haiku"}}
EOF
run --effort ic4
check "M22-no-effort-key" 0 "" ""

write_map <<'EOF'
{"version":1,"agents":{"ic4":"haiku"},"effort":{}}
EOF
run --effort ic4
check "M22-empty-object" 0 "" ""

# =============================================================================
# M23 — valid tokens, trim+lowercase
# =============================================================================
write_map <<'EOF'
{"version":1,"effort":{"ic4":"high"}}
EOF
run --effort ic4
check "M23-high" 0 "high" ""

write_map <<'EOF'
{"version":1,"effort":{"ic4":" HIGH "}}
EOF
run --effort ic4
check "M23-trim-lower" 0 "high" ""

write_map <<'EOF'
{"version":1,"effort":{"ic4":"low","pm":"medium","ic5":"xhigh","ds":"max"}}
EOF
run --effort ic4
check "M23-low" 0 "low" ""
run --effort pm
check "M23-medium" 0 "medium" ""
run --effort ic5
check "M23-xhigh" 0 "xhigh" ""
run --effort ds
check "M23-max" 0 "max" ""

# =============================================================================
# M25 — bad value fallthrough (null / non-string / empty / not in allowlist)
# =============================================================================
clear_layers
write_map <<'EOF'
{"version":1,"effort":{"ic4":null}}
EOF
write_repo <<'EOF'
{"version":1,"effort":{"ic4":"high"}}
EOF
run --effort ic4
check "M25-null-fallthrough" 0 "high" "effort.ic4 is not a valid effort token; using inherited effort"

write_map <<'EOF'
{"version":1,"effort":{"ic4":1}}
EOF
run --effort ic4
check "M25-num-fallthrough" 0 "high" "effort.ic4 is not a valid effort token; using inherited effort"

write_map <<'EOF'
{"version":1,"effort":{"ic4":""}}
EOF
run --effort ic4
check "M25-empty-fallthrough" 0 "high" "effort.ic4 is not a valid effort token; using inherited effort"

write_map <<'EOF'
{"version":1,"effort":{"ic4":"highest"}}
EOF
run --effort ic4
check "M25-alias-fallthrough" 0 "high" "effort.ic4 is not a valid effort token; using inherited effort"

write_map <<'EOF'
{"version":1,"effort":{"ic4":"xl"}}
EOF
run --effort ic4
check "M25-xl-fallthrough" 0 "high" "effort.ic4 is not a valid effort token; using inherited effort"

# no lower layer → empty + warn
clear_layers
write_map <<'EOF'
{"version":1,"effort":{"ic4":"nope"}}
EOF
run --effort ic4
check "M25-bad-omit" 0 "" "effort.ic4 is not a valid effort token; using inherited effort"

# =============================================================================
# M25 — effort not an object: skip effort, still resolve agents
# =============================================================================
clear_layers
write_map <<'EOF'
{"version":1,"agents":{"ic4":"haiku"},"effort":[]}
EOF
write_repo <<'EOF'
{"version":1,"effort":{"ic4":"high"}}
EOF
run ic4
check "M25-effort-not-obj-model" 0 "haiku" ""
run --effort ic4
check "M25-effort-not-obj-effort" 0 "high" "effort is not an object; using inherited effort"

# agents not an object must not poison --effort
clear_layers
write_map <<'EOF'
{"version":1,"agents":[],"effort":{"ic4":"max"}}
EOF
run --effort ic4
check "M25-agents-not-obj-effort" 0 "max" ""
run ic4
check "M25-agents-not-obj-model" 0 "" "agents is not an object; using Tier default"

# =============================================================================
# M25 — unparseable JSON: whole-layer skip, existing M6 prefix
# =============================================================================
clear_layers
write_map <<'EOF'
{
EOF
write_repo <<'EOF'
{"version":1,"effort":{"ic4":"low"}}
EOF
run --effort ic4
check "M25-unparseable" 0 "low" "unparseable JSON"
# CDT-231: field-aware suffix — effort mode says "inherited effort", not "Tier default".
if grep -F -q 'using inherited effort' "$ERRF"; then
  pass "M25-unparseable-m6-prefix"
else
  fail "M25-unparseable-m6-prefix err='$(cat "$ERRF")'"
fi

# =============================================================================
# M25 — per-field first-hit fixtures
# =============================================================================
clear_layers
write_map <<'EOF'
{"version":1,"agents":{"ic4":"haiku"}}
EOF
write_repo <<'EOF'
{"version":1,"agents":{"ic4":"sonnet"},"effort":{"ic4":"high"}}
EOF
run ic4
check "M25-fixture-model" 0 "haiku" ""
run --effort ic4
check "M25-fixture-effort" 0 "high" ""

clear_layers
write_map <<'EOF'
{"version":1,"effort":{"ic4":"low"}}
EOF
write_repo <<'EOF'
{"version":1,"agents":{"ic4":"sonnet"},"effort":{"ic4":"high"}}
EOF
run ic4
check "M25-inverse-model" 0 "sonnet" ""
run --effort ic4
check "M25-inverse-effort" 0 "low" ""

# local > repo > global for effort
clear_layers
write_map <<'EOF'
{"version":1,"effort":{"ic4":"high"}}
EOF
write_repo <<'EOF'
{"version":1,"effort":{"ic4":"low"}}
EOF
write_global <<'EOF'
{"version":1,"effort":{"ic4":"max"}}
EOF
run --effort ic4
check "M25-prec-local" 0 "high" ""
rm -f "$MAP"
run --effort ic4
check "M25-prec-repo" 0 "low" ""
rm -f "$REPO_MAP"
run --effort ic4
check "M25-prec-global" 0 "max" ""

# =============================================================================
# M25 — unknown effort key M7; other keys still resolve
# =============================================================================
clear_layers
write_map <<'EOF'
{"version":1,"effort":{"teh-lead":"max","ic4":"high"}}
EOF
run --effort ic4
check "M25-unknown-key" 0 "high" "unknown agent key 'teh-lead' ignored"

# --effort M7-scans effort keys only
write_map <<'EOF'
{"version":1,"agents":{"bogus":"haiku"},"effort":{"ic4":"high"}}
EOF
run --effort ic4
check "M25-effort-scan-only" 0 "high" ""

# model path M7-scans agents keys only
write_map <<'EOF'
{"version":1,"agents":{"ic4":"haiku"},"effort":{"bogus":"high"}}
EOF
run ic4
check "M25-model-scan-only" 0 "haiku" ""

# =============================================================================
# M25 — internals always empty; keys still M7-warn
# =============================================================================
write_map <<'EOF'
{"version":1,"effort":{"distiller":"max","project-init":"high"}}
EOF
run --effort distiller
check "M25-distiller" 0 "" "unknown agent key 'distiller' ignored"
run --effort project-init
check "M25-project-init" 0 "" "unknown agent key 'project-init' ignored"

# unknown argv
rm_map
run --effort nope
check "M25-unknown-agent" 0 "" "unknown agent 'nope'"

# =============================================================================
# M25 — jq absent: empty + existing warn; MUST NOT read layers
# =============================================================================
write_map <<'EOF'
{"version":1,"effort":{"ic4":"high"}}
EOF
RC=0
: >"$OUTF"
: >"$ERRF"
env HOME="$FAKE_HOME" PATH="$NOJQ_BIN" "$BASH_ABS" "$RESOLVE" --effort ic4 >"$OUTF" 2>"$ERRF" || RC=$?
# CDT-231: field-aware suffix — effort mode says "inherited effort", not "Tier default".
check "M25-jq" 0 "" "jq not found; using inherited effort"

# =============================================================================
# M26 — winning qa/council-judge effort emits + M9 once; empty → no M9
# =============================================================================
clear_layers
write_map <<'EOF'
{"version":1,"effort":{"qa":"max"}}
EOF
run --effort qa
check "M26-qa" 0 "max" "override for adversarial role 'qa'"
n=$(grep -cF "override for adversarial role" "$ERRF" || true)
if [ "$n" -eq 1 ]; then
  pass "M26-qa-m9-once"
else
  fail "M26-qa-m9-once count=$n err='$(cat "$ERRF")'"
fi

write_map <<'EOF'
{"version":1,"effort":{"council-judge":"low"}}
EOF
run --effort council-judge
check "M26-cj" 0 "low" "override for adversarial role 'council-judge'"

# empty effort for qa: no M9 even if agents.qa is set
write_map <<'EOF'
{"version":1,"agents":{"qa":"cheap"}}
EOF
run --effort qa
check "M26-qa-empty" 0 "" ""
run qa
check "M26-qa-model-still-m9" 0 "cheap" "override for adversarial role 'qa'"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
