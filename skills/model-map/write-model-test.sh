#!/usr/bin/env bash
#
# write-model-test.sh — SPEC-037 bite-tests for write-model.sh (CDT-228)
#
# Machine-check: bash skills/model-map/write-model-test.sh  (exit 0)
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
# shellcheck source=../../tests/lib/path.sh
. "$SCRIPT_DIR/../../tests/lib/path.sh"
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
for c in bash git dirname pwd mktemp mv rm mkdir cat chmod env; do
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
# list — read-only, every mappable agent, Tier default, local path
# =============================================================================
run list extra-ignored
check_rc "list-extra-argv" 0
LIST=$(got_out)
# Both sides canonical: write-model.sh prints the git-resolved MROOT while the
# fixture string carries TMPDIR's trailing-slash `//` (macOS lane).
LOCAL_OUT=$(sed -n 's/^local: //p' "$OUTF" | head -1)
if [ -n "$LOCAL_OUT" ] && [ "$(path_canon "$LOCAL_OUT")" = "$(path_canon "$TMP/.claude/dev-team/models.local.json")" ]; then
  pass "list-local-path"
else
  fail "list-local-path out='$LIST'"
fi
missing=""
for a in $(bash "$SCRIPT_DIR/mappable-names.sh" --list); do
  echo "$LIST" | grep -Eq "^${a}[[:space:]]+Tier default([[:space:]]|$)" || missing="$missing $a"
done
if [ -z "$missing" ]; then
  pass "list-mappable-tier-default"
else
  fail "list-mappable-tier-default missing:$missing out='$LIST'"
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
if grep -Eq '^pm[[:space:]]+grok-4([[:space:]]|$)' "$OUTF"; then
  pass "list-after-set-pm"
else
  fail "list-after-set-pm out='$(got_out)'"
fi
if grep -Eq '^ic4[[:space:]]+Tier default([[:space:]]|$)' "$OUTF"; then
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
if grep -Eq '^pm[[:space:]]+from-repo([[:space:]]|$)' "$OUTF"; then
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
# set-concurrency / unset-concurrency — SPEC-037 M34 (CDT-573)
# =============================================================================
printf '%s\n' '{"version":1,"agents":{"ic4":"keep"},"effort":{"ic4":"high"},"concurrency":9,"extra":true}' >"$MAP"

run set-concurrency 4
check_rc "set-concurrency" 0
if [ "$(jq -r '.concurrency' "$MAP")" = "4" ] \
   && [ "$(jq -r '.agents.ic4' "$MAP")" = "keep" ] \
   && [ "$(jq -r '.effort.ic4' "$MAP")" = "high" ] \
   && [ "$(jq -r '.extra' "$MAP")" = "true" ]; then
  pass "set-concurrency-preserve"
else
  fail "set-concurrency-preserve map=$(cat "$MAP")"
fi

# N must be an integer >= 1: reject, exit 64, usage, zero write.
i=0
for bad in 0 -1 abc 1.5 04 '' '   '; do
  i=$((i + 1))
  printf '%s\n' '{"version":1,"agents":{"ic4":"keep"},"concurrency":9}' >"$MAP"
  BEFORE=$(cksum "$MAP")
  run set-concurrency "$bad"
  AFTER=$(cksum "$MAP")
  if [ "$RC" -eq 64 ] && [ "$BEFORE" = "$AFTER" ] && [ ! -s "$OUTF" ] \
     && grep -qF 'usage: write-model.sh' "$ERRF"; then
    pass "set-concurrency-bad-$i"
  else
    fail "set-concurrency-bad-$i '$bad' rc=$RC out='$(got_out)' err='$(got_err)'"
  fi
done

run set-concurrency
check_rc "set-concurrency-no-arg" 64

# The cap grammar has ONE home: resolve-concurrency.sh (SPEC-037 M30/M34).
# write-model.sh MUST NOT keep a second copy of the grammar (CDT-573 review).
if grep -qE '^is_cap\(\)' "$WRITE"; then
  fail "set-concurrency-no-grammar-copy: write-model.sh re-implements is_cap"
else
  pass "set-concurrency-no-grammar-copy"
fi
if grep -qF 'resolve-concurrency.sh' "$WRITE" \
   && grep -qF -- '--flag "$1"' "$WRITE" \
   && grep -qF 'env -u COUNCIL_CONCURRENCY' "$WRITE"; then
  pass "set-concurrency-grammar-delegates"
else
  fail "set-concurrency-grammar-delegates: set-concurrency must validate through resolve-concurrency.sh --flag in an env-clean subshell"
fi

# Grammar-only validation: an inherited env cap MUST NOT leak into the check —
# it validates neither way, and the value written is the argument, not the env.
printf '%s\n' '{"version":1,"agents":{}}' >"$MAP"
RC=0
: >"$OUTF"
: >"$ERRF"
COUNCIL_CONCURRENCY=3 run set-concurrency abc
if [ "$RC" -eq 64 ] && grep -qF 'usage: write-model.sh' "$ERRF" \
   && [ "$(jq -r 'has("concurrency")' "$MAP")" = "false" ]; then
  pass "set-concurrency-env-invalid-still-64"
else
  fail "set-concurrency-env-invalid-still-64 rc=$RC err='$(got_err)' map=$(cat "$MAP")"
fi
run set-concurrency 7
if [ "$RC" -eq 0 ] && [ "$(jq -r '.concurrency' "$MAP")" = "7" ]; then
  pass "set-concurrency-env-valid-writes-arg-not-env"
else
  fail "set-concurrency-env-valid-writes-arg-not-env rc=$RC map=$(cat "$MAP")"
fi
unset COUNCIL_CONCURRENCY

# " 6 " trims to a valid cap; leading/trailing zeros do not.
printf '%s\n' '{"version":1,"agents":{}}' >"$MAP"
run set-concurrency " 6 " leftover
check_rc "set-concurrency-trim" 0
if [ "$(jq -r '.concurrency' "$MAP")" = "6" ]; then
  pass "set-concurrency-trim-wrote"
else
  fail "set-concurrency-trim-wrote map=$(cat "$MAP")"
fi

# Other verbs MUST NOT drop the top-level concurrency key (M18 extension).
printf '%s\n' '{"version":1,"agents":{"ic4":"keep"},"effort":{"ic4":"high"},"concurrency":6}' >"$MAP"
run set pm newmodel; RC_SET=$RC
run unset pm; RC_UNSET=$RC
run set-effort pm low
run unset-effort pm
if [ "$RC_SET$RC_UNSET" = "00" ] && [ "$RC" -eq 0 ] \
   && [ "$(jq -r '.concurrency' "$MAP")" = "6" ] \
   && [ "$(jq -r '.agents | has("pm")' "$MAP")" = "false" ] \
   && [ "$(jq -r '.effort | has("pm")' "$MAP")" = "false" ] \
   && [ "$(jq -r '.agents.ic4' "$MAP")" = "keep" ]; then
  pass "verbs-preserve-concurrency"
else
  fail "verbs-preserve-concurrency map=$(cat "$MAP")"
fi

run unset-concurrency
check_rc "unset-concurrency" 0
if [ "$(jq -r 'has("concurrency")' "$MAP")" = "false" ] \
   && [ "$(jq -r '.agents.ic4' "$MAP")" = "keep" ] \
   && [ "$(jq -r '.effort.ic4' "$MAP")" = "high" ]; then
  pass "unset-concurrency-preserve"
else
  fail "unset-concurrency-preserve map=$(cat "$MAP")"
fi

BEFORE=$(cksum "$MAP")
run unset-concurrency extra-ignored
check_rc "unset-concurrency-missing" 0
if [ "$(cksum "$MAP")" = "$BEFORE" ]; then
  pass "unset-concurrency-missing-nowrite"
else
  fail "unset-concurrency-missing-nowrite file mutated"
fi

# list prints the cap in both states.
run set-concurrency 3
run list
if grep -qxF 'concurrency: 3' "$OUTF"; then
  pass "list-concurrency-capped"
else
  fail "list-concurrency-capped out='$(got_out)'"
fi
run unset-concurrency
run list
if grep -qxF 'concurrency: unbounded' "$OUTF"; then
  pass "list-concurrency-unbounded"
else
  fail "list-concurrency-unbounded out='$(got_out)'"
fi

# unparseable existing → refuse, exit 1, file unchanged
printf '{\n' >"$MAP"
BEFORE=$(cksum "$MAP")
run set-concurrency 4
check_rc "set-concurrency-unparseable" 1
AFTER=$(cksum "$MAP")
if [ "$BEFORE" = "$AFTER" ]; then
  pass "set-concurrency-unparseable-nowrite"
else
  fail "set-concurrency-unparseable-nowrite file mutated"
fi

run unset-concurrency
check_rc "unset-concurrency-unparseable" 1
AFTER=$(cksum "$MAP")
if [ "$BEFORE" = "$AFTER" ]; then
  pass "unset-concurrency-unparseable-nowrite"
else
  fail "unset-concurrency-unparseable-nowrite file mutated"
fi

# local layer only: repo and global maps stay untouched
printf '%s\n' '{"version":1,"agents":{}}' >"$MAP"
REPO_H=$(cksum "$REPO_MAP")
GLOB_H=$(cksum "$GLOBAL_MAP")
run set-concurrency 5
check_rc "set-concurrency-layers" 0
if [ "$(cksum "$REPO_MAP")" = "$REPO_H" ] && [ "$(cksum "$GLOBAL_MAP")" = "$GLOB_H" ]; then
  pass "set-concurrency-never-repo-global"
else
  fail "set-concurrency-never-repo-global repo/global mutated"
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

# /setup models routes both concurrency verbs (SPEC-037 M36).
if grep -qF '/setup models set-concurrency <N>' "$ROOT/commands/setup.md" \
   && grep -qF '/setup models unset-concurrency' "$ROOT/commands/setup.md"; then
  pass "setup-models-concurrency-routing"
else
  fail "setup-models-concurrency-routing missing verbs in commands/setup.md"
fi

# models.local.json.lock is a local runtime file (write-model.sh flock target):
# .gitignore must list it next to models.local.json (CDT-282 [09 F23]). A text
# match, not `git check-ignore`: a global excludes file can hide the defect.
if grep -qxF '.claude/dev-team/models.local.json.lock' "$ROOT/.gitignore"; then
  pass "models-local-lock-ignored"
else
  fail "models-local-lock-ignored: .claude/dev-team/models.local.json.lock is not in .gitignore"
fi
# control: the same match finds nothing for a line that is not in the file
if grep -qxF '.claude/dev-team/not-a-runtime-file.lock' "$ROOT/.gitignore"; then
  fail "control: the .gitignore match finds a line that is not there"
else
  pass "control: the .gitignore match is false for an absent line"
fi
# adjust-agent names every mappable internal agent (write-model.sh is_mappable;
# rv-w1-20): finder and debugger are mappable like council-judge.
for a in council-judge finder debugger; do
  if grep -qF "\`$a\`" "$ROOT/commands/adjust-agent.md" && grep -qE "\`finder\` and \`debugger\` (are|is) (mappable|omitted|allowed)|\`finder\` and \`debugger\` are (mappable|omitted|allowed)" "$ROOT/commands/adjust-agent.md"; then
    pass "adjust-agent-mappable-$a"
  else
    fail "adjust-agent-mappable-$a: commands/adjust-agent.md does not name it as mappable"
  fi
done

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
