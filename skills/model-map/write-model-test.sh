#!/usr/bin/env bash
#
# write-model-test.sh — SPEC-037 bite-tests for write-model.sh (CDT-228)
#
# Machine-check: bash skills/model-map/write-model-test.sh  (exit 0)
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
WRITE="$SCRIPT_DIR/write-model.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/write-model-test.XXXXXX")
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
  env HOME="$FAKE_HOME" bash "$WRITE" "$@" >"$OUTF" 2>"$ERRF" || RC=$?
}

got_out() { cat "$OUTF"; }
got_err() { cat "$ERRF"; }

check_rc() {
  local id=$1 want=$2
  if [ "$RC" -eq "$want" ]; then
    pass "$id"
  else
    fail "$id rc=$RC (want $want) out='$(got_out)' err='$(got_err)'"
  fi
}

NOJQ_BIN="$TMP/nojq-bin"
mkdir -p "$NOJQ_BIN"
BASH_ABS=$(command -v bash)
for c in bash git dirname pwd mktemp mv rm mkdir cat chmod; do
  p=$(command -v "$c" 2>/dev/null) || continue
  ln -sf "$p" "$NOJQ_BIN/$(basename "$p")"
done

# =============================================================================
# Bad argv → 64 + usage
# =============================================================================
run
check_rc "argv-none" 64
if grep -qF 'usage: write-model.sh' "$ERRF"; then
  pass "argv-none-usage"
else
  fail "argv-none-usage err='$(got_err)'"
fi

run foo
check_rc "argv-unknown-sub" 64

run set
check_rc "argv-set-no-agent" 64

run set pm
check_rc "argv-set-no-string" 64

run unset
check_rc "argv-unset-no-agent" 64

run set distiller grok
check_rc "argv-set-internal" 64

run set nope grok
check_rc "argv-set-unknown-agent" 64

run unset distiller
check_rc "argv-unset-internal" 64

run set pm "   "
check_rc "argv-set-blank" 64
if [ -e "$MAP" ]; then
  fail "argv-set-blank created $MAP"
else
  pass "argv-set-blank-nowrite"
fi

# =============================================================================
# list — read-only, 8 agents, Tier default, local path
# =============================================================================
run list extra-ignored
check_rc "list-extra-argv" 0
LIST=$(got_out)
if grep -qF "local: $TMP/.claude/dev-team/models.local.json" "$OUTF"; then
  pass "list-local-path"
else
  fail "list-local-path out='$LIST'"
fi
missing=""
for a in pm tech-lead ic5 ic4 devops qa ds council-judge; do
  echo "$LIST" | grep -Eq "^${a}[[:space:]]+Tier default$" || missing="$missing $a"
done
if [ -z "$missing" ]; then
  pass "list-eight-tier-default"
else
  fail "list-eight-tier-default missing:$missing out='$LIST'"
fi
if [ ! -e "$TMP/.claude" ] && [ ! -e "$FAKE_HOME/.claude" ]; then
  pass "list-readonly"
else
  fail "list-readonly created paths"
fi

# =============================================================================
# set — create parent dirs, merge, trim; extra argv ignored
# =============================================================================
run set pm " grok-4 " leftover
check_rc "set-pm" 0
if [ -f "$MAP" ] && [ "$(jq -r '.version' "$MAP")" = "1" ] \
   && [ "$(jq -r '.agents.pm' "$MAP")" = "grok-4" ]; then
  pass "set-pm-trim-write"
else
  fail "set-pm-trim-write map=$(cat "$MAP" 2>/dev/null)"
fi
if [ -f "$REPO_MAP" ] || [ -f "$GLOBAL_MAP" ]; then
  fail "set-pm wrote repo/global"
else
  pass "set-pm-local-only"
fi

run list
if grep -Eq '^pm[[:space:]]+grok-4$' "$OUTF"; then
  pass "list-after-set-pm"
else
  fail "list-after-set-pm out='$(got_out)'"
fi
if grep -Eq '^ic4[[:space:]]+Tier default$' "$OUTF"; then
  pass "list-omitted-still-default"
else
  fail "list-omitted-still-default out='$(got_out)'"
fi

# merge preserves other keys + extra top-level
mkdir -p .claude/dev-team
cat >"$MAP" <<'EOF'
{"version":1,"agents":{"ic4":"keep-me"},"extra":true}
EOF
run set pm from-set
check_rc "set-merge" 0
if [ "$(jq -r '.agents.ic4' "$MAP")" = "keep-me" ] \
   && [ "$(jq -r '.agents.pm' "$MAP")" = "from-set" ] \
   && [ "$(jq -r '.extra' "$MAP")" = "true" ]; then
  pass "set-merge-preserve"
else
  fail "set-merge-preserve map=$(cat "$MAP")"
fi

# =============================================================================
# set qa / council-judge — allowed + M9 warn
# =============================================================================
run set qa cheap
check_rc "set-qa" 0
if grep -qF "override for adversarial role 'qa'" "$ERRF"; then
  pass "set-qa-m9"
else
  fail "set-qa-m9 err='$(got_err)'"
fi
if [ "$(jq -r '.agents.qa' "$MAP")" = "cheap" ]; then
  pass "set-qa-wrote"
else
  fail "set-qa-wrote map=$(cat "$MAP")"
fi

run set council-judge x
check_rc "set-cj" 0
if grep -qF "override for adversarial role 'council-judge'" "$ERRF"; then
  pass "set-cj-m9"
else
  fail "set-cj-m9 err='$(got_err)'"
fi

# =============================================================================
# unset — delete key; missing key OK; extra argv ignored
# =============================================================================
run unset pm leftover
check_rc "unset-pm" 0
if [ "$(jq -r '.agents.pm // empty' "$MAP")" = "" ] \
   && [ "$(jq -r '.agents.ic4' "$MAP")" = "keep-me" ]; then
  pass "unset-pm-leave-others"
else
  fail "unset-pm-leave-others map=$(cat "$MAP")"
fi

run unset pm
check_rc "unset-missing-ok" 0

run unset nope
check_rc "unset-unknown-agent" 64

# =============================================================================
# unparseable existing → refuse set/unset, exit 1, file unchanged
# =============================================================================
printf '{\n' >"$MAP"
BEFORE=$(cksum "$MAP")
run set ic5 grok
check_rc "set-unparseable" 1
if grep -qi 'unparseable' "$ERRF"; then
  pass "set-unparseable-warn"
else
  fail "set-unparseable-warn err='$(got_err)'"
fi
AFTER=$(cksum "$MAP")
if [ "$BEFORE" = "$AFTER" ]; then
  pass "set-unparseable-nowrite"
else
  fail "set-unparseable-nowrite file mutated"
fi

run unset ic4
check_rc "unset-unparseable" 1
AFTER=$(cksum "$MAP")
if [ "$BEFORE" = "$AFTER" ]; then
  pass "unset-unparseable-nowrite"
else
  fail "unset-unparseable-nowrite file mutated"
fi

# agents not an object → refuse
printf '%s\n' '{"version":1,"agents":[]}' >"$MAP"
BEFORE=$(cksum "$MAP")
run set pm grok
check_rc "set-agents-array" 1
AFTER=$(cksum "$MAP")
if [ "$BEFORE" = "$AFTER" ]; then
  pass "set-agents-array-nowrite"
else
  fail "set-agents-array-nowrite file mutated"
fi

# =============================================================================
# never write repo / global even when they exist
# =============================================================================
mkdir -p .claude/dev-team "$(dirname "$GLOBAL_MAP")"
printf '%s\n' '{"version":1,"agents":{"pm":"from-repo"}}' >"$REPO_MAP"
printf '%s\n' '{"version":1,"agents":{"pm":"from-global"}}' >"$GLOBAL_MAP"
printf '%s\n' '{"version":1,"agents":{}}' >"$MAP"
REPO_H=$(cksum "$REPO_MAP")
GLOB_H=$(cksum "$GLOBAL_MAP")
run set ic5 local-only
check_rc "set-ic5-layers" 0
if [ "$(cksum "$REPO_MAP")" = "$REPO_H" ] && [ "$(cksum "$GLOBAL_MAP")" = "$GLOB_H" ]; then
  pass "set-never-repo-global"
else
  fail "set-never-repo-global repo/global mutated"
fi
if [ "$(jq -r '.agents.ic5' "$MAP")" = "local-only" ]; then
  pass "set-ic5-local"
else
  fail "set-ic5-local map=$(cat "$MAP")"
fi

# list uses resolve-model.sh (repo wins when local omits)
printf '%s\n' '{"version":1,"agents":{}}' >"$MAP"
run list
if grep -Eq '^pm[[:space:]]+from-repo$' "$OUTF"; then
  pass "list-calls-resolve-repo"
else
  fail "list-calls-resolve-repo out='$(got_out)'"
fi

# =============================================================================
# git-common-dir MROOT: subdir set writes MROOT local, not cwd copy
# =============================================================================
mkdir -p "$TMP/sub"
cd "$TMP/sub" || { fail "cd sub"; cd "$TMP"; }
run set devops from-sub
cd "$TMP" || true
check_rc "set-from-subdir" 0
if [ -f "$MAP" ] && [ "$(jq -r '.agents.devops' "$MAP")" = "from-sub" ] \
   && [ ! -e "$TMP/sub/.claude/dev-team/models.local.json" ]; then
  pass "set-mroot-not-subdir"
else
  fail "set-mroot-not-subdir map=$(cat "$MAP" 2>/dev/null) sub=$(ls "$TMP/sub/.claude" 2>/dev/null)"
fi

# =============================================================================
# jq missing: set/unset exit 1; list still tries resolve
# =============================================================================
cd "$TMP" || true
printf '%s\n' '{"version":1,"agents":{"pm":"keep"}}' >"$MAP"
RC=0
: >"$OUTF"
: >"$ERRF"
env HOME="$FAKE_HOME" PATH="$NOJQ_BIN" "$BASH_ABS" "$WRITE" set ic4 x >"$OUTF" 2>"$ERRF" || RC=$?
if [ "$RC" -eq 1 ] && grep -qi 'jq not found' "$ERRF"; then
  pass "set-no-jq"
else
  fail "set-no-jq rc=$RC err='$(got_err)'"
fi
if [ "$(jq -r '.agents.ic4 // empty' "$MAP")" = "" ]; then
  pass "set-no-jq-nowrite"
else
  fail "set-no-jq-nowrite map=$(cat "$MAP")"
fi

RC=0
: >"$OUTF"
: >"$ERRF"
env HOME="$FAKE_HOME" PATH="$NOJQ_BIN" "$BASH_ABS" "$WRITE" unset pm >"$OUTF" 2>"$ERRF" || RC=$?
if [ "$RC" -eq 1 ]; then
  pass "unset-no-jq"
else
  fail "unset-no-jq rc=$RC err='$(got_err)'"
fi

RC=0
: >"$OUTF"
: >"$ERRF"
env HOME="$FAKE_HOME" PATH="$NOJQ_BIN" "$BASH_ABS" "$WRITE" list >"$OUTF" 2>"$ERRF" || RC=$?
if [ "$RC" -eq 0 ] && grep -Eq '^pm[[:space:]]+' "$OUTF"; then
  pass "list-no-jq"
else
  fail "list-no-jq rc=$RC out='$(got_out)' err='$(got_err)'"
fi

# =============================================================================
# Surface: /setup usage lists models; adjust-agent has --model sugar
# =============================================================================
if grep -qE 'project\|orchestration\|team\|models' "$ROOT/commands/setup.md" \
   && grep -qF 'models' "$ROOT/commands/setup.md"; then
  pass "setup-usage-models"
else
  fail "setup-usage-models missing from commands/setup.md"
fi
if grep -qF -- '--model' "$ROOT/commands/adjust-agent.md" \
   && grep -qF -- '--model-unset' "$ROOT/commands/adjust-agent.md"; then
  pass "adjust-agent-model-sugar"
else
  fail "adjust-agent-model-sugar missing from commands/adjust-agent.md"
fi
if grep -qF 'write-model.sh' "$ROOT/commands/setup.md" \
   && grep -qF 'write-model.sh' "$ROOT/commands/adjust-agent.md"; then
  pass "surface-delegates-writer"
else
  fail "surface-delegates-writer"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
