#!/usr/bin/env bash
#
# effort-write-test.sh — SPEC-037 M18 bite-tests for write-model.sh
# set-effort / unset-effort / list (CDT-229)
#
# Machine-check: bash skills/model-map/effort-write-test.sh  (exit 0)
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WRITE="$SCRIPT_DIR/write-model.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/effort-write-test.XXXXXX")
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
for c in bash git dirname pwd mktemp mv rm mkdir cat chmod tr; do
  p=$(command -v "$c" 2>/dev/null) || continue
  ln -sf "$p" "$NOJQ_BIN/$(basename "$p")"
done

# =============================================================================
# Bad argv → 64 + usage; no write (M18)
# =============================================================================
run set-effort
check_rc "argv-set-effort-no-agent" 64
if grep -qF 'usage: write-model.sh' "$ERRF"; then
  pass "argv-set-effort-usage"
else
  fail "argv-set-effort-usage err='$(got_err)'"
fi

run set-effort ic4
check_rc "argv-set-effort-no-token" 64

run unset-effort
check_rc "argv-unset-effort-no-agent" 64

run set-effort distiller high
check_rc "argv-set-effort-internal" 64

run set-effort nope high
check_rc "argv-set-effort-unknown-agent" 64

run unset-effort distiller
check_rc "argv-unset-effort-internal" 64

run unset-effort nope
check_rc "argv-unset-effort-unknown-agent" 64

run set-effort ic4 "   "
check_rc "argv-set-effort-blank" 64
if [ -e "$MAP" ]; then
  fail "argv-set-effort-blank created $MAP"
else
  pass "argv-set-effort-blank-nowrite"
fi

run set-effort ic4 xl
check_rc "argv-set-effort-alias" 64
run set-effort ic4 extreme
check_rc "argv-set-effort-invalid" 64
run set-effort ic4 LOWX
check_rc "argv-set-effort-not-allowlist" 64
if [ -e "$MAP" ]; then
  fail "argv-set-effort-invalid created $MAP"
else
  pass "argv-set-effort-invalid-nowrite"
fi

# =============================================================================
# AC14 — list read-only; 10 M8 names; Tier default + inherited (M18)
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
for a in pm tech-lead ic5 ic4 devops qa ds council-judge finder debugger; do
  echo "$LIST" | grep -Eq "^${a}[[:space:]]+Tier default[[:space:]]+inherited$" \
    || missing="$missing $a"
done
if [ -z "$missing" ]; then
  pass "AC14-list-ten-inherited"
else
  fail "AC14-list-ten-inherited missing:$missing out='$LIST'"
fi
want_pm=$(printf '%-14s %-16s %s\n' pm "Tier default" inherited)
got_pm=$(echo "$LIST" | grep -E '^pm[[:space:]]')
if [ "$got_pm" = "$want_pm" ]; then
  pass "list-printf-columns"
else
  fail "list-printf-columns got='$got_pm' want='$want_pm'"
fi
if [ ! -e "$TMP/.claude" ] && [ ! -e "$FAKE_HOME/.claude" ]; then
  pass "AC14-list-readonly"
else
  fail "AC14-list-readonly created paths"
fi

# =============================================================================
# set-effort — create, trim+lowercase, extra argv ignored (M18)
# =============================================================================
run set-effort ic4 " HIGH " leftover
check_rc "set-effort-ic4" 0
if [ -f "$MAP" ] && [ "$(jq -r '.effort.ic4' "$MAP")" = "high" ] \
   && [ "$(jq -r '.version' "$MAP")" = "1" ]; then
  pass "set-effort-trim-lower-write"
else
  fail "set-effort-trim-lower-write map=$(cat "$MAP" 2>/dev/null)"
fi
if jq -e '.agents' "$MAP" >/dev/null 2>&1; then
  fail "set-effort-no-agents-key map=$(cat "$MAP")"
else
  pass "set-effort-no-model-key"
fi
if [ -f "$REPO_MAP" ] || [ -f "$GLOBAL_MAP" ]; then
  fail "set-effort wrote repo/global"
else
  pass "set-effort-local-only"
fi

for tok in low medium high xhigh max; do
  run set-effort ds "$tok"
  if [ "$RC" -eq 0 ] && [ "$(jq -r '.effort.ds' "$MAP")" = "$tok" ]; then
    pass "set-effort-token-$tok"
  else
    fail "set-effort-token-$tok rc=$RC map=$(cat "$MAP")"
  fi
done

# =============================================================================
# Cross-field preserve (M18): set-effort keeps agents; set keeps effort
# =============================================================================
mkdir -p .claude/dev-team
cat >"$MAP" <<'EOF'
{"version":1,"agents":{"ic4":"haiku"},"extra":true}
EOF
run set-effort ic4 max
check_rc "set-effort-keep-agents" 0
if jq -e '.agents.ic4 == "haiku"' "$MAP" >/dev/null 2>&1 \
   && [ "$(jq -r '.effort.ic4' "$MAP")" = "max" ] \
   && [ "$(jq -r '.extra' "$MAP")" = "true" ]; then
  pass "AC15-set-effort-preserves-agents"
else
  fail "AC15-set-effort-preserves-agents map=$(cat "$MAP")"
fi

run set ic5 sonnet
check_rc "set-keep-effort" 0
if jq -e '.effort.ic4 == "max"' "$MAP" >/dev/null 2>&1 \
   && [ "$(jq -r '.agents.ic5' "$MAP")" = "sonnet" ] \
   && [ "$(jq -r '.agents.ic4' "$MAP")" = "haiku" ]; then
  pass "AC15-set-preserves-effort"
else
  fail "AC15-set-preserves-effort map=$(cat "$MAP")"
fi

# =============================================================================
# AC13 — qa / council-judge set-effort writes + M9 (M18 / M26)
# =============================================================================
run set-effort qa max
check_rc "set-effort-qa" 0
if grep -qF "override for adversarial role 'qa'" "$ERRF"; then
  pass "AC13-set-effort-qa-m9"
else
  fail "AC13-set-effort-qa-m9 err='$(got_err)'"
fi
if [ "$(jq -r '.effort.qa' "$MAP")" = "max" ]; then
  pass "AC13-set-effort-qa-wrote"
else
  fail "AC13-set-effort-qa-wrote map=$(cat "$MAP")"
fi

run set-effort council-judge low
check_rc "set-effort-cj" 0
if grep -qF "override for adversarial role 'council-judge'" "$ERRF"; then
  pass "AC13-set-effort-cj-m9"
else
  fail "AC13-set-effort-cj-m9 err='$(got_err)'"
fi
if [ "$(jq -r '.effort["council-judge"]' "$MAP")" = "low" ]; then
  pass "AC13-set-effort-cj-wrote"
else
  fail "AC13-set-effort-cj-wrote map=$(cat "$MAP")"
fi

# =============================================================================
# unset-effort — delete key; missing OK; does not drop agents (M18)
# =============================================================================
run unset-effort ic4 leftover
check_rc "unset-effort-ic4" 0
if [ "$(jq -r '.effort.ic4 // empty' "$MAP")" = "" ] \
   && [ "$(jq -r '.effort.qa' "$MAP")" = "max" ] \
   && [ "$(jq -r '.agents.ic4' "$MAP")" = "haiku" ]; then
  pass "unset-effort-leave-others"
else
  fail "unset-effort-leave-others map=$(cat "$MAP")"
fi

run unset-effort ic4
check_rc "unset-effort-missing-ok" 0

run unset ic4
check_rc "unset-model-keep-effort" 0
if [ "$(jq -r '.agents.ic4 // empty' "$MAP")" = "" ] \
   && [ "$(jq -r '.effort.qa' "$MAP")" = "max" ]; then
  pass "unset-model-preserves-effort"
else
  fail "unset-model-preserves-effort map=$(cat "$MAP")"
fi

# =============================================================================
# AC15 — list calls resolve-model.sh and --effort (M18)
# =============================================================================
mkdir -p .claude/dev-team "$(dirname "$GLOBAL_MAP")"
printf '%s\n' '{"version":1,"agents":{"ic4":"from-repo"},"effort":{"ic4":"high","pm":"low"}}' >"$REPO_MAP"
printf '%s\n' '{"version":1,"agents":{"pm":"from-global"}}' >"$GLOBAL_MAP"
printf '%s\n' '{"version":1,"agents":{},"effort":{"ic4":"low"}}' >"$MAP"
run list
check_rc "list-composed" 0
if grep -Eq '^ic4[[:space:]]+from-repo[[:space:]]+low$' "$OUTF"; then
  pass "AC15-list-local-effort-repo-model"
else
  fail "AC15-list-local-effort-repo-model out='$(got_out)'"
fi
if grep -Eq '^pm[[:space:]]+from-global[[:space:]]+low$' "$OUTF"; then
  pass "AC15-list-global-model-repo-effort"
else
  fail "AC15-list-global-model-repo-effort out='$(got_out)'"
fi
if grep -Eq '^qa[[:space:]]+Tier default[[:space:]]+inherited$' "$OUTF"; then
  pass "AC15-list-omitted-inherited"
else
  fail "AC15-list-omitted-inherited out='$(got_out)'"
fi
BEFORE=$(cksum "$MAP")
run list
AFTER=$(cksum "$MAP")
if [ "$BEFORE" = "$AFTER" ]; then
  pass "AC14-list-nowrite-existing"
else
  fail "AC14-list-nowrite-existing file mutated"
fi

# local model + repo effort (inverse compose)
printf '%s\n' '{"version":1,"agents":{"ic4":"haiku"}}' >"$MAP"
run list
if grep -Eq '^ic4[[:space:]]+haiku[[:space:]]+high$' "$OUTF"; then
  pass "AC15-list-local-model-repo-effort"
else
  fail "AC15-list-local-model-repo-effort out='$(got_out)'"
fi

# =============================================================================
# never write repo / global even when they exist
# =============================================================================
REPO_H=$(cksum "$REPO_MAP")
GLOB_H=$(cksum "$GLOBAL_MAP")
run set-effort devops xhigh
check_rc "set-effort-layers" 0
if [ "$(cksum "$REPO_MAP")" = "$REPO_H" ] && [ "$(cksum "$GLOBAL_MAP")" = "$GLOB_H" ]; then
  pass "set-effort-never-repo-global"
else
  fail "set-effort-never-repo-global repo/global mutated"
fi
if [ "$(jq -r '.effort.devops' "$MAP")" = "xhigh" ] \
   && [ "$(jq -r '.agents.ic4' "$MAP")" = "haiku" ]; then
  pass "set-effort-local-keeps-agents"
else
  fail "set-effort-local-keeps-agents map=$(cat "$MAP")"
fi

# =============================================================================
# unparseable existing → refuse set-effort/unset-effort, exit 1, unchanged
# =============================================================================
printf '{\n' >"$MAP"
BEFORE=$(cksum "$MAP")
run set-effort ic5 high
check_rc "set-effort-unparseable" 1
if grep -qi 'unparseable' "$ERRF"; then
  pass "set-effort-unparseable-warn"
else
  fail "set-effort-unparseable-warn err='$(got_err)'"
fi
AFTER=$(cksum "$MAP")
if [ "$BEFORE" = "$AFTER" ]; then
  pass "set-effort-unparseable-nowrite"
else
  fail "set-effort-unparseable-nowrite file mutated"
fi

run unset-effort ic4
check_rc "unset-effort-unparseable" 1
AFTER=$(cksum "$MAP")
if [ "$BEFORE" = "$AFTER" ]; then
  pass "unset-effort-unparseable-nowrite"
else
  fail "unset-effort-unparseable-nowrite file mutated"
fi

printf '%s\n' '{"version":1,"effort":[]}' >"$MAP"
BEFORE=$(cksum "$MAP")
run set-effort pm high
check_rc "set-effort-array" 1
AFTER=$(cksum "$MAP")
if [ "$BEFORE" = "$AFTER" ]; then
  pass "set-effort-array-nowrite"
else
  fail "set-effort-array-nowrite file mutated"
fi

# =============================================================================
# git-common-dir MROOT: subdir set-effort writes MROOT local
# =============================================================================
printf '%s\n' '{"version":1,"agents":{"ic4":"haiku"}}' >"$MAP"
mkdir -p "$TMP/sub"
cd "$TMP/sub" || { fail "cd sub"; cd "$TMP"; }
run set-effort devops medium
cd "$TMP" || true
check_rc "set-effort-from-subdir" 0
if [ -f "$MAP" ] && [ "$(jq -r '.effort.devops' "$MAP")" = "medium" ] \
   && [ "$(jq -r '.agents.ic4' "$MAP")" = "haiku" ] \
   && [ ! -e "$TMP/sub/.claude/dev-team/models.local.json" ]; then
  pass "set-effort-mroot-not-subdir"
else
  fail "set-effort-mroot-not-subdir map=$(cat "$MAP" 2>/dev/null)"
fi

# =============================================================================
# jq missing: set-effort/unset-effort exit 1; list still tries resolve
# =============================================================================
cd "$TMP" || true
printf '%s\n' '{"version":1,"agents":{"pm":"keep"},"effort":{"pm":"high"}}' >"$MAP"
RC=0
: >"$OUTF"
: >"$ERRF"
env HOME="$FAKE_HOME" PATH="$NOJQ_BIN" "$BASH_ABS" "$WRITE" set-effort ic4 low \
  >"$OUTF" 2>"$ERRF" || RC=$?
if [ "$RC" -eq 1 ] && grep -qi 'jq not found' "$ERRF"; then
  pass "set-effort-no-jq"
else
  fail "set-effort-no-jq rc=$RC err='$(got_err)'"
fi
if [ "$(jq -r '.effort.ic4 // empty' "$MAP")" = "" ]; then
  pass "set-effort-no-jq-nowrite"
else
  fail "set-effort-no-jq-nowrite map=$(cat "$MAP")"
fi

RC=0
: >"$OUTF"
: >"$ERRF"
env HOME="$FAKE_HOME" PATH="$NOJQ_BIN" "$BASH_ABS" "$WRITE" unset-effort pm \
  >"$OUTF" 2>"$ERRF" || RC=$?
if [ "$RC" -eq 1 ]; then
  pass "unset-effort-no-jq"
else
  fail "unset-effort-no-jq rc=$RC err='$(got_err)'"
fi
if [ "$(jq -r '.effort.pm' "$MAP")" = "high" ]; then
  pass "unset-effort-no-jq-nowrite"
else
  fail "unset-effort-no-jq-nowrite map=$(cat "$MAP")"
fi

RC=0
: >"$OUTF"
: >"$ERRF"
env HOME="$FAKE_HOME" PATH="$NOJQ_BIN" "$BASH_ABS" "$WRITE" list \
  >"$OUTF" 2>"$ERRF" || RC=$?
if [ "$RC" -eq 0 ] && grep -Eq '^pm[[:space:]]+Tier default[[:space:]]+inherited$' "$OUTF"; then
  pass "list-no-jq-inherited"
else
  fail "list-no-jq-inherited rc=$RC out='$(got_out)' err='$(got_err)'"
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
