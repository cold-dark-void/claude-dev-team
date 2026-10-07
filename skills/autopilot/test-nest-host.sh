#!/usr/bin/env bash
#
# skills/autopilot/test-nest-host.sh — CDT-512-C6 nest-host.sh bite-tests.
#
# Machine-check: bash skills/autopilot/test-nest-host.sh (exit 0, all PASS)
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
NEST="$SCRIPT_DIR/nest-host.sh"

source "$ROOT/tests/lib/hermetic.sh"
hermetic_init

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }

# Isolate from the ambient Grok session and any live epic state.
clear_nest_env() {
  unset GROK_AGENT GROK_SESSION_ID DEVTEAM_HOST DEVTEAM_NEST_DEPTH \
    EPIC_RELEASE_END EPIC_INTEGRATION_PATH DEVTEAM_MROOT || true
}

# Each case runs inside a throwaway git repo so live $MROOT epic state cannot leak.
make_repo() {
  local d
  d=$(mktemp -d "$TMPDIR/nest-host-repo.XXXXXX")
  git -C "$d" init -q
  git -C "$d" config user.email "hermetic@example.invalid"
  git -C "$d" config user.name "hermetic"
  mkdir -p "$d/.claude/epics"
  printf '%s\n' "$d"
}

run_nest() {
  (
    clear_nest_env
    export HOME="$HERMETIC_ROOT/home"
    # shellcheck disable=SC2030,SC2031
    "$@"
  )
}

expect_json() {
  local desc="$1" want_host="$2" want_depth="$3" want_can="$4"
  shift 4
  local out rc=0
  out=$(run_nest "$@" bash "$NEST" 2>/dev/null) || rc=$?
  local host depth can
  host=$(printf '%s' "$out" | jq -r .host 2>/dev/null || echo "")
  depth=$(printf '%s' "$out" | jq -r .nest_depth 2>/dev/null || echo "")
  can=$(printf '%s' "$out" | jq -r .can_spawn_council 2>/dev/null || echo "")
  if [ "$rc" -eq 0 ] && [ "$host" = "$want_host" ] && [ "$depth" = "$want_depth" ] \
     && [ "$can" = "$want_can" ]; then
    pass "$desc"
  else
    fail "$desc rc=$rc out=$out (want host=$want_host depth=$want_depth can=$want_can)"
  fi
}

if [ ! -f "$NEST" ]; then
  fail "nest-host.sh missing"
  echo "PASS=$PASS FAIL=$FAIL"
  exit 1
fi

REPO=$(make_repo)

# 1. default (no grok, no nest) → claude / 0 / true
expect_json "default host=claude depth=0 can=true" claude 0 true \
  env -C "$REPO"

# 2. GROK_AGENT=1, no depth → grok can spawn (depth 0)
expect_json "GROK_AGENT=1 depth 0 can=true" grok 0 true \
  env -C "$REPO" GROK_AGENT=1

# 3. GROK_SESSION_ID alone → grok
expect_json "GROK_SESSION_ID depth 0 can=true" grok 0 true \
  env -C "$REPO" GROK_SESSION_ID=sid-1

# 4. grok + DEVTEAM_NEST_DEPTH=1 → cannot spawn
expect_json "grok nest_depth=1 can=false" grok 1 false \
  env -C "$REPO" GROK_AGENT=1 DEVTEAM_NEST_DEPTH=1

# 5. grok + DEVTEAM_NEST_DEPTH=0 overrides other nest signals
expect_json "DEVTEAM_NEST_DEPTH=0 wins over EPIC_RELEASE_END" grok 0 true \
  env -C "$REPO" GROK_AGENT=1 DEVTEAM_NEST_DEPTH=0 EPIC_RELEASE_END=CDT-512

# 6. grok + EPIC_RELEASE_END → depth 1
expect_json "EPIC_RELEASE_END implies nest_depth=1" grok 1 false \
  env -C "$REPO" GROK_AGENT=1 EPIC_RELEASE_END=CDT-512

# 7. grok + EPIC_INTEGRATION_PATH → depth 1
expect_json "EPIC_INTEGRATION_PATH implies nest_depth=1" grok 1 false \
  env -C "$REPO" GROK_AGENT=1 EPIC_INTEGRATION_PATH=/tmp/epic

# 8. claude nested CAN spawn
expect_json "claude nest_depth=1 can=true" claude 1 true \
  env -C "$REPO" DEVTEAM_NEST_DEPTH=1

# 9. DEVTEAM_HOST override
expect_json "DEVTEAM_HOST=grok + depth 1" grok 1 false \
  env -C "$REPO" DEVTEAM_HOST=grok DEVTEAM_NEST_DEPTH=1

# 10. --host claude wins over GROK_AGENT
out=$(run_nest env -C "$REPO" GROK_AGENT=1 DEVTEAM_NEST_DEPTH=1 \
  bash "$NEST" --host claude 2>/dev/null) || true
if printf '%s' "$out" | jq -e '.host=="claude" and .can_spawn_council==true' >/dev/null; then
  pass "--host claude wins over GROK_AGENT"
else
  fail "--host claude wins over GROK_AGENT out=$out"
fi

# 11. can-spawn-council exit codes
rc=0
run_nest env -C "$REPO" GROK_AGENT=1 DEVTEAM_NEST_DEPTH=1 \
  bash "$NEST" can-spawn-council >/dev/null || rc=$?
if [ "$rc" -eq 1 ]; then
  pass "can-spawn-council grok nest → exit 1"
else
  fail "can-spawn-council grok nest rc=$rc (want 1)"
fi
rc=0
run_nest env -C "$REPO" bash "$NEST" can-spawn-council >/dev/null || rc=$?
if [ "$rc" -eq 0 ]; then
  pass "can-spawn-council default → exit 0"
else
  fail "can-spawn-council default rc=$rc (want 0)"
fi

# 12. classify-spawn-fail
out=$(run_nest env -C "$REPO" GROK_AGENT=1 DEVTEAM_NEST_DEPTH=1 \
  bash "$NEST" classify-spawn-fail 2>/dev/null) || true
if [ "$out" = "needs-parent-M14" ]; then
  pass "classify-spawn-fail grok nest → needs-parent-M14"
else
  fail "classify-spawn-fail grok nest out=$out"
fi
out=$(run_nest env -C "$REPO" bash "$NEST" classify-spawn-fail 2>/dev/null) || true
if [ "$out" = "bc7-spawn-fail" ]; then
  pass "classify-spawn-fail depth 0 → bc7-spawn-fail"
else
  fail "classify-spawn-fail depth 0 out=$out"
fi

# 13. junk DEVTEAM_NEST_DEPTH ignored
expect_json "junk DEVTEAM_NEST_DEPTH ignored" grok 0 true \
  env -C "$REPO" GROK_AGENT=1 DEVTEAM_NEST_DEPTH=abc

# 14. --ticket in_progress epic child + grok → nest
mkdir -p "$REPO/.claude/epics/E1"
cat > "$REPO/.claude/epics/E1/state.json" << 'JSON'
{"epic_id":"E1","children":[{"id":"T-1","status":"in_progress"},{"id":"T-2","status":"pending"}]}
JSON
out=$(
  clear_nest_env
  GROK_AGENT=1
  export GROK_AGENT
  cd "$REPO" && bash "$NEST" --ticket T-1
) || true
if printf '%s' "$out" | jq -e '.host=="grok" and .nest_depth==1 and .can_spawn_council==false' >/dev/null; then
  pass "--ticket in_progress + grok → can=false"
else
  fail "--ticket in_progress + grok out=$out"
fi
out=$(
  clear_nest_env
  GROK_AGENT=1
  export GROK_AGENT
  cd "$REPO" && bash "$NEST" --ticket T-2
) || true
if printf '%s' "$out" | jq -e '.host=="grok" and .nest_depth==0 and .can_spawn_council==true' >/dev/null; then
  pass "--ticket pending + grok → can=true"
else
  fail "--ticket pending + grok out=$out"
fi

# 15. unknown subcommand → 64
rc=0
run_nest env -C "$REPO" bash "$NEST" nope >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 64 ]; then
  pass "unknown subcommand → 64"
else
  fail "unknown subcommand rc=$rc (want 64)"
fi

# 16. JSON is exactly one line
out=$(run_nest env -C "$REPO" bash "$NEST") || true
n=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
if [ "$n" -eq 1 ] && printf '%s' "$out" | jq -e . >/dev/null; then
  pass "stdout is one JSON line"
else
  fail "stdout not one JSON line n=$n out=$out"
fi

# 17. grok nest_depth=2 still cannot spawn
expect_json "grok nest_depth=2 can=false" grok 2 false \
  env -C "$REPO" GROK_AGENT=1 DEVTEAM_NEST_DEPTH=2

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
exit $?
